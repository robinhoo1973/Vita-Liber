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

    /// FR6.9 期二：就诊的关联卡片（处方 / 收费票据）——卡片互联的**读面**。
    /// 事实源与写入侧同一：`prescription.encounter_id` / `claim_item.encounter_id`
    /// 单向引用就诊（写入由 `OCRCardStore` 经 `EncounterAssociation` 显式归属，
    /// 无信号不猜、NULL 不呈现）；本查询只读、按日期倒序、
    /// 不臆造关联，也不因媒体敏感改变口径（只出文字摘要，BR-007/008 不涉）。
    public struct LinkedCardRow: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case prescription
            case claim
            case medication, metricSample, immunization, encounter
            public var cardKind: String {
                switch self { case .claim: return "claim_item"; case .metricSample: return "metric_sample"; default: return rawValue }
            }
        }
        public let id: UUID
        public let kind: Kind
        public let date: Date?
        public let summary: String
        public let documentId: UUID?
        public var identity: String { kind.rawValue + ":" + id.uuidString }
        public init(id: UUID, kind: Kind, date: Date?, summary: String, documentId: UUID?) {
            self.id = id; self.kind = kind; self.date = date
            self.summary = summary; self.documentId = documentId
        }
    }

    /// 关联卡片清单（处方 + 收费票据合并、日期倒序）；日期缺失的行按最早排序。
    public func linkedCards(encounterId: UUID, patientId: UUID, limit: Int = 30) async throws -> [LinkedCardRow] {
        try await writer.read { db in
            var rows: [LinkedCardRow] = []
            let prescriptions = try Row.fetchAll(db, sql: """
                SELECT id, prescribed_at AS date, advice_text AS summary, document_file_id
                FROM prescription WHERE patient_id = ? AND encounter_id = ? AND confirmed = 1
                ORDER BY prescribed_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, encounterId.uuidString, limit])
            for row in prescriptions {
                guard let id = UUID(uuidString: row["id"] as String) else { continue }
                rows.append(LinkedCardRow(id: id, kind: .prescription,
                                          date: (row["date"] as Double?).map { Date(timeIntervalSince1970: $0) },
                                          summary: Self.firstLine(row["summary"] as String?),
                                          documentId: (row["document_file_id"] as String?).flatMap { UUID(uuidString: $0) }))
            }
            let claims = try Row.fetchAll(db, sql: """
                SELECT id, date, COALESCE(summary, item_type) AS summary, document_file_id
                FROM claim_item WHERE patient_id = ? AND encounter_id = ? AND confirmed = 1
                ORDER BY date DESC LIMIT ?
                """, arguments: [patientId.uuidString, encounterId.uuidString, limit])
            for row in claims {
                guard let id = UUID(uuidString: row["id"] as String) else { continue }
                rows.append(LinkedCardRow(id: id, kind: .claim,
                                          date: (row["date"] as Double?).map { Date(timeIntervalSince1970: $0) },
                                          summary: Self.firstLine(row["summary"] as String?),
                                          documentId: (row["document_file_id"] as String?).flatMap { UUID(uuidString: $0) }))
            }
            let projections: [(LinkedCardRow.Kind, String, String)] = [
                (.medication, "created_at", "generic_name"), (.metricSample, "measured_at", "raw_label"),
                (.immunization, "administered_at", "vaccine_name"), (.encounter, "date", "hospital"),
            ]
            var seen = Set(rows.map(\.identity))
            for (kind, dateColumn, summaryColumn) in projections {
                let confirmation = kind == .immunization ? "AND f.confirmed = 1" : ""
                let deletion = kind == .encounter ? "AND f.deleted_at IS NULL" : ""
                // 审查修复①：排除点（metric_sample.excluded=1，V3.45 软删）不得
                // 复活进关联卡清单——用户刻意移除的读数与趋势页一致地消失。
                let exclusion = kind == .metricSample ? "AND f.excluded = 0" : ""
                // 审查修复②：排除本就诊自身的来源就诊卡——就诊卡的 entity_id 即
                // 本就诊 id，旧查询把「就诊自己」列进自己的关联卡（空态文案
                // 「暂无关联的处方或收费卡片」永不成立，且点击构成自引用导航环）。
                let related = try Row.fetchAll(db, sql: """
                    SELECT f.id, f.\(dateColumn) AS date, f.\(summaryColumn) AS summary, c.document_file_id
                    FROM \(kind.cardKind) f JOIN ocr_card_commit c ON c.entity_id = f.id AND c.card_kind = ? AND c.patient_id = f.patient_id
                    JOIN document_file d ON d.id = c.document_file_id AND d.patient_id = c.patient_id
                    WHERE f.patient_id = ? AND (c.encounter_id = ? OR (c.card_kind = 'encounter' AND c.entity_id = ?))
                      AND NOT (c.card_kind = 'encounter' AND c.entity_id = ?)
                      AND d.status IN ('active','favorite') \(confirmation) \(deletion) \(exclusion)
                    ORDER BY f.\(dateColumn) DESC LIMIT ?
                    """, arguments: [kind.cardKind, patientId.uuidString, encounterId.uuidString, encounterId.uuidString, encounterId.uuidString, limit])
                for row in related {
                    guard let id = UUID(uuidString: row["id"] as String) else { continue }
                    let item = LinkedCardRow(id: id, kind: kind, date: (row["date"] as Double?).map(Date.init(timeIntervalSince1970:)),
                        summary: Self.firstLine(row["summary"]), documentId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)))
                    if seen.insert(item.identity).inserted { rows.append(item) }
                }
            }
            return rows.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    private static func firstLine(_ text: String?) -> String {
        guard let line = text?.split(separator: "\n").first else { return "" }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FR4.2 资料挂接到就诊（写入 document_file.encounter_id）。
    /// 挂接/解除与audit_event同事务，源与就诊必须属于同一成员。
    public func linkDocument(documentId: UUID, encounterId: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            guard let patient = try String.fetchOne(db, sql: "SELECT patient_id FROM document_file WHERE id = ?", arguments: [documentId.uuidString]),
                  try String.fetchOne(db, sql: "SELECT patient_id FROM encounter WHERE id = ? AND deleted_at IS NULL", arguments: [encounterId.uuidString]) == patient else {
                throw OCRCardStore.StoreError.invalidAssociation
            }
            try db.execute(sql: "UPDATE document_file SET encounter_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [encounterId.uuidString, now.timeIntervalSince1970, documentId.uuidString])
            guard db.changesCount > 0 else { throw StoreError.documentNotFound(documentId) }
            try AuditLogWriter.insert(action: "update", entityType: "document_file", entityId: documentId.uuidString,
                actorLocal: "owner", meta: #"{"relationship":"encounter","linked":true}"#, db: db)
        }
    }

    /// 解除挂接（资料保留，只清归属标记）
    public func unlinkDocument(documentId: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE document_file SET encounter_id = NULL WHERE id = ?",
                           arguments: [documentId.uuidString])
            guard db.changesCount > 0 else { throw StoreError.documentNotFound(documentId) }
            try AuditLogWriter.insert(action: "update", entityType: "document_file", entityId: documentId.uuidString,
                actorLocal: "owner", meta: #"{"relationship":"encounter","linked":false}"#, db: db)
        }
    }

    public struct LinkedDocument: Sendable, Identifiable {
        public let id: UUID
        public let title: String?
        public let type: String
    }
    public func linkedDocuments(encounterId: UUID, patientId: UUID) async throws -> [LinkedDocument] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT d.id, d.title, d.doc_type FROM document_file d
                WHERE d.patient_id = ? AND d.status IN ('active','favorite') AND
                  (d.encounter_id = ? OR EXISTS (SELECT 1 FROM ocr_card_commit c WHERE c.document_file_id = d.id AND c.patient_id = d.patient_id
                     AND (c.encounter_id = ? OR (c.card_kind = 'encounter' AND c.entity_id = ?)))
                   OR EXISTS (SELECT 1 FROM prescription p WHERE p.document_file_id = d.id AND p.patient_id = d.patient_id AND p.confirmed = 1 AND p.encounter_id = ?)
                   OR EXISTS (SELECT 1 FROM claim_item c WHERE c.document_file_id = d.id AND c.patient_id = d.patient_id AND c.confirmed = 1 AND c.encounter_id = ?))
                ORDER BY d.created_at DESC
                """, arguments: [patientId.uuidString, encounterId.uuidString, encounterId.uuidString, encounterId.uuidString, encounterId.uuidString, encounterId.uuidString])
                .compactMap { row -> LinkedDocument? in
                    guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                    return .init(id: id, title: row["title"], type: row["doc_type"])
                }
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
