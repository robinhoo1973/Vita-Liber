#if os(iOS) || os(macOS)
// linux-blind: URLSession/ZIP/AES-GCM 传输语义 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import ZIPFoundation

// 目录包下载/解包传输层（2026-10-28 切片-only B2 提取）：自 v4
// `MedicalCatalogUpdateService+Install` 原样搬出——切片安装器与存活调用面共用，
// 随 v4 文件删除不能带走。

// MARK: - Transport

/// 只从固定 Release 地址取签名命名的包；redirect 逐跳过 HTTPS 主机白名单且限跳数，
/// 落盘字节超过签名 packageSize 即中止。
public struct URLSessionMedicalCatalogPackageFetcher: MedicalCatalogPackageFetching, Sendable {
    private let session: URLSession
    /// 资产名 → 固定 Release 基址 URL。默认 = v4 `package-<ver>.bin` 文法；
    /// 切片服务注入 `CatalogSliceProtocol` 解析器（`app-catalog-*.bin`）——
    /// 传输/重试/尺寸门/逐跳主机白名单全部共用一条路径（2026-10-28 二轮质询矛盾 A：
    /// 名门与主机门是两件事，名门必须可注入而不是另起一套下载器）。
    private let urlResolver: @Sendable (String) -> URL?

    /// 2026-09-27 委员会裁决 5（SRE 席）：目录 fetcher 由 URLSession.shared（60s 空闲
    /// 超时、无重试）升级为专有会话——waitsForConnectivity 吸收短时抖动、
    /// 300s 请求超时兜底慢链路（GB 级 SQLite 在慢链路曾被 -1001 误杀）；
    /// 瞬态错误重试一次（与 ModelPackageDownloader 同清单 + 4s 退避）。
    public init(session: URLSession? = nil,
                urlResolver: @escaping @Sendable (String) -> URL? = { assetName in
                    MedicalCatalogReleaseProtocol.packageURL(assetName: assetName)
                }) {
        self.urlResolver = urlResolver
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 300
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetch(assetName: String, expectedSize: Int64, to destination: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard expectedSize > 0, let url = urlResolver(assetName) else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        var lastFailure: MedicalCatalogUpdateError = .downloadFailed
        for attempt in 0..<2 {
            let transfer = MedicalCatalogPackageTransfer(expectedBytes: expectedSize, onBytes: progress)
            let location: URL
            let response: URLResponse
            do {
                (location, response) = try await session.download(for: request, delegate: transfer)
                defer { try? FileManager.default.removeItem(at: location) } // try?-ok: URLSession 临时文件清理
                if let failure = transfer.failure { throw failure }
                try transfer.validate(response)
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                } catch {
                    throw MedicalCatalogUpdateError.downloadFailed
                }
                guard try CatalogPackageFiles.size(of: destination) == expectedSize else {
                    throw MedicalCatalogUpdateError.checksumMismatch
                }
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let medical = error as? MedicalCatalogUpdateError {
                    lastFailure = medical
                    // 非传输类失败（校验/落盘）不重试
                    guard attempt == 0 else { throw medical }
                    if medical != .downloadFailed { throw medical }
                } else if let urlError = error as? URLError,
                          [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                           .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(urlError.code) {
                    lastFailure = .downloadFailed
                    // 末次尝试仍失败：抛映射后的统一错误域（fetcher 契约 = MedicalCatalogUpdateError，
                    // 不向调用面泄漏 URLError——CI 36308337446 行为钉实证）
                    if attempt > 0 { throw lastFailure }
                } else {
                    throw error
                }
                try await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        throw lastFailure
    }
}

final class MedicalCatalogPackageTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maxRedirects = 5
    private let expectedBytes: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var storedFailure: MedicalCatalogUpdateError?
    private var redirects = 0
    private var lastReportedPercent: Int64 = -1

    init(expectedBytes: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.expectedBytes = expectedBytes
        self.onBytes = onBytes
    }

    var failure: MedicalCatalogUpdateError? { lock.lock(); defer { lock.unlock() }; return storedFailure }

    /// 守卫在回调里 cancel 后 URLSession 只抛 `URLError.cancelled`；优先暴露守卫记录的真实原因。
    func resolve(_ error: Error) -> Error { failure ?? MedicalCatalogUpdateError.downloadFailed }

    private func record(_ failure: MedicalCatalogUpdateError) {
        lock.lock()
        if storedFailure == nil { storedFailure = failure }
        lock.unlock()
    }

    private func nextRedirect() -> Int {
        lock.lock(); defer { lock.unlock() }
        redirects += 1
        return redirects
    }

    func validate(_ response: URLResponse) throws {
        guard let url = response.url, MedicalCatalogReleaseProtocol.allowsTransferURL(url) else {
            throw MedicalCatalogUpdateError.redirectRejected
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        if response.expectedContentLength >= 0, response.expectedContentLength != expectedBytes {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard nextRedirect() <= Self.maxRedirects, let url = request.url,
              MedicalCatalogReleaseProtocol.allowsTransferURL(url) else {
            record(.redirectRejected)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes else {
            record(.packageTooLarge)
            downloadTask.cancel()
            return
        }
        // 进度节流（2026-09-26 审查修复，StreamingFileHasher 同先例：按整百分比上报、
        // 上限 ~101 次）：URLSession 每 ~16–64KB 读一次就回调一次，大包（上限 GB 级）
        // 会产生数万次回调，每次构造进度枚举并 hop 过 actor；Settings 进度 UI 挂上
        // 后每个 chunk 就是一次状态变更 + SwiftUI 重绘（ASR 下载器 2026-09-16 教训）。
        lock.lock()
        let percent = totalBytesWritten * 100 / max(expectedBytes, 1)
        let changed = percent > lastReportedPercent
        if changed { lastReportedPercent = percent }
        lock.unlock()
        if changed { onBytes(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

// MARK: - Package opening

/// 分块 AES-256-GCM 信封解密 + 单 entry ZIP 解包（2026-10-06 业主裁决：
/// 医疗包加密改为与 ASR CI 一致，App 只保留一条解压解密路径）。
///
/// 直接复用 ASR 的 `ASRPackageCrypto.decryptEnvelope`——同一把主密钥、同一
/// 帧格式、同一 HKDF info 名空间。合并的代价是该主密钥**不是对 App 用户的
/// 秘密**（它按设计内嵌在 `ASRPackageCrypto.masterKeyHex` 里，任何拿到 App
/// 的人都能提取）；医疗包的真实性从来不由加密承担，而由 Ed25519 双签指针 +
/// 下载前 `packageSHA256` + 解密后 `sqliteSHA256` 校验承担（见调用点）。
public struct EnvelopeMedicalCatalogPackageOpening: MedicalCatalogPackageOpening, Sendable {
    public init() {}

    /// `identity` 必须是信封加密时使用的包身份 = 明文 SQLite 的 SHA-256，
    /// 由调用方从**验签后的** `candidate.sqliteSHA256` 传入。identity 漂移
    /// （例如误传 dataVersion 或 catalogVersion）会以 GCM 认证失败拒绝，
    /// 而不是解出垃圾——ASR 侧的金样测试已钉死这一失败语义。
    public func open(packageURL: URL, sqliteURL: URL, identity: String, entryName: String,
                     maxSQLiteBytes: Int64) async throws {
        let zipURL = sqliteURL.deletingLastPathComponent()
            .appendingPathComponent("medical-catalog-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) } // try?-ok: 解密中间件清理
        do {
            try ASRPackageCrypto.decryptEnvelope(at: packageURL, to: zipURL, identity: identity)
        } catch {
            // 认证失败/畸形/尺寸不符一律归约为 packageInvalid：调用点已有
            // `mapped(error, fallback: .packageInvalid)`，这里保持错误域单一。
            throw MedicalCatalogUpdateError.packageInvalid
        }
        try MedicalCatalogPackageExtractor.extractSQLite(from: zipURL, to: sqliteURL,
                                                         entryName: entryName,
                                                         maxSQLiteBytes: maxSQLiteBytes)
    }
}

/// 包内必须恰好一个普通文件（名 = 调用方传入的 `entryName`，即验签后的
/// `packageAssetName`/载荷 `sqliteEntryName` 绑定值）；声明大小与实际解压字节
/// 双重限额，目标文件独占创建，任何失败都不留下半成品。
enum MedicalCatalogPackageExtractor {
    static func extractSQLite(from zipURL: URL, to sqliteURL: URL, entryName: String,
                              maxSQLiteBytes: Int64) throws {
        let fileManager = FileManager.default
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        let entries = archive.makeIterator()
        guard let entry = entries.next(), entries.next() == nil,
              entry.path == entryName, entry.type == .file,
              entry.uncompressedSize > 0, entry.uncompressedSize <= UInt64(maxSQLiteBytes) else {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        let declared = entry.uncompressedSize
        if let free = try? sqliteURL.deletingLastPathComponent() // try?-ok: 取不到剩余空间只跳过预检，写盘失败仍判红
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Int64(declared) {
            throw MedicalCatalogUpdateError.insufficientStorage
        }
        guard !fileManager.fileExists(atPath: sqliteURL.path),
              fileManager.createFile(atPath: sqliteURL.path, contents: nil) else {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        do {
            let handle = try FileHandle(forWritingTo: sqliteURL)
            defer { try? handle.close() } // try?-ok: 写句柄关闭失败由随后的 SHA 校验判红
            var received: UInt64 = 0
            let crc = try archive.extract(entry) { data in
                received += UInt64(data.count)
                guard received <= declared else { throw MedicalCatalogUpdateError.packageInvalid }
                try handle.write(contentsOf: data)
            }
            guard received == declared, crc == entry.checksum else { throw MedicalCatalogUpdateError.packageInvalid }
        } catch {
            try? fileManager.removeItem(at: sqliteURL) // try?-ok: 拒绝路径清理半成品，不掩盖主错误
            if error is MedicalCatalogUpdateError { throw error }
            throw MedicalCatalogUpdateError.packageInvalid
        }
    }
}
#endif
