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

    /// §4.3 Schema v1（节选；外键开启由连接层 PRAGMA 保证）
    public static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS patient_profile (
      id TEXT PRIMARY KEY, display_name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS document_file (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      title TEXT, created_at REAL NOT NULL);
    """
}
