#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import Domain

/// T2 本机 LLM 模型下载服务（2026-10-09 换型+下载化批）：
/// 模型不随包——经本服务自发布面（CNB release，目录条目钉 URL+sha256+bytes）
/// 下载到安装位，校验通过后原子激活。
///
/// 与 2026-09-20 被回滚的初版（b8d6c4f8）的结构差异——**单一来源**：
/// 初版在 Bundle 分支仍在的前提下加下载（本地 `isModelReady()` 恒真 → 下载路径
/// 短路，「画蛇添足」当日回滚）；本版 Bundle 分支已从 `LlamaModelManager` 整体
/// 删除（L0 [20] 断言钉死），下载是唯一进料路径——并存矛盾不可复现。
///
/// 复用 ASR 侧已成型的下载纪律（成熟实现优先）：
/// - 断点续传：`ModelPackageDownloader.resumeOffset`（`<file>.part` 字节水位）；
/// - 分段并行 + HEAD 探测 + 服务端吞 Range 退单流（下载器内部，零重写）；
/// - 哈希+字节双钉版：`StreamingFileHasher.sha256` 与目录条目逐字节比对，不符即弃；
/// - 原子激活：校验通过后才 move 入版本目录并**最后**写指针（active.json）——
///   半程文件永不可见；指针写失败 = 旧版本继续有效；
/// - 失败清理：暂存目录整体删除，`.part` 仅在续传语义（同文件名重装）下保留。
public actor LLMModelDownloadService {

    /// 安装阶段（消费侧呈现确定性与阶段文案）。
    public enum Phase: Sendable, Equatable {
        case downloading
        case verifying
        case activating
    }

    /// 进度快照（复用 Domain 进度值类型：单调守卫/系列语义与 ASR 同源）。
    public typealias Progress = ASRDownloadProgress
    public typealias Failure = ASRDownloadFailure

    public static let shared = LLMModelDownloadService()

    /// 单装全局串行（actor 互斥 + 显式在装集合给出 `.installInProgress` 语义）。
    private var installing: Set<String> = []
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = true
        // 默认仅非计费网络（Wi-Fi）；蜂窝需 UI 侧显式放行——本批按保守默认。
        configuration.allowsExpensiveNetworkAccess = false
        session = URLSession(configuration: configuration)
    }

    /// 安装（幂等）：已就绪即短路返回；否则 下载 → 校验 → 激活。
    /// 取消（Task.cancel）→ `CancellationError`，暂存保留可续传；失败 → 暂存清理后抛错。
    @discardableResult
    public func install(_ entry: LLMModelCatalog.Entry,
                        progress: (@Sendable (Progress) -> Void)? = nil,
                        onPhase: (@Sendable (Phase) -> Void)? = nil) async throws -> URL {
        if LlamaModelManager.isModelReady(id: entry.id), let url = LlamaModelManager.installedModelURL(id: entry.id) {
            return url
        }
        guard installing.insert(entry.id).inserted else { throw Failure.installInProgress }
        defer { installing.remove(entry.id) }

        // —— 入口校验（信任锚 = 随包目录条目；这里只是把它的钉版值当输入）——
        guard ModelResourcePolicy.allowedURL(entry.url), entry.bytes > 0,
              entry.bytes <= ModelResourcePolicy.packageBytes else { throw Failure.badAddress }
        try checkStorage(requiredBytes: entry.bytes)

        guard let root = LlamaModelManager.installRootDirectory,
              let directory = LlamaModelManager.installDirectory(id: entry.id) else {
            throw Failure.installFailed
        }
        let staging = directory.appendingPathComponent(
            LLMModelInstallLayout.stagingDirectoryName(uuid: UUID().uuidString), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            excludeFromBackup(root)

            let partial = staging.appendingPathComponent(entry.fileName + LLMModelInstallLayout.partialSuffix)
            let partialBytes = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)   // try?-ok: 无 .part 即从头下载
                .flatMap { $0?.int64Value }
            let resumeOffset = LLMModelInstallLayout.resumeOffset(partialBytes: partialBytes,
                                                                  expectedBytes: entry.bytes)

            let flag = CancelFlag()
            onPhase?(.downloading)
            let downloader = ModelPackageDownloader(session: session, segmentCount: 4)
            do {
                try await withTaskCancellationHandler {
                    try await downloader.download(
                        url: entry.url, expectedBytes: entry.bytes, to: partial,
                        progress: { update in
                            progress?(Progress(receivedBytes: update.receivedBytes, totalBytes: update.totalBytes,
                                               mode: update.mode, series: update.series))
                        },
                        resumeOffset: resumeOffset,
                        isStopRequested: { flag.isCancelled })
                } onCancel: {
                    flag.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            }

            // —— 校验（哈希 + 字节双钉版；不符即弃，绝不安装不可信字节）——
            onPhase?(.verifying)
            let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)   // try?-ok: 读不到即判失败
                .flatMap { $0?.int64Value } ?? 0
            guard size == entry.bytes else { throw Failure.sizeMismatch }
            let digest = try StreamingFileHasher.sha256(of: partial)
            guard digest.lowercased() == entry.sha256.lowercased() else { throw Failure.checksumMismatch }

            // —— 激活（原子：move 到位 → 最后写指针）——
            onPhase?(.activating)
            let versionDirectory = directory.appendingPathComponent(
                LLMModelInstallLayout.versionDirectoryName(version: entry.version, sha256: entry.sha256),
                isDirectory: true)
            try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            let destination = versionDirectory.appendingPathComponent(entry.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            try LlamaModelManager.writePointer(
                LlamaModelManager.InstallPointer(version: entry.version, fileName: entry.fileName,
                                                 bytes: entry.bytes, sha256: entry.sha256),
                id: entry.id)

            // 清扫：只保留刚激活的版本目录（历史版本在指针切换成功后删除；回滚=重下）。
            let cleanup = LLMModelInstallLayout.cleanupPlan(installed: installedVersionDirectories(in: directory),
                                                            active: versionDirectory.lastPathComponent)
            for stale in cleanup {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))   // try?-ok: 清扫尽力而为，残留由下次安装再扫
            }
            try? FileManager.default.removeItem(at: staging)   // try?-ok: 暂存目录已空，删除失败由系统临时目录回收

            // 换型激活后驱逐旧驻留句柄（旧模型句柄仍指向已删文件时下次 load 才失败——此处主动释放）。
            await LlamaRuntime.shared.unload()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)   // try?-ok: 失败清理尽力而为
            throw error
        }
    }

    /// 删除已安装模型（先断指针再删目录——指针在 = 就绪；顺序反了会有「指针在而文件无」窗口）。
    public func remove(id: String) async throws {
        guard let directory = LlamaModelManager.installDirectory(id: id) else { return }
        let pointer = directory.appendingPathComponent(LLMModelInstallLayout.pointerFileName)
        try? FileManager.default.removeItem(at: pointer)   // try?-ok: 指针本就不在=幂等
        await LlamaRuntime.shared.unload()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - 私有

    private func checkStorage(requiredBytes: Int64) throws {
        guard let root = LlamaModelManager.installRootDirectory else { throw Failure.installFailed }
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),   // try?-ok: 探针失败不拦（fail-open 只对未知）
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let headroom: Int64 = 256 * 1_024 * 1_024
        guard available >= requiredBytes + headroom else { throw Failure.insufficientStorage }
    }

    private func installedVersionDirectories(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []   // try?-ok: 读不到按空目录处理
        return names.filter { !$0.hasPrefix(LLMModelInstallLayout.stagingPrefix)
            && $0 != LLMModelInstallLayout.pointerFileName }
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)   // try?-ok: 备份排除失败不阻断安装（整目录属可再生数据）
    }

    /// 取消标志盒（downloader 的 isStopRequested 需跨线程可见的同步闭包）。
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
#endif
