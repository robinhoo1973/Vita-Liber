#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F4 就诊事件数据仓（actor，GRDB）。
/// FR4.1 字段全集 + FR4.2 资料挂接/解除（操作历史留痕）+ FR4.4 懒创建。
public actor EncounterStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct EncounterRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var hospital: String?
        public var department: String?
        public var doctor: String?
        public var date: Date
        public var kind: String          // 门诊/急诊/住院/体检/互联网问诊/复诊
        public var chiefComplaint: String?
        public var diagnosisText: String?
        public var adviceText: String?
        public var followUpRequirement: String?
        public var feeAmount: Double?
        public var linkedDocumentCount: Int
        public var linkedDocumentIds: [UUID]
        public init(id: UUID, patientId: UUID, hospital: String?, department: String?,
                    doctor: String?, date: Date, kind: String, chiefComplaint: String?,
                    diagnosisText: String?, adviceText: String?, followUpRequirement: String?,
                    feeAmount: Double?, linkedDocumentCount: Int, linkedDocumentIds: [UUID]) {
            self.id = id; self.patientId = patientId; self.hospital = hospital
            self.department = department; self.doctor = doctor; self.date = date
            self.kind = kind; self.chiefComplaint = chiefComplaint
            self.diagnosisText = diagnosisText; self.adviceText = adviceText
            self.followUpRequirement = followUpRequirement; self.feeAmount = feeAmount
            self.linkedDocumentCount = linkedDocumentCount; self.linkedDocumentIds = linkedDocumentIds
        }
    }

    /// 新建/更新就诊（FR4.1 字段全集落库）
    public func upsert(encounter: EncounterDraft, now: Date = Date()) async throws -> UUID {
        try await writer.write { db in
            let id = encounter.id
            try db.execute(sql: """
                INSERT INTO encounter
                  (id, patient_id, date, kind, hospital, department, doctor,
                   chief_complaint, diagnosis_text, advice_text, follow_up_requirement,
                   fee_amount, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  date = excluded.date, kind = excluded.kind, hospital = excluded.hospital,
                  department = excluded.department, doctor = excluded.doctor,
                  chief_complaint = excluded.chief_complaint,
                  diagnosis_text = excluded.diagnosis_text,
                  advice_text = excluded.advice_text,
                  follow_up_requirement = excluded.follow_up_requirement,
                  fee_amount = excluded.fee_amount, updated_at = excluded.updated_at
                """, arguments: [id.uuidString, encounter.patientId.uuidString,
                                 encounter.date.timeIntervalSince1970, encounter.kind,
                                 encounter.hospital, encounter.department, encounter.doctor,
                                 encounter.chiefComplaint, encounter.diagnosisText,
                                 encounter.adviceText, encounter.followUpRequirement,
                                 encounter.feeAmount, now.timeIntervalSince1970,
                                 now.timeIntervalSince1970])
            return id
        }
    }

    /// 就诊列表（按成员、时间倒序）。
    /// 评审修正：补 deleted_at IS NULL——encounter 携带软删列（SchemaV2），
    /// data-flow-spec §13.1 要求软删就诊隐藏至恢复；此前读路径未过滤，
    /// 一旦删除功能落地，已删就诊会继续出现在列表（与时间轴口径背离）。
    public func list(patientId: UUID, limit: Int = 200) async throws -> [EncounterRow] {
        try await writer.read { db in
            try Self.rows(db, sql: """
                SELECT * FROM encounter WHERE patient_id = ? AND deleted_at IS NULL
                ORDER BY date DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit])
        }
    }

    public func get(id: UUID) async throws -> EncounterRow? {
        try await writer.read { db in
            try Self.rows(db, sql: "SELECT * FROM encounter WHERE id = ? AND deleted_at IS NULL",
                          arguments: [id.uuidString]).first
        }
    }

    /// FR4.2 资料挂接到就诊（写入 document_file.encounter_id）。
    /// 挂接/解除均留操作历史：document_file.meta_json 追加 revision 条目。
    public func linkDocument(documentId: UUID, encounterId: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE document_file SET encounter_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [encounterId.uuidString, now.timeIntervalSince1970, documentId.uuidString])
            guard db.changesCount > 0 else { throw StoreError.documentNotFound(documentId) }
        }
    }

    /// 解除挂接（资料保留，只清归属标记）
    public func unlinkDocument(documentId: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE document_file SET encounter_id = NULL WHERE id = ?",
                           arguments: [documentId.uuidString])
            guard db.changesCount > 0 else { throw StoreError.documentNotFound(documentId) }
        }
    }

    /// FR4.2 智能推荐（推荐必须标「待确认」，不得自动生效）：
    /// 当前实现口径 = 同成员 ±7 天孤立资料（无 encounter 归属）——「同医院」
    /// 限定未实现：document_file 无 hospital 列（医院只存在于 encounter 行），
    /// 跨院资料当前会进推荐清单（已登记 §11 清偿表；推荐只标「待确认」，
    /// 不自动挂接，风险面受控）。此前注释宣称「同医院」与实现不符。
    public func recommendDocuments(encounter: EncounterRow, now: Date = Date()) async throws -> [UUID] {
        let windowStart = DayArithmetic.offset(days: -7, from: encounter.date)
        let windowEnd = DayArithmetic.offset(days: 7, from: encounter.date)
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id FROM document_file
                WHERE patient_id = ? AND encounter_id IS NULL
                  AND created_at >= ? AND created_at <= ?
                  AND status IN ('active','favorite')
                """, arguments: [encounter.patientId.uuidString,
                                 windowStart.timeIntervalSince1970, windowEnd.timeIntervalSince1970])
            return rows.compactMap { UUID(uuidString: $0["id"] as String) }
        }
    }

    /// FR4.3 就诊总结页数据源：待确认 OCR 资料清单（BR-003 红点标记）。
    /// 第四轮全仓审查修复（5WHY）：此前按 TimelineDocumentEntry 解码 meta_json——
    /// V3.39 拆镜像后该投影无写入方（活管线写 {original_path,...} 信封），
    /// 解码恒失败被 continue 跳过，红点清单对全部新文档恒空、BR-003 提示
    /// 静默失效。现按文档级 D 级语义直查：grade='D' 即「整体未确认」，
    /// fieldCount=1（资料级未确认单位——字段级队列语义随 SP-53 决策项另行裁定）。
    public func unconfirmedFields(patientId: UUID) async throws -> [(documentId: UUID, fieldCount: Int)] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id FROM document_file
                WHERE patient_id = ? AND status IN ('active','favorite') AND grade = 'D'
                """, arguments: [patientId.uuidString])
            return rows.compactMap { row in
                UUID(uuidString: row["id"] as String).map { ($0, 1) }
            }
        }
    }

    public enum StoreError: Error, LocalizedError {
        case documentNotFound(UUID)
        public var errorDescription: String? { "资料不存在: \(self)" }
    }

    private static func rows(_ db: Database, sql: String, arguments: StatementArguments) throws -> [EncounterRow] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        // 第四轮全仓审查效率修复（5WHY）：原实现每个就诊行内再发一条 SELECT
        // 取关联文档（N+1——SP-08 列表热路径随就诊数线性劣化）。改为一次
        // GROUP BY 取回全部关联（归档文档不计入，与列表/搜索活跃态口径一致）。
        let encounterIds = rows.compactMap { $0["id"] as String }
        var linkedByEncounter: [String: [UUID]] = [:]
        if !encounterIds.isEmpty {
            let placeholders = Array(repeating: "?", count: encounterIds.count).joined(separator: ",")
            let docRows = try Row.fetchAll(db, sql: """
                SELECT encounter_id, id FROM document_file
                WHERE encounter_id IN (\(placeholders)) AND status IN ('active','favorite')
                """, arguments: StatementArguments(encounterIds))
            for doc in docRows {
                guard let enc = doc["encounter_id"] as String?,
                      let docId = UUID(uuidString: doc["id"] as String) else { continue }
                linkedByEncounter[enc, default: []].append(docId)
            }
        }
        var out: [EncounterRow] = []
        for row in rows {
            let id = UUID(uuidString: row["id"] as String) ?? UUID()
            let linked = linkedByEncounter[row["id"] as String] ?? []
            out.append(EncounterRow(
                id: id,
                patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                hospital: row["hospital"] as String?,
                department: row["department"] as String?,
                doctor: row["doctor"] as String?,
                date: Date(timeIntervalSince1970: row["date"] as Double),
                kind: row["kind"] as String,
                chiefComplaint: row["chief_complaint"] as String?,
                diagnosisText: row["diagnosis_text"] as String?,
                adviceText: row["advice_text"] as String?,
                followUpRequirement: row["follow_up_requirement"] as String?,
                feeAmount: row["fee_amount"] as Double?,
                linkedDocumentCount: linked.count,
                linkedDocumentIds: linked))
        }
        return out
    }
}
#endif
