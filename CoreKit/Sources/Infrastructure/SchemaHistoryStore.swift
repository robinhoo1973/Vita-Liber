#if os(iOS) || os(macOS)
// linux-blind: GRDB only links on Apple platforms; Linux compiles an empty unit.
import Foundation
import GRDB
import os

/// `app-local-schema-history.sqlite` 的唯一写入口。
///
/// **非权威**：本库只做版本目录投影 + 启动观测 + 迁移尝试记录。
/// 任何迁移决策都必须重读物理患者库的 `PRAGMA user_version`；
/// 本库损坏/缺失/写失败只影响诊断，不得阻断 App 启动。
public struct SchemaHistoryStore: Sendable {
    public struct RegistryEntry: Sendable, Equatable {
        public let name: String
        public let role: String
        public let description: String
    }

    public struct StepRecord: Sendable, Equatable {
        public let version: Int
        public let name: String
        public let kind: String
        public let sqlLength: Int
        public let transactional: Bool
        public let fkCheckTable: String?
    }

    public struct Observation: Sendable, Equatable {
        public let name: String
        public let role: String
        public let exists: Bool
        public let sizeBytes: Int64
        public let headerValid: Bool
        public let observedVersion: Int?
        public let requiredTables: Int
        public let observedAt: Date

        public init(name: String, role: String, exists: Bool, sizeBytes: Int64,
                    headerValid: Bool, observedVersion: Int?, requiredTables: Int,
                    observedAt: Date = Date()) {
            self.name = name
            self.role = role
            self.exists = exists
            self.sizeBytes = sizeBytes
            self.headerValid = headerValid
            self.observedVersion = observedVersion
            self.requiredTables = requiredTables
            self.observedAt = observedAt
        }
    }

    public struct Attempt: Sendable, Equatable {
        public let databaseName: String
        public let sourceVersion: Int?
        public let targetVersion: Int?
        public let outcome: String
        public let detail: String?
        public let observedAt: Date

        public init(databaseName: String, sourceVersion: Int?, targetVersion: Int?,
                    outcome: String, detail: String?, observedAt: Date = Date()) {
            self.databaseName = databaseName
            self.sourceVersion = sourceVersion
            self.targetVersion = targetVersion
            self.outcome = outcome
            self.detail = detail
            self.observedAt = observedAt
        }
    }

    public struct Contents: Sendable, Equatable {
        public let meta: [String: String]
        public let steps: [StepRecord]
        public let registry: [RegistryEntry]
        public let observations: [Observation]
        public let attempts: [Attempt]
    }

    public let path: String
    private let dbQueue: DatabaseQueue
    private static let logger = Logger(subsystem: "com.vitaliber", category: "schema-history")

    private init(path: String, dbQueue: DatabaseQueue) {
        self.path = path
        self.dbQueue = dbQueue
    }

    /// 业主 2026-10-25：启动时若历史库存在则清空，按代码内压缩 base64 SQL 重建。
    /// 删除旧文件而不是逐表 DELETE，确保旧列/旧触发器不会残留成“第二 schema”。
    public static func rebuild(at path: String,
                               fileManager: FileManager = .default) throws -> SchemaHistoryStore {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        for suffix in ("", "-wal", "-shm", "-journal") {
            let candidate = path + suffix
            if fileManager.fileExists(atPath: candidate) {
                try fileManager.removeItem(atPath: candidate)
            }
        }
        let seed = try SchemaHistorySeed.sql()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        do {
            try queue.write { db in
                try db.execute(sql: seed)
            }
        } catch {
            // 重建失败不留下半成品；调用方把历史库标记为不可用，患者库继续。
            try? fileManager.removeItem(atPath: path) // try?-ok: 清理半成品，不掩盖原始错误
            throw error
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values) // try?-ok: 备份排除失败不影响非权威库可用性
        logger.info("schema history rebuilt: \(url.lastPathComponent, privacy: .public)")
        return SchemaHistoryStore(path: path, dbQueue: queue)
    }

    public func contents() throws -> Contents {
        try dbQueue.read { db in
            let meta = try Row.fetchAll(db, sql: "SELECT key, value FROM schema_meta")
                .reduce(into: [String: String]()) { result, row in
                    result[row["key"] as String] = row["value"] as String
                }
            let steps = try Row.fetchAll(db, sql: """
                SELECT version, name, kind, length(sql) AS sql_length, transactional, fk_check_table
                FROM schema_step ORDER BY version
                """).map { row in
                    StepRecord(version: row["version"] as Int, name: row["name"] as String,
                               kind: row["kind"] as String,
                               sqlLength: row["sql_length"] as Int,
                               transactional: (row["transactional"] as Int) == 1,
                               fkCheckTable: row["fk_check_table"] as String?)
                }
            let registry = try Row.fetchAll(db, sql: """
                SELECT name, role, description FROM database_registry ORDER BY name
                """).map { row in
                    RegistryEntry(name: row["name"] as String, role: row["role"] as String,
                                  description: row["description"] as String)
                }
            let observations = try Row.fetchAll(db, sql: """
                SELECT name, role, exists_flag, size_bytes, header_valid, observed_version,
                       required_tables, observed_at
                FROM database_observation ORDER BY name
                """).map { row in
                    Observation(name: row["name"] as String, role: row["role"] as String,
                                exists: (row["exists_flag"] as Int) == 1,
                                sizeBytes: row["size_bytes"] as Int64,
                                headerValid: (row["header_valid"] as Int) == 1,
                                observedVersion: row["observed_version"] as Int?,
                                requiredTables: row["required_tables"] as Int,
                                observedAt: Date(timeIntervalSince1970: row["observed_at"] as Double))
                }
            let attempts = try Row.fetchAll(db, sql: """
                SELECT database_name, source_version, target_version, outcome, detail, observed_at
                FROM migration_attempt ORDER BY id
                """).map { row in
                    Attempt(databaseName: row["database_name"] as String,
                            sourceVersion: row["source_version"] as Int?,
                            targetVersion: row["target_version"] as Int?,
                            outcome: row["outcome"] as String,
                            detail: row["detail"] as String?,
                            observedAt: Date(timeIntervalSince1970: row["observed_at"] as Double))
                }
            return Contents(meta: meta, steps: steps, registry: registry,
                            observations: observations, attempts: attempts)
        }
    }

    public func record(_ observation: Observation) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO database_observation
                    (name, role, exists_flag, size_bytes, header_valid, observed_version,
                     required_tables, observed_at)
                VALUES
                    (:name, :role, :exists, :size, :header, :version, :required, :observedAt)
                ON CONFLICT(name) DO UPDATE SET
                    role = excluded.role,
                    exists_flag = excluded.exists_flag,
                    size_bytes = excluded.size_bytes,
                    header_valid = excluded.header_valid,
                    observed_version = excluded.observed_version,
                    required_tables = excluded.required_tables,
                    observed_at = excluded.observed_at
                """, arguments: [
                    "name": observation.name,
                    "role": observation.role,
                    "exists": observation.exists,
                    "size": observation.sizeBytes,
                    "header": observation.headerValid,
                    "version": observation.observedVersion,
                    "required": observation.requiredTables,
                    "observedAt": observation.observedAt.timeIntervalSince1970,
                ])
        }
    }

    /// append-only：每次启动重建会清空本表（业主“清空重建”语义），
    /// 因此它只记录**本次启动**的尝试；跨启动审计需另行立项。
    public func recordAttempt(_ attempt: Attempt) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO migration_attempt
                    (database_name, source_version, target_version, outcome, detail, observed_at)
                VALUES (:name, :source, :target, :outcome, :detail, :observedAt)
                """, arguments: [
                    "name": attempt.databaseName,
                    "source": attempt.sourceVersion,
                    "target": attempt.targetVersion,
                    "outcome": attempt.outcome,
                    "detail": attempt.detail,
                    "observedAt": attempt.observedAt.timeIntervalSince1970,
                ])
        }
    }
}
#endif
