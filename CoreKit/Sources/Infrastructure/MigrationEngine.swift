import Foundation
import Domain

/// v1(flutter JSON) → v2 迁移引擎 · R0-2 只读降级（M0 Sprint-1：结构 + 两类金样）
public enum MigrationOutcome: Sendable, Equatable {
    case migrated(count: Int)
    case degraded                      // 损坏 JSON → 只读降级，绝不落种子数据
}

public enum MigrationEngine {
    public static func migrate(recordsJSON data: Data) -> MigrationOutcome {
        do { return .migrated(count: try JSONDecoder().decode([LegacyRecord].self, from: data).count) }
        catch { return .degraded }
    }

    /// §4.3 Schema v2 全量建表（V3.40，dev-pm §3.1 M0 第 5 条）：
    /// 含 stock_lot / dose_lot_allocation / medication / medication_plan /
    /// medication_dose_log 等 FR9.10-9.14 依赖的表——批次表属 schema 基础设施，
    /// 不推迟到 M1b。外键开启落在连接层 `Configuration.foreignKeysEnabled`
    /// （GRDBStore），不依赖事后 PRAGMA。
    /// 旧名 schemaV1 保留为兼容引用，语义即「v2 全量建表」。
    public static let schemaV1 = SchemaV2.ddl
}
