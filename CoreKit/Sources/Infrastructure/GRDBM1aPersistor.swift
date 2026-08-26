#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// M1a 生产持久化（评审修正：owner/consent/timeline 落 §4.3 对应表，
/// 不再整体塞 UserDefaults）：
///   LocalOwner           → local_owner（+ PatientProfile → patient_profile）
///   ConsentRecord        → consent_record
///   TimelineDocumentEntry→ document_file（meta_json 承载投影元数据）
public actor GRDBM1aPersistor: M1aPersisting {
    private let store: GRDBStore

    public init(store: GRDBStore) { self.store = store }

    private var writer: any DatabaseWriter { store.writer }

    public func loadOwner() async throws -> LocalOwner? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM local_owner LIMIT 1") else { return nil }
            return LocalOwner(
                id: UUID(uuidString: row["id"] as String) ?? UUID(),
                displayName: row["display_name"] as String,
                selfPatientId: (row["self_patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                createdAt: row["created_at"] as Double)
        }
    }

    public func saveOwner(_ owner: LocalOwner, profile: PatientProfile) async throws {
        try await writer.write { db in
            // §4.2 明示纪律：FK 插入顺序不可调换（foreign_keys=ON 下违反即抛错回滚）——
            // local_owner.self_patient_id REFERENCES patient_profile，故 patient_profile 先落库
            try db.execute(
                sql: """
                INSERT INTO patient_profile
                  (id, owner_local_id, display_name, relation, gender, birth_date, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [profile.id.uuidString, owner.id.uuidString, profile.displayName,
                            profile.relation, profile.gender, profile.birthDate, profile.note,
                            profile.createdAt, profile.updatedAt])
            try db.execute(
                sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, ?, ?, ?)",
                arguments: [owner.id.uuidString, owner.displayName,
                            owner.selfPatientId?.uuidString, owner.createdAt])
        }
    }

    public func loadConsents() async throws -> [ConsentRecord] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM consent_record ORDER BY accepted_at").map { row in
                ConsentRecord(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                              key: row["key"] as String,
                              level: row["level"] as Int,
                              version: row["version"] as String,
                              acceptedAt: row["accepted_at"] as Double)
            }
        }
    }

    public func saveConsent(_ c: ConsentRecord) async throws {
        // 去重由调用侧按 key 保证（AppState.advanceDisclosure）；此处用普通 INSERT——
        // OR IGNORE 会静默吞掉外键/约束失败（ERR#35 防复发纪律：FK 写入禁用 IGNORE 语义）
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO consent_record (id, key, level, version, accepted_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [c.id.uuidString, c.key, c.level, c.version, c.acceptedAt])
        }
    }

    public func loadTimeline() async throws -> [TimelineDocumentEntry] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT meta_json FROM document_file
                WHERE meta_json IS NOT NULL ORDER BY created_at DESC
                """)
            var out: [TimelineDocumentEntry] = []
            for row in rows {
                guard let json = row["meta_json"] as String?,
                      let data = json.data(using: .utf8) else { continue }
                // 单条损坏元数据跳过，不拖垮整轴（§7 禁 try?，显式降级）
                do { out.append(try JSONDecoder().decode(TimelineDocumentEntry.self, from: data)) }
                catch { continue }
            }
            return out
        }
    }

    public func saveTimeline(_ entries: [TimelineDocumentEntry]) async throws {
        try await writer.write { db in
            for e in entries {
                let meta = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? "{}"
                // UPSERT 而非 INSERT OR REPLACE：REPLACE=先删后插，会触发 FK 级联语义
                // （ERR#35 纪律：FK 写入禁用 IGNORE/REPLACE）
                try db.execute(
                    sql: """
                    INSERT INTO document_file
                      (id, patient_id, doc_type, sha256, mime_type, origin, meta_json, created_at, updated_at)
                    VALUES (?, ?, 'ocr_document', ?, 'application/json', 'scanner', ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET meta_json = excluded.meta_json,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [e.id.uuidString, e.patientId.uuidString,
                                "sha:" + e.id.uuidString, meta, e.occurredAt, e.occurredAt])
            }
        }
    }

    /// UI 测试清态：清空 M1a 相关业务表（保留 schema，等价首次安装）
    public func reset() async throws {
        try await writer.write { db in
            for table in ["document_file", "consent_record", "patient_profile",
                          "local_owner", "audit_event"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
#endif
