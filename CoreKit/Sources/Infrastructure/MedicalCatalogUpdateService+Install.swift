#if os(iOS) || os(macOS)
// linux-blind: URLSession/AgeKit/ZIPFoundation/GRDB 安装链路 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import AgeKit
import ZIPFoundation

extension MedicalCatalogUpdateService {
    public init(destination: URL,
                fetcher: any MedicalCatalogPackageFetching = URLSessionMedicalCatalogPackageFetcher(),
                journal: (any MedicalCatalogActivationJournaling)? = nil,
                limits: MedicalCatalogUpdateLimits = .standard,
                trust: MedicalCatalogTrustStore? = nil) {
        self.init(destination: destination, fetcher: fetcher, journal: journal, limits: limits,
                  activeCheck: { try MedicalCatalogStore.smokeCheck(path: $0) }, trust: trust)
    }

    /// 下载 → 包 size/SHA → 解密解包 → SQLite size/SHA → 发布门 + 代表性查询 → 同卷 staging
    /// → journal.begin → 原子替换 → 复开 → journal.complete。任一门失败或取消都保留原目录库。
    public func update(candidate: VerifiedMedicalCatalogCandidate,
                       opener: any MedicalCatalogPackageOpening,
                       progress: @escaping @Sendable (MedicalCatalogUpdateProgress) -> Void = { _ in }) async throws {
        guard candidate.installable else { throw MedicalCatalogUpdateError.catalogNotInstallable }
        guard !isUpdating else { throw MedicalCatalogUpdateError.updateInProgress }
        isUpdating = true
        defer { isUpdating = false }
        // 反回退 floor（2026-09-26 审查接线）：候选已由 pinned root 验签，此处推进
        // 「已验证达到过的最高版本」地板——更低版本/同版本异 digest 就地拒绝，
        // 不进入下载（metadata 层面的可信度与安装结果无关，符合 TrustStore 契约）。
        if let trust {
            do {
                try trust.accept(candidate)
            } catch {
                throw MedicalCatalogUpdateError.catalogRolledBack
            }
        }
        guard candidate.packageSize > 0, candidate.packageSize <= limits.maxPackageBytes else {
            throw MedicalCatalogUpdateError.packageTooLarge
        }

        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let work = directory.appendingPathComponent(".medical-catalog-work-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw MedicalCatalogUpdateError.insufficientStorage
        }
        defer { try? fileManager.removeItem(at: work) } // try?-ok: 工作目录清理失败不掩盖主错误，下次更新前不复用
        // 工作集 = 加密包 + 解密 zip（明文 ≤ 密文）+ 解压 sqlite；sqlite 尺寸在解压处按
        // 声明值复核（MedicalCatalogPackageExtractor），此处补齐「zip 中间件」这一此前
        // 无人守卫的缺口（2026-09-26 审查修复：原预检只算 packageSize，紧盘设备会在
        // 下载/解密完成后才在解压写盘处失败，白烧流量与 CPU）。
        try Self.requireFreeSpace(candidate.packageSize * 2, at: work)

        let package = work.appendingPathComponent("package.bin")
        let total = candidate.packageSize
        progress(.downloading(receivedBytes: 0, totalBytes: total))
        do {
            try await fetcher.fetch(assetName: candidate.packageAssetName, expectedSize: total, to: package) { received in
                progress(.downloading(receivedBytes: received, totalBytes: total))
            }
        } catch {
            throw Self.mapped(error, fallback: .downloadFailed)
        }
        try Self.checkCancellation()

        progress(.verifying)
        guard try Self.size(of: package, failing: .downloadFailed) == candidate.packageSize,
              try await Self.sha256(of: package) == candidate.packageSHA256 else {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
        try Self.checkCancellation()

        let sqlite = work.appendingPathComponent(MedicalCatalogReleaseProtocol.sqliteEntryName)
        do {
            try await opener.open(packageURL: package, sqliteURL: sqlite, maxSQLiteBytes: limits.maxSQLiteBytes)
        } catch {
            throw Self.mapped(error, fallback: .packageInvalid)
        }
        try Self.checkCancellation()
        let sqliteSize = try Self.size(of: sqlite, failing: .packageInvalid)
        guard sqliteSize > 0, sqliteSize <= limits.maxSQLiteBytes else { throw MedicalCatalogUpdateError.packageInvalid }
        guard try await Self.sha256(of: sqlite) == candidate.sqliteSHA256 else {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                // 审查修复（2026-09-26）：合并为单次只读打开的完整发布门，
                // 不再 validateRelease + smokeCheck 双开双扫。
                try MedicalCatalogStore.validateReleaseAndSmoke(path: sqlite,
                                                                schemaVersion: candidate.schemaVersion,
                                                                dataVersion: candidate.dataVersion)
            }.value
        } catch {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        try Self.checkCancellation()

        progress(.activating)
        try activate(verified: sqlite, candidate: candidate)
    }

    /// 自 journal.begin 起不再响应取消：替换 + 复开要么完成，要么恢复 last-good。
    private func activate(verified sqlite: URL, candidate: VerifiedMedicalCatalogCandidate) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent("medical-catalog-staging-\(UUID().uuidString).sqlite")
        do {
            try fileManager.moveItem(at: sqlite, to: staging)
        } catch {
            throw MedicalCatalogUpdateError.activationFailed
        }
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging) // try?-ok: 未激活的 staging 清理，不触碰 active
            }
        }
        let hasActive = fileManager.fileExists(atPath: destination.path)
        let backup = hasActive ? directory.appendingPathComponent(destination.lastPathComponent + Self.lastGoodSuffix) : nil
        do {
            if let backup {
                if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
                do {
                    try fileManager.linkItem(at: destination, to: backup)
                } catch {
                    try fileManager.copyItem(at: destination, to: backup)
                }
            }
        } catch {
            throw MedicalCatalogUpdateError.activationFailed
        }
        let pending = PendingActivation(candidate: candidate, stagingURL: staging,
                                        activeURL: destination, lastGoodBackupURL: backup)
        do {
            try journal?.begin(pending)
        } catch {
            throw MedicalCatalogUpdateError.activationFailed
        }
        guard Self.atomicRename(staging, to: destination) else { throw MedicalCatalogUpdateError.activationFailed }
        do {
            try activeCheck(destination)
        } catch {
            restoreLastGood(backup)
            throw MedicalCatalogUpdateError.activationFailed
        }
        do {
            try journal?.complete(pending)
        } catch {
            throw MedicalCatalogUpdateError.activationFailed
        }
    }

    /// 复开失败时尽力回滚；回滚本身失败时 journal 停留在 begin，交由启动恢复处理。
    private func restoreLastGood(_ backup: URL?) {
        if let backup {
            _ = Self.atomicRename(backup, to: destination)
            return
        }
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            return
        }
    }

    /// 同目录 `rename(2)`：目标路径原子地指向新 inode，已打开旧库的只读连接不受影响。
    private static func atomicRename(_ source: URL, to target: URL) -> Bool {
        rename(source.path, target.path) == 0
    }

    private static func mapped(_ error: Error, fallback: MedicalCatalogUpdateError) -> MedicalCatalogUpdateError {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        return error as? MedicalCatalogUpdateError ?? fallback
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw MedicalCatalogUpdateError.cancelled }
    }

    private static func size(of url: URL, failing failure: MedicalCatalogUpdateError) throws -> Int64 {
        do { return try fileSize(of: url) } catch { throw failure }
    }

    private static func sha256(of url: URL) async throws -> String {
        do {
            return try await Task.detached(priority: .userInitiated) { try StreamingFileHasher.sha256(of: url) }.value
        } catch {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
    }

    private static func requireFreeSpace(_ bytes: Int64, at url: URL) throws {
        let free: Int64?
        do {
            free = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        } catch {
            return
        }
        if let free, free < bytes { throw MedicalCatalogUpdateError.insufficientStorage }
    }
}

// MARK: - Transport

/// 只从固定 Release 地址取签名命名的包；redirect 逐跳过 HTTPS 主机白名单且限跳数，
/// 落盘字节超过签名 packageSize 即中止。
public struct URLSessionMedicalCatalogPackageFetcher: MedicalCatalogPackageFetching, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(assetName: String, expectedSize: Int64, to destination: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard expectedSize > 0, let url = MedicalCatalogReleaseProtocol.packageURL(assetName: assetName) else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let transfer = MedicalCatalogPackageTransfer(expectedBytes: expectedSize, onBytes: progress)
        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(for: request, delegate: transfer)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw transfer.resolve(error)
        }
        defer { try? FileManager.default.removeItem(at: location) } // try?-ok: URLSession 临时文件清理
        if let failure = transfer.failure { throw failure }
        try transfer.validate(response)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        guard try MedicalCatalogUpdateService.fileSize(of: destination) == expectedSize else {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
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

/// AgeKit（X25519）解密 + 单 entry ZIP 解包。identity 文本由 App 发布配置注入，
/// 仓库内不保存私钥。
public struct AgeKitMedicalCatalogPackageOpening: MedicalCatalogPackageOpening, Sendable {
    private let identityText: Data

    public init(identityText: String) {
        self.identityText = Data(identityText.utf8)
    }

    public func open(packageURL: URL, sqliteURL: URL, maxSQLiteBytes: Int64) async throws {
        let zipURL = sqliteURL.deletingLastPathComponent()
            .appendingPathComponent("medical-catalog-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) } // try?-ok: 解密中间件清理
        try decrypt(packageURL, to: zipURL)
        try MedicalCatalogPackageExtractor.extractSQLite(from: zipURL, to: sqliteURL, maxSQLiteBytes: maxSQLiteBytes)
    }

    /// age 明文不大于密文，超出即拒绝。AgeKit `StreamReader` 没有 EOF 信号：只有末块可短于
    /// 64 KiB；明文恰为整块倍数时，末块后的下一次读取抛错即流结束——截断/篡改由已校验的
    /// 包 SHA 与随后的 ZIP CRC、SQLite SHA 兜底。
    private func decrypt(_ packageURL: URL, to zipURL: URL) throws {
        let limit = try MedicalCatalogUpdateService.fileSize(of: packageURL)
        guard let input = InputStream(url: packageURL) else { throw MedicalCatalogUpdateError.packageInvalid }
        let keyInput = InputStream(data: identityText)
        input.open()
        keyInput.open()
        defer { input.close(); keyInput.close() }
        let identities = try Age.parseIdentities(input: keyInput)
        guard identities.count == 1, let identity = identities.first else {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        var reader = try Age.decrypt(src: input, identities: identity)
        guard FileManager.default.createFile(atPath: zipURL.path, contents: nil) else {
            throw MedicalCatalogUpdateError.insufficientStorage
        }
        let output = try FileHandle(forWritingTo: zipURL)
        defer { try? output.close() } // try?-ok: 写句柄关闭失败由后续 ZIP 解析判红
        let chunk = 64 * 1024
        var written: Int64 = 0
        var lastReadFilled = false
        // 审查修复（2026-09-26）：缓冲提升到循环外——此前每轮分配一个 64KB Data
        // （百 MB 包 ≈ 数千次分配/清零/ARC 抖动），reader.read(&buffer) 从首字节覆写，
        // 复用语义不变（重构前旧实现即如此）。
        var buffer = Data(count: chunk)
        while true {
            let count: Int
            do {
                count = try reader.read(&buffer)
            } catch {
                guard written > 0, lastReadFilled else { throw error }
                break
            }
            guard count > 0 else { break }
            written += Int64(count)
            guard written <= limit else { throw MedicalCatalogUpdateError.packageInvalid }
            try output.write(contentsOf: buffer.prefix(count))
            lastReadFilled = count == chunk
            if !lastReadFilled { break }
        }
        try output.synchronize()
    }
}

/// 包内必须恰好一个普通文件 `medical-catalog.sqlite`；声明大小与实际解压字节双重限额，
/// 目标文件独占创建，任何失败都不留下半成品。
enum MedicalCatalogPackageExtractor {
    static func extractSQLite(from zipURL: URL, to sqliteURL: URL, maxSQLiteBytes: Int64) throws {
        let fileManager = FileManager.default
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        var entries = archive.makeIterator()
        guard let entry = entries.next(), entries.next() == nil,
              entry.path == MedicalCatalogReleaseProtocol.sqliteEntryName, entry.type == .file,
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
