import Domain
import Foundation

/// 切片激活可恢复日志（每片一文件：`…/catalog/v5/app-catalog-<kind>-active-journal.json`）。
/// 与 v4 `MedicalCatalogActivationJournal` 同构同纪律：`begin`/`complete` 括住
/// staging → 同卷 `rename(2)` → 复开窗口；启动 `recoverBeforeOpen` 把窗口内任一
/// 步崩溃收敛到「旧库可读」或「新库已验证生效」两态——绝不把未复核字节留在 active。
///
/// 切片化差异：
/// - 记录**内容身份** = `catalogVersion + sqliteSHA256`（另存审计锚
///   `signedPayloadDigest`/`rootVersion`；同版异 sqlite = 回执/floor 层已拒）；
/// - schema/meta 复核门 `verifyInstalled: (URL) throws -> Void` 由 App 注入
///   （`CatalogSliceProbe`：slice_meta 契约 + 表集 + COUNT），本类型只做
///   SQLite 头 + 尺寸 + SHA 与分支收敛——纯 Foundation，Linux 可测。
///
/// 旧库（prior）分支不注入复核门：prior 身份由 journal 记录的 SHA-256 钉死，
/// 切片旧库的表集/计数随版本演进，事后无法用同一 manifest 复核。
public struct CatalogSliceActivationJournal: Sendable {
    public enum RecoveryOutcome: Sendable, Equatable {
        /// 未发现待恢复 journal：无安装在途，或上次安装已正常 complete。
        case clean
        /// journal 存在，复核确认 active 已是本次候选的新库并已完成收尾。
        case completedActivation
        /// journal 存在，复核判定新态不可信（或本就未换过），已回到旧库/未安装态。
        case restoredLastGood
    }

    public enum Failure: Error, Equatable {
        /// journal 内容损坏、超限或 schema 版本不认识。
        case invalidState
        /// journal 记录的路径解析后不落在切片支持目录内。
        case pathEscape
        /// 曾有旧库但 active 与 last-good 备份都无法复核——不可信 active 已隔离，
        /// 调用方必须把本次抛出当作「绝不打开该切片」处理。
        case irrecoverable
    }

    public struct Pending: Sendable, Equatable {
        public let kind: CatalogSliceKind
        public let catalogVersion: Int64
        public let rootVersion: Int64
        public let sqliteSHA256: String
        public let signedPayloadDigest: String
        public let stagingURL: URL
        public let activeURL: URL
        public let lastGoodBackupURL: URL?

        public init(kind: CatalogSliceKind, catalogVersion: Int64, rootVersion: Int64,
                    sqliteSHA256: String, signedPayloadDigest: String,
                    stagingURL: URL, activeURL: URL, lastGoodBackupURL: URL? = nil) {
            self.kind = kind
            self.catalogVersion = catalogVersion
            self.rootVersion = rootVersion
            self.sqliteSHA256 = sqliteSHA256
            self.signedPayloadDigest = signedPayloadDigest
            self.stagingURL = stagingURL
            self.activeURL = activeURL
            self.lastGoodBackupURL = lastGoodBackupURL
        }
    }

    private static let journalSchemaVersion = 1
    private static let maxBytes = 16 * 1024
    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)
    private static let quarantineTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private let journalURL: URL
    private let supportDirectory: URL
    private let sha256: @Sendable (URL) throws -> String
    private let verifyInstalled: (@Sendable (URL) throws -> Void)?

    public init(journalURL: URL, supportDirectory: URL,
                sha256: @escaping @Sendable (URL) throws -> String,
                verifyInstalled: (@Sendable (URL) throws -> Void)? = nil) {
        self.journalURL = journalURL
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.sha256 = sha256
        self.verifyInstalled = verifyInstalled
    }

    // MARK: - begin / complete

    /// 只在全部校验门通过后、原子替换前调用。落盘失败即整条安装链路判红。
    public func begin(_ pending: Pending) throws {
        try Self.requireUnderSupport(pending.stagingURL, supportDirectory: supportDirectory)
        try Self.requireUnderSupport(pending.activeURL, supportDirectory: supportDirectory)
        if let backup = pending.lastGoodBackupURL {
            try Self.requireUnderSupport(backup, supportDirectory: supportDirectory)
        }
        let priorActiveSHA256 = try hashIfPresent(pending.activeURL)
        let record = Record(
            journalSchemaVersion: Self.journalSchemaVersion,
            kind: pending.kind.rawValue,
            activePath: pending.activeURL.path,
            stagingPath: pending.stagingURL.path,
            lastGoodBackupPath: pending.lastGoodBackupURL?.path,
            priorActiveSHA256: priorActiveSHA256,
            catalogVersion: pending.catalogVersion,
            rootVersion: pending.rootVersion,
            sqliteSHA256: pending.sqliteSHA256,
            signedPayloadDigest: pending.signedPayloadDigest)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxBytes else { throw Failure.invalidState }
        try MedicalCatalogSupportFile.write(data, to: journalURL)
    }

    /// 原子替换 + 复开成功后调用：journal 与 last-good 备份只剩清理价值——
    /// 删除失败不掩盖已生效的切片（下次 `recoverBeforeOpen` 幂等收尾）。
    public func complete(_ pending: Pending) throws {
        removeIfPresent(journalURL)
        if let backup = pending.lastGoodBackupURL { removeIfPresent(backup) }
    }

    // MARK: - Recovery

    /// 该切片打开前调用（只读本地文件，不发起任何网络）。
    public func recoverBeforeOpen(catalogURL: URL) throws -> RecoveryOutcome {
        guard let data = MedicalCatalogSupportFile.read(journalURL, maxBytes: Self.maxBytes) else {
            return .clean
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw Failure.invalidState
        }
        guard record.journalSchemaVersion == Self.journalSchemaVersion,
              CatalogSliceKind(rawValue: record.kind) != nil,
              record.catalogVersion > 0, record.rootVersion >= 1,
              MedicalCatalogReleaseProtocol.isLowercaseSHA256(record.sqliteSHA256),
              MedicalCatalogReleaseProtocol.isLowercaseSHA256(record.signedPayloadDigest) else {
            throw Failure.invalidState
        }
        let active = URL(fileURLWithPath: record.activePath)
        let staging = URL(fileURLWithPath: record.stagingPath)
        let backup = record.lastGoodBackupPath.map(URL.init(fileURLWithPath:))
        try Self.requireUnderSupport(active, supportDirectory: supportDirectory)
        try Self.requireUnderSupport(staging, supportDirectory: supportDirectory)
        if let backup { try Self.requireUnderSupport(backup, supportDirectory: supportDirectory) }
        guard active.standardizedFileURL.path == catalogURL.standardizedFileURL.path else {
            throw Failure.invalidState
        }

        // 分支一：active 仍是旧库——替换从未发生。journal 只剩清理价值。
        if try matches(active, expectedSHA256: record.priorActiveSHA256) {
            removeIfPresent(staging)
            if let backup { removeIfPresent(backup) }
            removeIfPresent(journalURL)
            return .restoredLastGood
        }

        // 分支二：active 是候选新库字节——独立复核（不信任原进程结果）。
        if try matches(active, expectedSHA256: record.sqliteSHA256), passesInstalledGate(active) {
            if let backup { removeIfPresent(backup) }
            removeIfPresent(journalURL)
            return .completedActivation
        }

        // 分支三：active 既非旧也非已验证新——用 last-good 兜底。
        if let backup, try matches(backup, expectedSHA256: record.priorActiveSHA256) {
            guard Self.atomicRename(backup, to: active) else { throw Failure.irrecoverable }
            removeIfPresent(staging)
            removeIfPresent(journalURL)
            return .restoredLastGood
        }
        if record.priorActiveSHA256 == nil {
            // 首次安装：不可信的新文件回到「未安装」合法旧态。
            removeIfPresent(active)
            removeIfPresent(staging)
            removeIfPresent(journalURL)
            return .restoredLastGood
        }
        // 曾有旧库但都无法复核：隔离不可信 active，journal 保留供诊断。
        quarantineUnverifiedActive(active)
        throw Failure.irrecoverable
    }

    // MARK: - Helpers

    private func quarantineUnverifiedActive(_ active: URL) {
        guard FileManager.default.fileExists(atPath: active.path) else { return }
        let timestamp = Self.quarantineTimestampFormatter.string(from: Date())
        let quarantined = active.deletingLastPathComponent()
            .appendingPathComponent(active.lastPathComponent + ".quarantine-" + timestamp)
        guard Self.atomicRename(active, to: quarantined) else {
            removeIfPresent(active)
            return
        }
    }

    private func matches(_ url: URL, expectedSHA256: String?) throws -> Bool {
        guard let expectedSHA256 else { return !FileManager.default.fileExists(atPath: url.path) }
        guard FileManager.default.fileExists(atPath: url.path), Self.hasSQLiteHeader(url) else {
            return false
        }
        let size: Int64
        do {
            size = try MedicalCatalogUpdateService.fileSize(of: url)
        } catch {
            return false
        }
        guard size > 0, size <= MedicalCatalogUpdateLimits.standard.maxSQLiteBytes else { return false }
        return try sha256(url) == expectedSHA256
    }

    private func passesInstalledGate(_ url: URL) -> Bool {
        guard let verifyInstalled else { return true }
        do {
            try verifyInstalled(url)
            return true
        } catch {
            return false
        }
    }

    private func hashIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try sha256(url)
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url) // try?-ok: 恢复态清理失败不改变已判定状态，下次启动幂等重试
    }

    private static func hasSQLiteHeader(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() } // try?-ok: 只读句柄关闭失败由系统回收，不影响已读出的头部判断
        do {
            return try handle.read(upToCount: sqliteHeader.count) == sqliteHeader
        } catch {
            return false
        }
    }

    private static func atomicRename(_ source: URL, to target: URL) -> Bool {
        rename(source.path, target.path) == 0
    }

    private static func requireUnderSupport(_ url: URL, supportDirectory: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = supportDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw Failure.pathEscape
        }
    }

    private struct Record: Codable {
        let journalSchemaVersion: Int
        let kind: String
        let activePath: String
        let stagingPath: String
        let lastGoodBackupPath: String?
        let priorActiveSHA256: String?
        let catalogVersion: Int64
        let rootVersion: Int64
        let sqliteSHA256: String
        let signedPayloadDigest: String
    }
}
