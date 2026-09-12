// FR17.15（业主 2026-09-12 决定）：ASR 模型**运行时下载 / 解压 / 校验 / 原子切换**服务。
//
// 设计要点（详见 tech-spec §5.13 与 downloads/README.md）：
// - 只读 `downloads/<app>/asr/index.json` 索引；`baseUrl` + 相对文件名 ⇒ 换 CDN 不发版。
// - 下载：`URLSession` 分段 Range（默认 4 路）并行；服务端不支持 Range 时自动退化为单流；
//   全程只写目标文件（不落内存大对象），进度经回调逐段聚合。
// - 校验：整包 SHA-256（CryptoKit 流式）→ 解压 → `ASRModelAssets.validate` 逐文件字节数/SHA。
// - 切换：先装到暂存目录，校验通过才原子移动到 `<id>/<version>/` 并改写 `active.json` 指针；
//   任何失败保持旧版本可用（先装后切）；保留上一版本以支持回滚。
// - 解压：ZIPFoundation（成熟 MIT 库，避免自研 zip 解析——业主「不重复造轮子」要求）。
// - 离线优先红线：本服务**只由用户显式动作（[检查更新]/[下载模型]/[更新]按钮）调用**；
//   视图出现不再自动拉取索引（安全审查 2026-09-12）；识别会话路径不调用。
#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Domain
import ZIPFoundation

public actor ASRModelDownloadService {
    public struct DownloadProgress: Sendable, Equatable {
        public var receivedBytes: Int64
        public var totalBytes: Int64
        public var fraction: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }
    }

    public enum Failure: Error, Equatable {
        case badIndex          // 索引不合法/结构版本不支持
        case notPublished      // 条目未发布（空 sha256 / 零字节）
        case untrustedPackage  // 未登记于**构建期信任锚**或哈希不一致（fail closed）
        case badAddress        // URL 无法解析
        case badResponse(Int)  // 非 2xx
        case sizeMismatch      // 下载字节数与索引不符
        case checksumMismatch  // 整包 SHA-256 不符
        case unzipFailed
        case invalidPackage    // 包内 manifest/文件校验失败（ASRModelAssets 拒绝）
        case installFailed
        case installInProgress // 已有安装进行中（actor 级互斥，防跨视图实例竞态）
    }

    struct ActivePointer: Codable, Sendable {
        var choice: String
        var version: String
        var installedAt: Date
    }

    private let session: URLSession
    private let fileManager = FileManager.default
    /// 分段数：4 路在移动网/CDN 场景通常接近带宽上限，且不至于触发服务端限流。
    private let segmentCount = 4
    /// 安装互斥（actor 级）：actor 串行化不覆盖 await 间隙，跨实例的并发
    /// install 会在 moveItem/active.json 上竞态（静默降级）——入口同步检入检出的
    /// 守卫才是真互斥。UI 一律经 `shared` 单例（安全审查 2026-09-12：此前每视图
    /// 自建实例，守卫互不看见，互斥形同虚设）。
    private var installing = false

    public init(session: URLSession = .shared) { self.session = session }

    /// 全 App 共享实例：安装互斥守卫是实例级的，共享实例才能让互斥跨视图生效。
    public static let shared = ASRModelDownloadService()

    /// 索引地址：优先 Info.plist `ASRModelIndexURL`（发版/私有环境可覆盖），否则用仓库内默认
    /// `downloads/vitaliber/asr/index.json` 的 raw 地址（robinhoo1973/Vita-Liber，master）。
    public nonisolated static var indexURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "ASRModelIndexURL") as? String,
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "https://raw.githubusercontent.com/robinhoo1973/Vita-Liber/master/downloads/vitaliber/asr/index.json")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    // MARK: - 路径

    /// 运行时资产根：`Application Support/ASRModels/`（与随包 `Bundle/ASRModels` 平行的第二条供应路径）。
    public nonisolated static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ASRModels", isDirectory: true)
    }

    /// 已激活（校验过）的下载版本目录；无有效指针则返回 nil（调用方回落随包/Bundle）。
    public nonisolated static func activeRoot(for choice: VoiceEngineChoice) -> URL? {
        guard let pointer = activePointer(for: choice) else { return nil }
        return applicationSupportRoot().appendingPathComponent(choice.rawValue, isDirectory: true)
            .appendingPathComponent(pointer.version, isDirectory: true)
    }

    public nonisolated static func installedVersion(for choice: VoiceEngineChoice) -> String? {
        activePointer(for: choice)?.version
    }

    // MARK: - 指针缓存（进程级；install 完成时失效）

    /// `active.json` 是低频变更文件，但被 resolve/installedVersion/updateAvailable
    /// 在设置页 body 与能力查询热路径反复同步读盘——进程级备忘，安装落盘后失效。
    private static let pointerCacheLock = NSLock()
    /// 缓存值为装箱枚举而非 `ActivePointer?`——字典对可选值赋 nil 会删键，
    /// 负缓存（未安装=无指针）随之失效，每次调用都重读 active.json（审查发现）。
    private nonisolated(unsafe) static var pointerCache: [String: PointerResult] = [:]

    private enum PointerResult: Sendable {
        case none
        case pointer(ActivePointer)
    }

    public nonisolated static func activePointer(for choice: VoiceEngineChoice) -> ActivePointer? {
        pointerCacheLock.lock(); defer { pointerCacheLock.unlock() }
        switch pointerCache[choice.rawValue] {
        case .none: return nil
        case .pointer(let pointer): return pointer
        case nil:
            let computed = computeActivePointer(for: choice)
            pointerCache[choice.rawValue] = computed.map(PointerResult.pointer) ?? .none
            return computed
        }
    }

    private nonisolated static func computeActivePointer(for choice: VoiceEngineChoice) -> ActivePointer? {
        let root = applicationSupportRoot().appendingPathComponent(choice.rawValue, isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("active.json")),   // try?-ok: 指针缺失=未下载（布尔判定，非错误吞没）
              let pointer = try? JSONDecoder().decode(ActivePointer.self, from: data) else { return nil }   // try?-ok: 同上
        let dir = root.appendingPathComponent(pointer.version, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            return nil
        }
        return pointer
    }

    private nonisolated static func invalidatePointerCache() {
        pointerCacheLock.lock()
        pointerCache = [:]
        pointerCacheLock.unlock()
    }

    // MARK: - 索引

    /// 拉取并校验索引（结构版本不支持即拒绝；不做任何缓存写入——索引很小）。
    public func fetchIndex(from url: URL) async throws -> ASRModelReleaseIndex {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let index = try JSONDecoder().decode(ASRModelReleaseIndex.self, from: data)
        guard index.isSupported else { throw Failure.badIndex }
        return index
    }

    /// 最新可发布条目（同 id 中取版本最高者；未发布/不兼容条目跳过）。
    public nonisolated static func latest(for choice: VoiceEngineChoice,
                                          in index: ASRModelReleaseIndex,
                                          appVersion: String) -> ASRModelRelease? {
        index.models
            .filter { $0.id == choice.rawValue && $0.isPublished && $0.isCompatible(appVersion: appVersion) }
            // 构建期信任锚：未登记于 App 内置哈希表的版本不可安装，UI 直接不展示（fail closed）。
            .filter { TrustedModelHashStore.shared.isTrusted($0) }
            .max { ASRVersion.isNewer($1.version, than: $0.version) }
    }

    /// 是否存在可更新版本（已装版本由 active.json 记录）。
    /// 未安装时不视为「可更新」——新装走独立的下载按钮分支（否则新装
    /// 恒显示「更新到 X」且下载按钮/失败提示分支永远不可达）。
    public nonisolated static func updateAvailable(for choice: VoiceEngineChoice,
                                                   index: ASRModelReleaseIndex,
                                                   appVersion: String) -> ASRModelRelease? {
        guard let installed = installedVersion(for: choice) else { return nil }
        guard let latest = latest(for: choice, in: index, appVersion: appVersion) else { return nil }
        return latest.isNewer(than: installed) ? latest : nil
    }

    // MARK: - 安装

    /// 下载 → 校验 → 解压 → 包内校验 → 原子切换。返回安装后的版本目录。
    @discardableResult
    public func install(_ release: ASRModelRelease,
                        baseURL: URL?,
                        progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        guard !installing else { throw Failure.installInProgress }
        installing = true
        defer { installing = false }
        guard release.isPublished else { throw Failure.notPublished }
        // 构建期信任锚（随 App 签名保护的哈希表）是**唯一信任根**：远端索引可被替换，
        // 若只比对远端自报 sha256 等于无信任根。未登记版本一律拒绝安装。
        guard let trusted = TrustedModelHashStore.shared.trustedEntry(for: release) else {
            throw Failure.untrustedPackage
        }
        guard let url = release.resolvedURL(baseURL: baseURL) else { throw Failure.badAddress }

        let modelRoot = Self.applicationSupportRoot()
            .appendingPathComponent(release.id, isDirectory: true)
        let staging = modelRoot.appendingPathComponent(".staging-\(release.version)-\(UUID().uuidString)",
                                                       isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }   // try?-ok: 暂存清理失败无用户可见后果，不掩盖主错误

        let zipURL = staging.appendingPathComponent("package.zip")
        try await download(url: url, expectedBytes: release.bytes ?? 0, to: zipURL, progress: progress)

        let digest = try Self.sha256(of: zipURL)
        // 以信任锚哈希为准（上一步已确保 release.sha256 == trusted.sha256）。
        guard digest.caseInsensitiveCompare(trusted.sha256) == .orderedSame else {
            throw Failure.checksumMismatch
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(zipURL, to: unpacked)

        guard let choice = VoiceEngineChoice(rawValue: release.id) else { throw Failure.invalidPackage }
        do {
            _ = try ASRModelAssets(root: unpacked).validate(choice)
        } catch {
            throw Failure.invalidPackage
        }

        let versionDir = modelRoot.appendingPathComponent(release.version, isDirectory: true)
        if fileManager.fileExists(atPath: versionDir.path) {
            try? fileManager.removeItem(at: versionDir)   // try?-ok: 同版本旧目录清理；失败由下方 moveItem 报错
        }
        do {
            try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: unpacked, to: versionDir)
        } catch {
            throw Failure.installFailed
        }

        let pointer = ActivePointer(choice: release.id, version: release.version, installedAt: Date())
        let pointerData = try JSONEncoder().encode(pointer)
        try pointerData.write(to: modelRoot.appendingPathComponent("active.json"), options: .atomic)
        Self.invalidatePointerCache()
        ASRModelAssets.invalidateCaches()

        pruneOldVersions(modelRoot: modelRoot, keeping: release.version)
        return versionDir
    }

    /// 下载（分段并行；不支持 Range 时单流）。预计字节数来自索引，用于预分配与进度分母。
    /// 服务端宣称 Range 却对分段请求整包 200（代理/CDN 吞 Range）时，分段会互相
    /// 覆写产出垃圾文件——捕获后整文件重建、退回单流重下（进度另计，不虚增）。
    private func download(url: URL,
                          expectedBytes: Int64,
                          to destination: URL,
                          progress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        // 纵深防御（安全审查 2026-09-12）：下载目标必须 https——Domain `resolvedURL`
        // 已限相对路径 + https baseUrl，此处兜底任何直构 URL 的调用点。
        guard url.scheme?.lowercased() == "https" else { throw Failure.badAddress }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 30
        let (_, headResponse) = try await session.data(for: head)
        guard let headHTTP = headResponse as? HTTPURLResponse, (200..<300).contains(headHTTP.statusCode) else {
            throw Failure.badResponse((headResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let total = headResponse.expectedContentLength > 0 ? headResponse.expectedContentLength : expectedBytes
        guard total > 0 else { throw Failure.badResponse(-1) }
        let supportsRanges = headHTTP.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false

        fileManager.createFile(atPath: destination.path, contents: nil)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }   // try?-ok: 句柄关闭失败由系统回收，无静默降级风险
        try writer.truncate(atOffset: UInt64(total))

        if supportsRanges, segmentCount > 1 {
            let chunk = total / Int64(segmentCount)
            let counter = ProgressCounter(total: total, callback: progress)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<segmentCount {
                        let start = Int64(index) * chunk
                        let end = index == segmentCount - 1 ? total - 1 : start + chunk - 1
                        group.addTask {
                            try await Self.downloadSegment(session: self.session, url: url,
                                                           start: start, end: end,
                                                           destination: destination, counter: counter)
                        }
                    }
                    try await group.waitForAll()
                }
            } catch {
                // Range 被服务端忽略（对 bytes=start-end 返回 200 整包）：分段写坏了文件，
                // 重建空文件后单流重下。进度计数器重建，避免分段字节虚增进度。
                try? fileManager.removeItem(at: destination)   // try?-ok: 旧坏文件删除失败由重建覆盖
                fileManager.createFile(atPath: destination.path, contents: nil)
                let writer = try FileHandle(forWritingTo: destination)
                defer { try? writer.close() }   // try?-ok: 句柄关闭失败由系统回收
                try writer.truncate(atOffset: UInt64(total))
                let fallbackCounter = ProgressCounter(total: total, callback: progress)
                try await Self.downloadSegment(session: session, url: url, start: 0, end: nil,
                                               destination: destination, counter: fallbackCounter)
            }
        } else {
            let counter = ProgressCounter(total: total, callback: progress)
            try await Self.downloadSegment(session: session, url: url, start: 0, end: nil,
                                           destination: destination, counter: counter)
        }

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let written = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard written == total else { throw Failure.sizeMismatch }
        progress?(.init(receivedBytes: total, totalBytes: total))
    }

    /// 单个 Range 段：独立 FileHandle 从 start 处顺序写入（互不重叠，无需加锁）。
    private static func downloadSegment(session: URLSession,
                                        url: URL,
                                        start: Int64,
                                        end: Int64?,
                                        destination: URL,
                                        counter: ProgressCounter) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let end { request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.badResponse(-1)
        }
        // 带 Range 的请求只认 206：返回 200 = 服务端忽略 Range 发了整包，
        // 在 start 偏移写整包会产出尺寸错乱的垃圾文件——必须抛错走单流回落。
        if end != nil {
            guard http.statusCode == 206 else { throw Failure.badResponse(http.statusCode) }
        } else {
            guard http.statusCode == 200 else { throw Failure.badResponse(http.statusCode) }
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }   // try?-ok: 分段写入句柄关闭失败由系统回收
        try handle.seek(toOffset: UInt64(start))

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                counter.add(Int64(buffer.count))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            counter.add(Int64(buffer.count))
        }
    }

    // MARK: - 解压与校验

    private func unzip(_ zipURL: URL, to root: URL) throws {
        guard let archive = Archive(url: zipURL, accessMode: .read) else { throw Failure.unzipFailed }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in archive {
            // 路径穿越防护：拒绝绝对路径与 `..`（zip 内路径不可信）。
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else {
                throw Failure.unzipFailed
            }
            let target = root.appendingPathComponent(entry.path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            do {
                _ = try archive.extract(entry, to: target)
            } catch {
                throw Failure.unzipFailed
            }
        }
    }

    /// 流式 SHA-256（不把整包读进内存）。
    public nonisolated static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unzipFailed }   // try?-ok: 打开失败即刻换上抛，非吞没
        defer { try? handle.close() }   // try?-ok: 读句柄关闭失败由系统回收
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 保留当前版本 + 最近一个旧版本（回滚窗口），其余删除。
    /// 版本目录按 `ASRVersion.isNewer` 语义排序（字典序会把 `v2026.03.4` 排在
    /// `v2026.03.25` 之后、把 `1.9` 排在 `1.10` 之后——回滚窗口会保留最旧版本）。
    private func pruneOldVersions(modelRoot: URL, keeping version: String) {
        guard let entries = try? fileManager.contentsOfDirectory(at: modelRoot,   // try?-ok: 目录不可读=无可清理版本，清理非关键路径
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { return }
        let versions = entries.filter { $0.hasDirectoryPath && $0.lastPathComponent != version }
        guard versions.count > 1 else { return }
        let sorted = versions.sorted { ASRVersion.isNewer($0.lastPathComponent, than: $1.lastPathComponent) }
        for stale in sorted.dropFirst() { try? fileManager.removeItem(at: stale) }   // try?-ok: 旧版本清理失败仅占空间，不影响新版本使用
    }
}

/// 多段并发进度聚合（回调可在任意线程调用；调用方自行切主线程）。
/// 节流：每 64KB 块发一次会把主线程淹成数千次 hop——按增量 ≥0.5% 或
/// ≥200ms 发一次；终态由调用方显式补发 1.0。
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = 0
    private var lastEmittedFraction: Double = 0
    private var lastEmitTime: TimeInterval = 0
    private let total: Int64
    private let callback: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?

    init(total: Int64, callback: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?) {
        self.total = total
        self.callback = callback
    }

    func add(_ bytes: Int64) {
        lock.lock()
        received += bytes
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmit = fraction - lastEmittedFraction >= 0.005 || now - lastEmitTime >= 0.2
        if shouldEmit {
            lastEmittedFraction = fraction
            lastEmitTime = now
        }
        let snapshot = received
        lock.unlock()
        if shouldEmit {
            callback?(.init(receivedBytes: snapshot, totalBytes: total))
        }
    }
}
#endif
