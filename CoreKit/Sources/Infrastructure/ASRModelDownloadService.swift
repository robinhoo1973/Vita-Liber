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
        var directory: String? = nil
        var artifactRevision: Int? = nil
        var packageSHA256: String? = nil
    }

    private let session: URLSession
    private let trust = ModelCatalogTrustStore.shared
    private let fileManager = FileManager.default
    /// 分段数：4 路在移动网/CDN 场景通常接近带宽上限，且不至于触发服务端限流。
    private let segmentCount = 4
    /// 安装互斥（actor 级）：actor 串行化不覆盖 await 间隙，跨实例的并发
    /// install 会在 moveItem/active.json 上竞态（静默降级）——入口同步检入检出的
    /// 守卫才是真互斥。UI 一律经 `shared` 单例（安全审查 2026-09-12：此前每视图
    /// 自建实例，守卫互不看见，互斥形同虚设）。
    private var installing = false

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
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
            .appendingPathComponent(pointer.directory ?? pointer.version, isDirectory: true)
    }

    public nonisolated static func installedVersion(for choice: VoiceEngineChoice) -> String? {
        activePointer(for: choice)?.version
    }

    nonisolated static func activeAssets(for choice: VoiceEngineChoice) -> ASRModelAssets? {
        guard let pointer = activePointer(for: choice), let hash = pointer.packageSHA256 else { return nil }
        let root = applicationSupportRoot().appendingPathComponent(choice.rawValue, isDirectory: true)
            .appendingPathComponent(pointer.directory ?? pointer.version, isDirectory: true)
        return ASRModelAssets(root: root, packageSHA256: hash)
    }

    // MARK: - 指针缓存（进程级；install 完成时失效）

    /// `active.json` 是低频变更文件，但被 resolve/installedVersion/updateAvailable
    /// 在设置页 body 与能力查询热路径反复同步读盘——进程级备忘，安装落盘后失效。
    private static let pointerCacheLock = NSLock()
    /// 缓存值为装箱枚举而非 `ActivePointer?`——字典对可选值赋 nil 会删键，
    /// 负缓存（未安装=无指针）随之失效，每次调用都重读 active.json（审查发现）。
    private nonisolated(unsafe) static var pointerCache: [String: PointerResult] = [:]

    private enum PointerResult: Sendable {
        case missing
        case pointer(ActivePointer)
    }

    private nonisolated static func activePointer(for choice: VoiceEngineChoice) -> ActivePointer? {
        pointerCacheLock.lock(); defer { pointerCacheLock.unlock() }
        switch pointerCache[choice.rawValue] {
        case .some(.missing): return nil
        case .some(.pointer(let pointer)):
            guard let hash = pointer.packageSHA256, !ModelCatalogTrustStore.shared.isRevoked(hash) else { return nil }
            return pointer
        case nil:
            let computed = computeActivePointer(for: choice)
            pointerCache[choice.rawValue] = computed.map(PointerResult.pointer) ?? PointerResult.missing
            return computed
        }
    }

    private nonisolated static func computeActivePointer(for choice: VoiceEngineChoice) -> ActivePointer? {
        let root = applicationSupportRoot().appendingPathComponent(choice.rawValue, isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("active.json")),   // try?-ok: 指针缺失=未下载（布尔判定，非错误吞没）
              let pointer = try? JSONDecoder().decode(ActivePointer.self, from: data) else { return nil }   // try?-ok: 同上
        guard let hash = pointer.packageSHA256, ModelResourcePolicy.isSHA256(hash),
              !ModelCatalogTrustStore.shared.isRevoked(hash),
              pointer.choice == choice.rawValue, ModelResourcePolicy.isSlug(pointer.version),
              ModelResourcePolicy.isSlug(pointer.directory ?? pointer.version) else { return nil }
        let dir = root.appendingPathComponent(pointer.directory ?? pointer.version, isDirectory: true)
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
        guard !installing else { throw Failure.installInProgress }
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
        let (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
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
        let newerPackage = latest.version == installed && (latest.artifactRevision ?? 0) > (activePointer(for: choice)?.artifactRevision ?? 0)
        return latest.isNewer(than: installed) || newerPackage ? latest : nil
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
        try await download(url: url, expectedBytes: release.bytes ?? 0, to: zipURL, progress: progress)

        let digest = try Self.sha256(of: zipURL)
        // release 的整份描述已匹配受信任授权。
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw Failure.checksumMismatch
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(zipURL, to: unpacked, maximumBytes: expanded)
        do {
            _ = try ASRModelAssets(root: unpacked).validate(choice)
        } catch {
            throw Failure.invalidPackage
        }

        try Task.checkCancellation()
        guard trust.isAuthorized(release) else { throw Failure.untrustedPackage }
        // 唯一安装目录：同版本修复也不会先删除当前激活目录。
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
        Self.invalidatePointerCache()
        ASRModelAssets.invalidateCaches()

        pruneOldVersions(modelRoot: modelRoot, keeping: [versionDir, previousRoot].compactMap { $0 })
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
        guard ModelResourcePolicy.allowedURL(url), expectedBytes > 0,
              expectedBytes <= ModelResourcePolicy.packageBytes else { throw Failure.badAddress }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 30
        head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let headGuard = ModelResourceTransfer()
        let (_, headResponse) = try await session.data(for: head, delegate: headGuard)
        if let failure = headGuard.failure { throw failure }
        guard let headHTTP = headResponse as? HTTPURLResponse else { throw Failure.badResponse(-1) }
        let headSupported = (200..<300).contains(headHTTP.statusCode)
        guard headSupported || headHTTP.statusCode == 405 || headHTTP.statusCode == 501 else {
            throw Failure.badResponse(headHTTP.statusCode)
        }
        if headSupported, headResponse.expectedContentLength > 0, headResponse.expectedContentLength != expectedBytes { throw Failure.sizeMismatch }
        let total = expectedBytes
        let supportsRanges = headSupported && (headHTTP.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false)

        fileManager.createFile(atPath: destination.path, contents: nil)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }   // try?-ok: 句柄关闭失败由系统回收，无静默降级风险
        try writer.truncate(atOffset: 0)

        if supportsRanges, total >= Int64(segmentCount) {
            let chunk = total / Int64(segmentCount)
            let counter = ProgressCounter(total: total, callback: progress)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<segmentCount {
                        let start = Int64(index) * chunk
                        let end = index == segmentCount - 1 ? total - 1 : start + chunk - 1
                        group.addTask {
                            try await Self.downloadSegment(session: self.session, url: url,
                                                           start: start, end: end, total: total,
                                                           destination: destination, counter: counter)
                        }
                    }
                    try await group.waitForAll()
                }
            } catch Failure.badResponse(let status) where status == 200 || status == 416 {
                try Task.checkCancellation()
                // Range 被服务端忽略（对 bytes=start-end 返回 200 整包）：分段写坏了文件，
                // 重建空文件后单流重下。进度计数器重建，避免分段字节虚增进度。
                try writer.truncate(atOffset: 0)
                let fallbackCounter = ProgressCounter(total: total, callback: progress)
                try await Self.downloadSegment(session: session, url: url, start: 0, end: nil, total: total,
                                               destination: destination, counter: fallbackCounter)
            }
        } else {
            let counter = ProgressCounter(total: total, callback: progress)
            try await Self.downloadSegment(session: session, url: url, start: 0, end: nil, total: total,
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
                                         total: Int64,
                                        destination: URL,
                                        counter: ProgressCounter) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let end { request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range") }
        let expected = end.map { $0 - start + 1 } ?? total
        let delegate = ModelResourceTransfer(expectedBytes: expected, range: end.map { (start, $0, total) }, onBytes: { counter.add($0) })
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            try Task.checkCancellation()
            if let failure = delegate.failure { throw failure }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) } // try?-ok: URLSession 临时下载文件清理，不掩盖主错误
        try Task.checkCancellation()
        if let failure = delegate.failure { throw failure }
        try delegate.validate(response)
        let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard size?.int64Value == expected else { throw Failure.sizeMismatch }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }   // try?-ok: 分段写入句柄关闭失败由系统回收
        try handle.seek(toOffset: UInt64(start))
        let input = try FileHandle(forReadingFrom: temporary)
        defer { try? input.close() } // try?-ok: 只读临时文件句柄清理
        var written: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            written += Int64(chunk.count)
            guard written <= expected else { throw Failure.sizeMismatch }
            try handle.write(contentsOf: chunk)
        }
        guard written == expected else { throw Failure.sizeMismatch }
    }

    // MARK: - 解压与校验

    private func unzip(_ zipURL: URL, to root: URL, maximumBytes: Int64) throws {
        let archive = try Archive(url: zipURL, accessMode: .read, pathEncoding: nil)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var paths = Set<String>()
        var count = 0
        var total: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            // 路径穿越防护：拒绝绝对路径与 `..`（zip 内路径不可信）。
            guard count <= ModelResourcePolicy.zipEntries, entry.type != .symlink,
                  !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains(":"),
                  !entry.path.split(separator: "/").contains(".."), entry.path.utf8.count <= 1024,
                  !entry.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  UInt64(entry.uncompressedSize) <= UInt64(maximumBytes) - total else {
                throw Failure.unzipFailed
            }
            total += UInt64(entry.uncompressedSize)
            let target = root.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  paths.insert(target.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw Failure.unzipFailed }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            do {
                if entry.type == .directory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                let ext = target.pathExtension.lowercased()
                guard ["onnx", "json", "txt", "md", "vocab"].contains(ext)
                        || ["LICENSE", "README", "NOTICE"].contains(target.lastPathComponent) else { throw Failure.unzipFailed }
                guard fileManager.createFile(atPath: target.path, contents: nil) else { throw Failure.unzipFailed }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() } // try?-ok: 解压临时文件句柄关闭
                var received: UInt64 = 0
                let crc = try archive.extract(entry) { data in
                    try Task.checkCancellation()
                    received += UInt64(data.count)
                    guard received <= UInt64(entry.uncompressedSize) else { throw Failure.unzipFailed }
                    try handle.write(contentsOf: data)
                }
                guard received == UInt64(entry.uncompressedSize), crc == entry.checksum else { throw Failure.unzipFailed }
            } catch {
                if error is CancellationError { throw error }
                throw Failure.unzipFailed
            }
        }
        guard total == UInt64(maximumBytes) else { throw Failure.sizeMismatch }
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
