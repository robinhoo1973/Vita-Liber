import Foundation

/// 目录激活的可恢复日志：`begin`/`complete` 括住 `MedicalCatalogUpdateService`
/// 的原子替换窗口（staging → 同卷 `rename(2)` → 复开）；App 启动时
/// `recoverBeforeOpen` 必须在 `MedicalCatalogStore` 打开前跑一遍，把窗口内
/// 任一步的崩溃收敛到"旧库可读"或"新库已验证生效"两态之一——患者主库
/// 全程不参与，本类型只触碰独立目录库文件。
///
/// 平台中立 Foundation 实现（Linux 可编译可测）：SQLite schema/meta 复核门
/// （GRDB，Apple-only）经 `verifyInstalled` 闭包注入，SHA-256 经 `sha256` 闭包
/// 注入（ADR-025：加密原语不得自研，生产实现走 CryptoKit）。生产装配（真实
/// `StreamingFileHasher` + `MedicalCatalogStore.validateRelease`）见
/// `MedicalCatalogActivationJournal+Apple.swift`。
public struct MedicalCatalogActivationJournal: MedicalCatalogActivationJournaling, Sendable {
    public enum RecoveryOutcome: Sendable, Equatable {
        /// 未发现待恢复的 journal：无更新在途，或上次更新已正常 complete。
        case clean
        /// journal 存在，复核确认 active 已是本次候选的新库并已完成收尾。
        case completedActivation
        /// journal 存在，复核判定新态不可信（或本就未换过），已回到旧库。
        case restoredLastGood
    }

    public enum Failure: Error, Equatable {
        /// journal 内容损坏、超限或 schema 版本不认识——拒绝盲目相信其中的路径。
        case invalidState
        /// journal 记录的路径解析后不落在目录库支持目录内——拒绝跨目录/跨卷操作。
        case pathEscape
        /// 记录着"曾有旧库"，但当前 active 与 last-good 备份都无法复核为该旧库，
        /// 且不存在把状态安全归零的路径——需要人工/运维介入，绝不静默吞掉。
        /// 抛出前 active 上不可信的字节已被隔离（quarantine 改名或删除），
        /// 调用方必须把本次抛出当作"绝不打开目录库"处理。
        case irrecoverable
    }

    private static let journalSchemaVersion = 1
    private static let maxBytes = 16 * 1024
    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)
    /// ISO 8601 基本形式（无冒号，文件名安全）：`quarantineUnverifiedActive` 用它给
    /// 隔离文件命名，避免扩展形式的 `:` 在文件名里造成任何文件系统兼容性问题。
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
    /// Apple-only schema/meta 复核门：`(path, candidateSchemaVersion, candidateDataVersion)`。
    /// Linux 测试宿主可传 nil——header+size+SHA 仍会跑，只是跳过 GRDB 复开。
    private let verifyInstalled: (@Sendable (_ path: URL, _ schemaVersion: Int, _ dataVersion: String) throws -> Void)?

    public init(journalURL: URL, supportDirectory: URL,
                sha256: @escaping @Sendable (URL) throws -> String,
                verifyInstalled: (@Sendable (_ path: URL, _ schemaVersion: Int, _ dataVersion: String) throws -> Void)? = nil) {
        self.journalURL = journalURL
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.sha256 = sha256
        self.verifyInstalled = verifyInstalled
    }

    // MARK: - MedicalCatalogActivationJournaling

    /// 只在全部校验门通过后、原子替换前调用（见 `MedicalCatalogUpdateService+Install.swift`
    /// `activate(verified:candidate:)`）。记录旧 active 的哈希（可能为 nil——首次安装无旧库），
    /// 落盘失败即整条更新链路判红，绝不进入原子替换。
    public func begin(_ pending: PendingActivation) throws {
        try Self.requireUnderSupport(pending.stagingURL, supportDirectory: supportDirectory)
        try Self.requireUnderSupport(pending.activeURL, supportDirectory: supportDirectory)
        if let backup = pending.lastGoodBackupURL {
            try Self.requireUnderSupport(backup, supportDirectory: supportDirectory)
        }
        let priorActiveSHA256 = try hashIfPresent(pending.activeURL)
        let record = Record(
            journalSchemaVersion: Self.journalSchemaVersion,
            activePath: pending.activeURL.path,
            stagingPath: pending.stagingURL.path,
            lastGoodBackupPath: pending.lastGoodBackupURL?.path,
            priorActiveSHA256: priorActiveSHA256,
            candidateCatalogVersion: pending.candidate.catalogVersion,
            candidateDataVersion: pending.candidate.dataVersion,
            candidateSQLiteSchemaVersion: pending.candidate.schemaVersion,
            candidateSQLiteSHA256: pending.candidate.sqliteSHA256,
            candidateSignedPointerDigest: pending.candidate.signedPointerDigest)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxBytes else { throw Failure.invalidState }
        try MedicalCatalogSupportFile.write(data, to: journalURL)
    }

    /// 在原子替换 + 复开都成功之后调用：journal 与 last-good 备份都只剩清理价值——
    /// 删除失败不掩盖已生效的目录（下次 `recoverBeforeOpen` 会幂等收尾）。
    public func complete(_ pending: PendingActivation) throws {
        removeIfPresent(journalURL)
        if let backup = pending.lastGoodBackupURL { removeIfPresent(backup) }
    }

    // MARK: - Recovery

    /// App 启动时、`MedicalCatalogStore(path:)` 打开前调用。只读本地文件，不发起任何网络。
    /// 复核而非信任 journal 记录的路径与哈希：路径须落在 `supportDirectory` 内，
    /// 数据须经 SQLite 头部 + 大小 + SHA-256（+ Apple 平台 schema/meta）复核。
    public func recoverBeforeOpen(catalogURL: URL) throws -> RecoveryOutcome {
        guard let data = MedicalCatalogSupportFile.read(journalURL, maxBytes: Self.maxBytes) else { return .clean }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw Failure.invalidState
        }
        guard record.journalSchemaVersion == Self.journalSchemaVersion else { throw Failure.invalidState }

        let active = URL(fileURLWithPath: record.activePath)
        let staging = URL(fileURLWithPath: record.stagingPath)
        let backup = record.lastGoodBackupPath.map(URL.init(fileURLWithPath:))
        try Self.requireUnderSupport(active, supportDirectory: supportDirectory)
        try Self.requireUnderSupport(staging, supportDirectory: supportDirectory)
        if let backup { try Self.requireUnderSupport(backup, supportDirectory: supportDirectory) }
        guard active.standardizedFileURL.path == catalogURL.standardizedFileURL.path else { throw Failure.invalidState }

        // 分支一：active 仍是（或又变回了）旧库——替换从未发生，或原进程内
        // activeCheck 失败已把 backup 换回 active。journal 只剩清理价值。
        if try matches(active, expectedSHA256: record.priorActiveSHA256) {
            removeIfPresent(staging)
            if let backup { removeIfPresent(backup) }
            removeIfPresent(journalURL)
            return .restoredLastGood
        }

        // 分支二：active 是本次候选的新库字节——独立复核（不信任原进程的 activeCheck
        // 结果），全部通过才视为「已完成」。
        if try matches(active, expectedSHA256: record.candidateSQLiteSHA256),
           try passesInstalledGate(active, record: record) {
            if let backup { removeIfPresent(backup) }
            removeIfPresent(journalURL)
            return .completedActivation
        }

        // 分支三：active 既非旧也非已验证的新——用 last-good 兜底。
        if let backup, try matches(backup, expectedSHA256: record.priorActiveSHA256) {
            guard Self.atomicRename(backup, to: active) else { throw Failure.irrecoverable }
            removeIfPresent(staging)
            removeIfPresent(journalURL)
            return .restoredLastGood
        }
        if record.priorActiveSHA256 == nil {
            // 从未有旧库（首次安装），不可信的新文件不留在原地——回到"未安装"
            // 这一同样合法的旧态，而不是拿一份未经验证的库开门。
            removeIfPresent(active)
            removeIfPresent(staging)
            removeIfPresent(journalURL)
            return .restoredLastGood
        }
        // 记录着"曾有旧库"，但 active 与 last-good 备份都无法复核为该旧库——不存在
        // 能安全归零的路径。绝不能把不可信字节留在 active 路径上任由调用方随后打开：
        // 同目录改名到 quarantine（失败则直接删除），journal 原样保留以便诊断
        // （调用方——AppContainer——必须把本次抛出当作"绝不打开目录库"处理）。
        quarantineUnverifiedActive(active)
        throw Failure.irrecoverable
    }

    /// 把无法复核的 active 移出视线：同目录 `<active>.quarantine-<UTC 时间戳>` 改名；
    /// 改名失败（如跨设备/权限）则直接删除。两者都失败时函数静默返回——调用方
    /// 无论如何都会收到 `Failure.irrecoverable` 并且（按约定）绝不打开目录库，
    /// 这是"不可信 active 绝不被打开"这条不变式的最终兜底。
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

    // MARK: - Verification helpers

    private func matches(_ url: URL, expectedSHA256: String?) throws -> Bool {
        guard let expectedSHA256 else { return !FileManager.default.fileExists(atPath: url.path) }
        guard FileManager.default.fileExists(atPath: url.path), Self.hasSQLiteHeader(url) else { return false }
        return try sha256(url) == expectedSHA256
    }

    private func passesInstalledGate(_ url: URL, record: Record) throws -> Bool {
        guard let verifyInstalled else { return true }
        do {
            try verifyInstalled(url, record.candidateSQLiteSchemaVersion, record.candidateDataVersion)
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
        try? FileManager.default.removeItem(at: url) // try?-ok: 恢复态清理失败不改变已判定的 active/旧库状态，下次启动幂等重试
    }

    private static func hasSQLiteHeader(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() } // try?-ok: 只读句柄关闭失败由系统回收，不影响已读出的头部字节判断
        do {
            return try handle.read(upToCount: sqliteHeader.count) == sqliteHeader
        } catch {
            return false
        }
    }

    private static func atomicRename(_ source: URL, to target: URL) -> Bool {
        rename(source.path, target.path) == 0
    }

    /// 拒绝越过目录库支持目录的路径（穿越 `..`、指向其他卷/符号链接逃逸）；
    /// 两侧都做符号链接解析后再比较，避免 `/tmp` 之类的系统级符号链接误判。
    private static func requireUnderSupport(_ url: URL, supportDirectory: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = supportDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw Failure.pathEscape
        }
    }

    private struct Record: Codable {
        let journalSchemaVersion: Int
        let activePath: String
        let stagingPath: String
        let lastGoodBackupPath: String?
        let priorActiveSHA256: String?
        let candidateCatalogVersion: Int64
        let candidateDataVersion: String
        let candidateSQLiteSchemaVersion: Int
        let candidateSQLiteSHA256: String
        let candidateSignedPointerDigest: String
    }
}
