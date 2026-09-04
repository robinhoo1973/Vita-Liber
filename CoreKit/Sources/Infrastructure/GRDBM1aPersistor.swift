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
            // §4.2 明示纪律：FK 插入顺序不可调换。local_owner.self_patient_id 与
            // patient_profile.owner_local_id 互为环——同事务三段式破环：
            // ① patient_profile 落库（owner_local_id 暂空）② local_owner 落库（回指 profile）
            // ③ 回填 patient_profile.owner_local_id。任一步失败整体回滚。
            try db.execute(
                sql: """
                INSERT INTO patient_profile
                  (id, owner_local_id, display_name, relation, gender, birth_date, note, created_at, updated_at)
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [profile.id.uuidString, profile.displayName,
                            profile.relation, profile.gender, profile.birthDate, profile.note,
                            profile.createdAt, profile.updatedAt])
            try db.execute(
                sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, ?, ?, ?)",
                arguments: [owner.id.uuidString, owner.displayName,
                            owner.selfPatientId?.uuidString, owner.createdAt])
            try db.execute(
                sql: "UPDATE patient_profile SET owner_local_id = ? WHERE id = ?",
                arguments: [owner.id.uuidString, profile.id.uuidString])
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

    public func saveMember(_ profile: PatientProfile) async throws {
        try store.insert(profile: profile)
    }

    public func members() async throws -> [PatientProfile] {
        try await store.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, display_name, relation, gender, birth_date, blood_type, id_no, insurance_no,
                       note, created_at, updated_at
                FROM patient_profile WHERE deleted_at IS NULL ORDER BY created_at ASC
                """)
            return rows.map { row in
                PatientProfile(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    displayName: row["display_name"] as String,
                    relation: row["relation"] as String,
                    gender: row["gender"] as String?,
                    birthDate: row["birth_date"] as String?,
                    bloodType: row["blood_type"] as String?,
                    idNo: row["id_no"] as String?,
                    insuranceNo: row["insurance_no"] as String?,
                    note: row["note"] as String?,
                    createdAt: row["created_at"] as Double,
                    updatedAt: row["updated_at"] as Double)
            }
        }
    }

    /// FR3.1 成员字段更新（血型/证件号/医保号/备注等补全）
    public func updateMember(_ profile: PatientProfile) async throws {
        try await store.writer.write { db in
            try db.execute(sql: """
                UPDATE patient_profile
                SET display_name = ?, relation = ?, gender = ?, birth_date = ?,
                    blood_type = ?, id_no = ?, insurance_no = ?, note = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """, arguments: [profile.displayName, profile.relation, profile.gender,
                                   profile.birthDate, profile.bloodType, profile.idNo,
                                   profile.insuranceNo, profile.note,
                                   profile.updatedAt, profile.id.uuidString])
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

    /// FR6.1 OCR 结果独立存储（与 notes 解耦）：每次识别记录原文块、置信度、
    /// 来源文件、识别时间、引擎版本——识别留痕与确认流解耦，可追溯。
    /// 签名与 M1aPersisting 协议**精确一致**（额外便捷参数只放协议扩展，
    /// 不在此处加默认参数——协议一致性与默认参数不兼容，评审修正）。
    public func saveOCRResult(documentId: UUID, fields: [CandidateField],
                              engineVersion: String) async throws {
        let now = Date()
        try await writer.write { db in
            for field in fields {
                try db.execute(sql: """
                    INSERT INTO ocr_result
                      (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
                    VALUES (?, ?, 0, ?, ?, ?)
                    """, arguments: [UUID().uuidString, documentId.uuidString,
                                     "\(field.key): \(field.rawText) [confidence=\(field.confidence)]",
                                     engineVersion, now.timeIntervalSince1970])
            }
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

    /// UI 测试清态：清空全部业务表（保留 schema，等价首次安装）。
    /// FK 安全顺序（评审修正，两轮）：① 此前仅清 M1a 五表，M1b/M1c 数据存在时
    /// DELETE patient_profile 即 FK 违规、整事务回滚，「测试清态」静默失效；
    /// ② 子表之间亦有引用（medication_plan→medication、dose_lot_allocation→stock_lot、
    /// immunization→allergy_event、patient_profile→local_owner/asset 等）——
    /// 顺序为拓扑序：最末级子表在前，父表在后；patient_profile 在 local_owner 之前
    /// （local_owner.self_patient_id 引用它），asset 在 patient_profile 之后（它被其引用）。
    /// FR22.4 数据与存储健康：PRAGMA 读取逻辑库大小与完整性（内存库同口径可用）。
    public func databaseHealth() async throws -> (sizeBytes: Int64, integrityOK: Bool) {
        try await writer.read { db -> (Int64, Bool) in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let rows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            let ok = rows.allSatisfy { $0 == "ok" }
            return (pages * pageSize, ok)
        }
    }

    public func reset() async throws {
        try await writer.write { db in
            let ordered = [
                // 最末级子表（不被他表引用，或被更末级引用）
                "ai_message", "dose_lot_allocation", "notification_delivery", "stock_lot",
                "ocr_result", "claim_item", "prescription", "encounter_question", "voice_note",
                "immunization", "allergy_event", "observation", "document_file", "medication_plan",
                "medication_dose_log", "sent_message", "emergency_card_selection", "contact",
                "metric_sample", "alert_event", "guideline_source", "ai_conversation", "reminder",
                "medication", "encounter", "health_problem", "appointment",
                // local_owner 子表
                "consent_record", "device_identity", "onboarding_progress",
                // 父表
                "audit_event", "patient_profile", "local_owner", "asset",
            ]
            for table in ordered {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
#endif
