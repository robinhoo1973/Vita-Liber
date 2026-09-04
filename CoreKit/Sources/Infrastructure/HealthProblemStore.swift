#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F11.4 健康问题管理（SP-49）数据仓：懒创建/手动新建/重命名/合并/归档/取消归档。
/// 归档问题不出现在默认筛选（FR11.2）；合并两问题历史不丢（合并 = 建新主问题 +
/// 原问题归档 + 关联数据转移，audit 由调用方记）。
public actor HealthProblemStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var name: String
        public var archived: Bool
        public init(id: UUID, patientId: UUID, name: String, archived: Bool) {
            self.id = id; self.patientId = patientId; self.name = name; self.archived = archived
        }
    }

    public func list(patientId: UUID, includeArchived: Bool = false) async throws -> [Row] {
        try await writer.read { db in
            let sql = includeArchived
                ? "SELECT * FROM health_problem WHERE patient_id = ? ORDER BY created_at DESC"
                : "SELECT * FROM health_problem WHERE patient_id = ? AND archived = 0 ORDER BY created_at DESC"
            return try Row.fetchAll(db, sql: sql, arguments: [patientId.uuidString]).map { row in
                Row(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: patientId,
                    name: row["name"] as String,
                    archived: (row["archived"] as Int) == 1)
            }
        }
    }

    /// 新建/懒创建（FR11.4：可从文档/观察/就诊懒创建或手动新建）
    @discardableResult
    public func create(patientId: UUID, name: String, now: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO health_problem (id, patient_id, name, kind, archived, created_at, updated_at)
                VALUES (?, ?, ?, NULL, 0, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, name,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }

    public func rename(id: UUID, to name: String, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE health_problem SET name = ?, updated_at = ? WHERE id = ?",
                           arguments: [name, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// 归档/取消归档（FR11.4：归档问题不出现在默认筛选；取消归档可恢复）
    public func setArchived(id: UUID, archived: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE health_problem SET archived = ?, updated_at = ? WHERE id = ?",
                           arguments: [archived ? 1 : 0, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// 合并：主问题保留、被合并问题归档（各自历史不丢——数据行不删除）。
    /// 关联数据转移（document/observation 的 problem 引用）由后续版本承载；
    /// 本方法保证「合并」语义的最小不变量：被合并问题从默认筛选消失。
    public func merge(primary: UUID, into secondary: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM health_problem WHERE id = ? AND archived = 0",
                                   arguments: [primary.uuidString]) != nil else {
                throw StoreError.notFound(primary)
            }
            try db.execute(sql: "UPDATE health_problem SET archived = 1, updated_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, secondary.uuidString])
        }
    }

    public enum StoreError: Error, LocalizedError {
        case notFound(UUID)
        public var errorDescription: String? { "健康问题不存在: \(self)" }
    }
}
#endif
