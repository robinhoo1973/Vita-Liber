#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// FR17.14 VoiceNote 数据仓（actor，GRDB）：语音速记条目——成员/时间/正文/
/// 标签/可选挂接就诊/入轴开关。音频即用即弃（零落盘断言），只存转写文本。
public actor VoiceNoteStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func create(id: UUID = UUID(), patientId: UUID, body: String,
                       tags: [String]? = nil, encounterId: UUID? = nil,
                       inTimeline: Bool = true, now: Date = Date()) async throws {
        try await writer.write { db in
            let tagsJSON: String
            if let tags {
                do { tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]" }
                catch { tagsJSON = "[]" }
            } else {
                tagsJSON = "[]"
            }
            try db.execute(sql: """
                INSERT INTO voice_note (id, patient_id, body, occurred_at, tags, encounter_id, in_timeline, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, body,
                                 now.timeIntervalSince1970, tagsJSON,
                                 encounterId?.uuidString, inTimeline ? 1 : 0,
                                 now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }

    public struct VoiceNoteRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var body: String
        public var occurredAt: Date
        public var tags: [String]
        public init(id: UUID, body: String, occurredAt: Date, tags: [String]) {
            self.id = id; self.body = body; self.occurredAt = occurredAt; self.tags = tags
        }
    }

    public func list(patientId: UUID, limit: Int = 50) async throws -> [VoiceNoteRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, body, occurred_at, tags FROM voice_note
                WHERE patient_id = ? ORDER BY occurred_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map { row in
                let tags: [String] = (row["tags"] as String?).flatMap { json in
                    guard let data = json.data(using: .utf8) else { return [] }
                    do { return try JSONDecoder().decode([String].self, from: data) }
                    catch { return [] }
                } ?? []
                return VoiceNoteRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                                    body: row["body"] as String,
                                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                                    tags: tags)
            }
        }
    }
}
#endif
