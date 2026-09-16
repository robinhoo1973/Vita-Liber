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
import Domain
// CryptoKit/ZIPFoundation 随职责迁出（StreamingFileHasher / ModelPackageUnpacker）。

public actor ASRModelDownloadService {
    /// 传输形态（2026-09-16 业主实测「ASR 下载速度很慢」）：`ModelPackageDownloader`
    /// 在 `supportsRanges` 为假、或 HEAD 最终响应不带 `Accept-Ranges: bytes` 时
    /// **静默退化**为单流——1 条连接 vs 分段 N 路并发，这是「慢」的首要嫌疑，
    /// 但此前没有任何出口可判定，只能靠猜。暴露到进度回调即可当场分辨。
    public enum DownloadMode: Sendable, Equatable {
        case segmented(segments: Int)
        case singleStream
    }

    public struct DownloadProgress: Sendable, Equatable {
        public var receivedBytes: Int64
        public var totalBytes: Int64
        /// 传输形态；`nil` = 尚未确定。
        public var mode: DownloadMode? = nil
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
        var directory: String? = nil
        var artifactRevision: Int? = nil
        var packageSHA256: String? = nil
    }

    private let session: URLSession
    private let trust = ModelCatalogTrustStore.shared
    private let fileManager = FileManager.default
    /// 分段数（并行度）：6——2026-09-15 实测复核（业主报告下载慢）：CDN
    /// （release-assets.githubusercontent.com，白名单已放行）支持 `Accept-Ranges: bytes`，
    /// 分段并行链路本身正常；瓶颈在单连接链路速率（本机实测单流 ~0.17 MB/s），
    /// 提高并发连接数聚合带宽是标准手段（大文件场景 4 → 6，仍低于连接池上限）。
    private let segmentCount = 6
    /// 安装互斥（actor 级）：actor 串行化不覆盖 await 间隙，跨实例的并发
    /// install 会在 moveItem/active.json 上竞态（静默降级）——入口同步检入检出的
    /// 守卫才是真互斥。UI 一律经 `shared` 单例（安全审查 2026-09-12：此前每视图
    /// 自建实例，守卫互不看见，互斥形同虚设）。
    /// 在装模型集合（release.id）：per-model 互斥（各模型独立目录/指针/暂存），
    /// 并发上限 2——同链路分段已 6 路，多模型再叠加会互相抢带宽。
    private var installing: Set<String> = []
    private static let maximumConcurrentInstalls = 2

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // 连接池上限（成熟下载器通行做法）：默认 6 会与分段数打平——6 段并行 + 索引/HEAD
        // 请求同刻争用会排队；抬到 8 留出余量。不设超时天花板（大包在慢链路需数小时，
        // timeoutIntervalForResource 默认 7 天不干预）。
        configuration.httpMaximumConnectionsPerHost = 8
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// 全 App 共享实例：安装互斥守卫是实例级的，共享实例才能让互斥跨视图生效。
    public static let shared = ASRModelDownloadService()

    /// 索引地址：优先 Info.plist `ASRModelIndexURL`（发版/私有环境可覆盖），否则用仓库内默认
    /// `downloads/vitaliber/asr/index.json` 的 raw 地址（robinhoo1973/Vita-Liber，master）。
    public nonisolated static var indexURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "ASRModelIndexURL") as? String,
           let url = URL(string: raw), ModelResourcePolicy.allowedURL(url) {
            return url
        }
        return URL(string: "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models/catalog.json")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    // MARK: - 协作类（结构轮 2026-09-15 拆分：下载/解压/哈希/指针各一职责类）
    // 以下 static 转发保留原公共面（App 与 CoreKit 内消费点零改）。

    /// 分段下载器（HEAD 探测 → 4 路并行 → 吞 Range 退单流）。
    private var downloader: ModelPackageDownloader {
        ModelPackageDownloader(session: session, segmentCount: segmentCount)
    }

    /// 运行时资产根：`Application Support/ASRModels/`（转发 ActivePointerStore）。
    public nonisolated static func applicationSupportRoot() -> URL { ActivePointerStore.applicationSupportRoot() }

    /// 已激活（校验过）的下载版本目录；无有效指针则返回 nil（调用方回落随包/Bundle）。
    public nonisolated static func activeRoot(for choice: VoiceEngineChoice) -> URL? { ActivePointerStore.activeRoot(for: choice) }

    public nonisolated static func installedVersion(for choice: VoiceEngineChoice) -> String? { ActivePointerStore.installedVersion(for: choice) }

    nonisolated static func activeAssets(for choice: VoiceEngineChoice) -> ASRModelAssets? { ActivePointerStore.activeAssets(for: choice) }

    /// 流式 SHA-256（转发 StreamingFileHasher；整包校验与逐文件校验同源）。
    public nonisolated static func sha256(of url: URL) throws -> String { try StreamingFileHasher.sha256(of: url) }

    /// 崩溃残留暂存回收（转发 ActivePointerStore）。
    nonisolated static func removeStaleStaging(in modelRoot: URL, fileManager: FileManager = .default) {
        ActivePointerStore.removeStaleStaging(in: modelRoot, fileManager: fileManager)
    }

    // MARK: - 索引

    /// 拉取并校验索引（结构版本不支持即拒绝；不做任何缓存写入——索引很小）。
    public func fetchIndex(from url: URL) async throws -> ASRModelReleaseIndex {
        guard installing.isEmpty else { throw Failure.installInProgress }
        for _ in 0..<32 {
            guard let next = trust.nextRootURL else { throw Failure.badIndex }
            do {
                let data = try await metadata(from: next)
                try trust.acceptRoot(data)
            }
            catch Failure.badResponse(404) { break }
        }
        let data = try await metadata(from: url)
        let index = try trust.acceptCatalog(data)
        ASRModelAssets.invalidateCaches()
        return index
    }

    private func metadata(from url: URL) async throws -> Data {
        guard ModelResourcePolicy.allowedURL(url) else { throw Failure.badAddress }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let guardDelegate = ModelResourceTransfer()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
        } catch {
            try Task.checkCancellation()
            throw guardDelegate.resolve(error)
        }
        if let failure = guardDelegate.failure { throw failure }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try guardDelegate.validate(response)
        guard response.expectedContentLength <= Int64(ModelResourcePolicy.metadataBytes) else { throw Failure.badIndex }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ModelResourcePolicy.metadataBytes else { throw Failure.badIndex }
            data.append(byte)
        }
        return data
    }

    /// 最新可发布条目（同 id 中取版本最高者；未发布/不兼容条目跳过）。
    public nonisolated static func latest(for choice: VoiceEngineChoice,
                                          in index: ASRModelReleaseIndex,
                                          appVersion: String) -> ASRModelRelease? {
        index.models
            .filter { $0.id == choice.rawValue && $0.isPublished && $0.isCompatible(appVersion: appVersion) }
            // 方案 B：目录验签产生动态授权；App 内基线提供已知包的离线授权。
            .filter { ModelCatalogTrustStore.shared.isAuthorized($0) && $0.runtime == ModelResourcePolicy.runtime }
            .max {
                if $0.version == $1.version { return ($0.artifactRevision ?? 0) < ($1.artifactRevision ?? 0) }
                return ASRVersion.isNewer($1.version, than: $0.version)
            }
    }

    /// 是否存在可更新版本（已装版本由 active.json 记录）。
    /// 未安装时不视为「可更新」——新装走独立的下载按钮分支（否则新装
    /// 恒显示「更新到 X」且下载按钮/失败提示分支永远不可达）。
    public nonisolated static func updateAvailable(for choice: VoiceEngineChoice,
                                                   index: ASRModelReleaseIndex,
                                                   appVersion: String) -> ASRModelRelease? {
        guard let installed = installedVersion(for: choice) else { return nil }
        guard let latest = latest(for: choice, in: index, appVersion: appVersion) else { return nil }
        let newerPackage = latest.version == installed && (latest.artifactRevision ?? 0) > (ActivePointerStore.activePointer(for: choice)?.artifactRevision ?? 0)
        return latest.isNewer(than: installed) || newerPackage ? latest : nil
    }

    // MARK: - 安装

    /// 安装阶段（业主 2026-09-16 实测：此前只有下载阶段有进度，校验/解压/激活
    /// 长时间无反馈——慢链路下用户判定「卡死」）。UI 按阶段展示确定进度（下载）
    /// 或不确定进度 + 阶段文案。
    public enum InstallPhase: String, Sendable, Equatable {
        case downloading
        case verifying
        case unpacking
        case activating
        case pruning
    }

    /// 下载 → 校验 → 解压 → 包内校验 → 原子切换。返回安装后的版本目录。
    /// `onPhase` 逐阶段回调（主线程无保证，调用方自行 hop）。
    @discardableResult
    public func install(_ release: ASRModelRelease,
                        baseURL: URL?,
                        progress: (@Sendable (DownloadProgress) -> Void)? = nil,
                        onPhase: (@Sendable (InstallPhase) -> Void)? = nil) async throws -> URL {
        // per-model 互斥（2026-09-16）：各模型有独立 modelRoot / active.json / staging，
        // 无共享可变状态——此前全局 Bool 把「并行下载不同模型」一并禁掉且拒绝路径
        // 静默（业主实测「不能多个同时下载」）。并发上限防链路争用（同链路分段已 6 路）。
        guard !installing.contains(release.id) else { throw Failure.installInProgress }
        guard installing.count < Self.maximumConcurrentInstalls else { throw Failure.installInProgress }
        installing.insert(release.id)
        defer { installing.remove(release.id) }
        guard release.isPublished else { throw Failure.notPublished }
        // 公钥签名目录或 App 内嵌基线授权完整描述；网络自报 SHA 无法自行授权。
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.1"
        guard trust.isAuthorized(release), release.isCompatible(appVersion: appVersion),
              release.runtime == ModelResourcePolicy.runtime else {
            throw Failure.untrustedPackage
        }
        guard let authorizedBase = trust.baseURL(for: release),
              baseURL == nil || baseURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == authorizedBase.absoluteString,
              let url = release.resolvedURL(baseURL: authorizedBase) else { throw Failure.badAddress }

        let modelRoot = Self.applicationSupportRoot()
            .appendingPathComponent(release.id, isDirectory: true)
        guard let choice = VoiceEngineChoice(rawValue: release.id), choice.isBundledModel,
              let expanded = release.expandedBytes, expanded > 0, expanded <= ModelResourcePolicy.expandedBytes else { throw Failure.invalidPackage }
        // 安全复审 S-I1：崩溃/jetsam 残留的暂存目录先于空间预算检查回收，
        // 否则反复中断的大包会把空闲空间耗尽、后续安装恒失败。
        ActivePointerStore.removeStaleStaging(in: modelRoot, fileManager: fileManager)
        let previousRoot = Self.activeRoot(for: choice)
        let staging = modelRoot.appendingPathComponent(".staging-\(release.version)-\(UUID().uuidString)",
                                                       isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }   // try?-ok: 暂存清理失败无用户可见后果，不掩盖主错误
        var excludedRoot = modelRoot
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        let free = try staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let free, free < 2 * (release.bytes ?? 0) + expanded + 268_435_456 { throw Failure.installFailed }

        let zipURL = staging.appendingPathComponent("package.zip")
        onPhase?(.downloading)
        try await downloader.download(url: url, expectedBytes: release.bytes ?? 0, to: zipURL, progress: progress)

        onPhase?(.verifying)
        // 校验/解压复用 `progress` 出口（不新增通道）：阶段本身已说明字节的含义，
        // UI 据此二选文案（下载 = 「已下载 X/Y」，校验解压 = 只出条不出数字）。
        let digest = try StreamingFileHasher.sha256(of: zipURL) { processed, total in
            progress?(.init(receivedBytes: processed, totalBytes: total))
        }
        // release 的整份描述已匹配受信任授权。
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw Failure.checksumMismatch
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        onPhase?(.unpacking)
        try ModelPackageUnpacker.unzip(zipURL, to: unpacked, maximumBytes: expanded) { processed, total in
            progress?(.init(receivedBytes: processed, totalBytes: total))
        }
        do {
            _ = try ASRModelAssets(root: unpacked).validate(choice)
        } catch {
            throw Failure.invalidPackage
        }

        try Task.checkCancellation()
        guard trust.isAuthorized(release) else { throw Failure.untrustedPackage }
        // 唯一安装目录：同版本修复也不会先删除当前激活目录。
        onPhase?(.activating)
        let directoryName = String(release.version.prefix(60)) + "-" + String(release.sha256.prefix(12)) + "-" + UUID().uuidString
        let versionDir = modelRoot.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: unpacked, to: versionDir)
        } catch {
            throw Failure.installFailed
        }

        let pointer = ActivePointer(choice: release.id, version: release.version, installedAt: Date(),
                                    directory: directoryName, artifactRevision: release.artifactRevision, packageSHA256: release.sha256)
        do {
            try Task.checkCancellation()
            let pointerData = try JSONEncoder().encode(pointer)
            try pointerData.write(to: modelRoot.appendingPathComponent("active.json"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: versionDir) // try?-ok: 未激活的本次唯一安装目录清理，不触碰旧版本
            throw error
        }
        ActivePointerStore.invalidatePointerCache()
        ASRModelAssets.invalidateCaches()

        onPhase?(.pruning)
        pruneOldVersions(modelRoot: modelRoot, keeping: [versionDir, previousRoot].compactMap { $0 })
        return versionDir
    }
    /// 版本目录按 `ASRVersion.isNewer` 语义排序（字典序会把 `v2026.03.4` 排在
    /// `v2026.03.25` 之后、把 `1.9` 排在 `1.10` 之后——回滚窗口会保留最旧版本）。
    private func pruneOldVersions(modelRoot: URL, keeping roots: [URL]) {
        guard let entries = try? fileManager.contentsOfDirectory(at: modelRoot,   // try?-ok: 目录不可读=无可清理版本，清理非关键路径
                                                                 includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                 options: [.skipsHiddenFiles]) else { return }
        let kept = Set(roots.map { $0.standardizedFileURL.path })
        for stale in entries where !kept.contains(stale.standardizedFileURL.path) {
            do {
                let values = try stale.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try ASRModelAssets.removeIfUnused(stale)
            } catch { /* 清理失败只保留旧资源，不改变当前激活版本。 */ }
        }
    }
}
#endif
