import Foundation

/// 启动数据库决策（纯函数，零框架）。
///
/// 事实优先级（不可反转）：
/// 1. 物理库文件是否存在、大小、SQLite 头、`PRAGMA user_version`、核心表；
/// 2. 代码内 `SchemaMigrations.latestVersion`；
/// 3. `app-local-schema-history.sqlite` 的观测值只作诊断，**不参与本决策**。
///
/// 任何“无法证明安全”的状态都 fail-closed（`corrupt` / `tooNew` /
/// `missingWithOriginals`），绝不静默建空库覆盖患者数据。
public struct DatabaseProbeSnapshot: Sendable, Equatable {
    public let exists: Bool
    public let sizeBytes: Int64
    public let headerValid: Bool
    /// nil = 文件可读但 `PRAGMA user_version` 取不到。
    public let observedVersion: Int?
    public let tableCount: Int
    public let requiredTablesPresent: Int
    public let requiredTablesExpected: Int
    public let originalsPresent: Bool

    public init(exists: Bool, sizeBytes: Int64, headerValid: Bool,
                observedVersion: Int?, tableCount: Int,
                requiredTablesPresent: Int, requiredTablesExpected: Int,
                originalsPresent: Bool) {
        self.exists = exists
        self.sizeBytes = sizeBytes
        self.headerValid = headerValid
        self.observedVersion = observedVersion
        self.tableCount = tableCount
        self.requiredTablesPresent = requiredTablesPresent
        self.requiredTablesExpected = requiredTablesExpected
        self.originalsPresent = originalsPresent
    }

    public var hasAllRequiredTables: Bool {
        requiredTablesExpected > 0 && requiredTablesPresent == requiredTablesExpected
    }
}

public enum DatabaseBootDecision: Sendable, Equatable {
    /// 文件不存在（或合法空库）且没有原件证据：跑 baseline 建新库。
    case fresh
    case ready(version: Int)
    case migrate(from: Int, to: Int)
    /// 旧二进制打开更新 schema：只读降级，不可当作“无需迁移”。
    case tooNew(found: Int, supported: Int)
    /// 原件仍在但主库缺失：可能是外部删除/损坏，禁止自动重建。
    case missingWithOriginals
    case corrupt(CorruptReason)

    public enum CorruptReason: String, Sendable, Equatable {
        case emptyFile
        case badHeader
        case unreadableVersion
        case versionZeroWithTables
        case missingRequiredTables
    }
}

public enum DatabaseBootPolicy {
    /// 核心表探针：版本号说“最新”但核心表缺失时仍必须失败（用户库可能被替换/半恢复）。
    public static let requiredTables = ["patient_profile", "app_settings", "document_file"]

    public static func decide(_ probe: DatabaseProbeSnapshot,
                              supportedVersion: Int) -> DatabaseBootDecision {
        guard probe.exists else {
            return probe.originalsPresent ? .missingWithOriginals : .fresh
        }
        guard probe.sizeBytes > 0 else { return .corrupt(.emptyFile) }
        guard probe.headerValid else { return .corrupt(.badHeader) }
        guard let version = probe.observedVersion else { return .corrupt(.unreadableVersion) }

        if version > supportedVersion {
            return .tooNew(found: version, supported: supportedVersion)
        }
        if version == 0 {
            guard probe.tableCount == 0 else { return .corrupt(.versionZeroWithTables) }
            // 空 SQLite 文件 + 原件仍在：与文件缺失同风险（半恢复/外部工具产物），
            // 不得静默重建覆盖患者数据（2026-10-27 审查 P2）。
            return probe.originalsPresent ? .missingWithOriginals : .fresh
        }
        guard probe.hasAllRequiredTables else { return .corrupt(.missingRequiredTables) }
        if version < supportedVersion {
            return .migrate(from: version, to: supportedVersion)
        }
        return .ready(version: version)
    }
}
