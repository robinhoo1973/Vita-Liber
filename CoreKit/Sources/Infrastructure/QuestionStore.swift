#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// FR10.5「我要问医生的问题」数据仓：随时记录，自动汇入最近的相关准备包。
/// 状态机 open → asked → dropped（问过/不再问），与 schema status CHECK 对齐。
public actor QuestionStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct QuestionRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var encounterId: UUID?
        public var body: String
        public var status: String       // open/asked/dropped
        public var askedAt: Date?
        public var createdAt: Date
        public init(id: UUID, patientId: UUID, encounterId: UUID?, body: String,
                    status: String, askedAt: Date?, createdAt: Date) {
            self.id = id; self.patientId = patientId; self.encounterId = encounterId
            self.body = body; self.status = status; self.askedAt = askedAt; self.createdAt = createdAt
        }
    }

    @discardableResult
    public func add(patientId: UUID, body: String, encounterId: UUID? = nil,
                    now: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO encounter_question (id, patient_id, encounter_id, body, asked_at, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, NULL, 'open', ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString,
                                 encounterId?.uuidString, body,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }

    public func list(patientId: UUID, status: String? = nil) async throws -> [QuestionRow] {
        try await writer.read { db in
            let statusClause = status.map { _ in "AND status = ?" } ?? ""
            var args: [DatabaseValueConvertible] = [patientId.uuidString]
            if let status { args.append(status) }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM encounter_question
                WHERE patient_id = ? \(statusClause)
                ORDER BY created_at DESC
                """, arguments: StatementArguments(args)).map { row in
                QuestionRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                    encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
                    body: row["body"] as String,
                    status: row["status"] as String,
                    askedAt: (row["asked_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
            }
        }
    }

    /// 标记已问（就诊后回填：问过即勾，FR10.4 准备包据此展示已办/未办）
    public func markAsked(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE encounter_question SET status = 'asked', asked_at = ?, updated_at = ? WHERE id = ?
                """, arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// 放弃该问题（不删除，状态 dropped——记录如实保留）
    public func drop(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE encounter_question SET status = 'dropped', updated_at = ? WHERE id = ?
                """, arguments: [now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// FR10.4 准备包数据源：未问问题（open 状态，最近 10 条）
    public func openQuestions(patientId: UUID, limit: Int = 10) async throws -> [QuestionRow] {
        try await list(patientId: patientId, status: "open").map { Array($0.prefix(limit)) } ?? []
    }
}
#endif
