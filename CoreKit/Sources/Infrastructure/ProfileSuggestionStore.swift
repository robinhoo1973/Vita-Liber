#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// 子项目 D · D4-2「资料建议」接受流（recognition-remediation-design §0.3 需求 1 / BR-003）。
///
/// - `collect`：**只读**已确认卡的回执（`ocr_card_commit` → `encounter.past_history/allergy_history`、
///   `hospitalization.admit/discharge_diagnosis_text`、`diagnosis.name`、`lab_result.item_name/result_text`）→
///   `ProfileSuggestionExtractor`；零写入；已处理 / 已忽略（`notification_state` `kind='profile_suggestion'`）与既有资料同值不复现。
/// - `accept`：用户逐项显式接受后**单事务**写 `patient_profile.blood_type` / `health_problem`（诊断来源回填
///   `diagnosis.health_problem_id`，FR11.4）/ `allergy_event`（严重度只能由用户给出）+ 审计 `profile_suggestion_accepted`
///   （meta 只记留痕，不记医疗内容）。已有值**不覆盖** → `.skippedExisting`。
/// - 成员隔离（BR-001）：来源实体必须属于该成员，否则 `invalidCard`（不区分「不存在」与「他人的」）。
/// - `dismiss`：持久登记「已忽略」（键 = `suggestion-<sha256(patient|dedupeKey)>`），不写事实、不审计。
public actor ProfileSuggestionStore {
    public enum AcceptOutcome: Sendable, Equatable { case written, skippedExisting }

    /// 审计白名单动作（`AuditLogWriter.allowedActions`）。
    public static let auditAction = "profile_suggestion_accepted"
    static let stateKind = "profile_suggestion"
    /// 建议来源实体表白名单——表名只从此集合进入 SQL。
    static let sourceTables: Set<String> = ["encounter", "hospitalization", "diagnosis", "lab_result"]
    /// 规范严重度 = SevereReactionRules.canonicalSeverities（Domain 单一事实源，
    /// 与 DDL CHECK 同源——此前此处为第三份拷贝，结构轮 2026-09-15 收敛为别名）。
    static let severities: Set<String> = SevereReactionRules.canonicalSeverities

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    // MARK: - collect（只读）

    /// 一张已确认卡（全部回执）→ 建议。无回执（未确认 / 他人的卡）→ 空。
    public func collect(cardId: UUID, patientId: UUID) async throws -> [ProfileSuggestion] {
        try await writer.read { db in
            let receipts = try Row.fetchAll(db, sql: """
                SELECT * FROM ocr_card_commit WHERE card_id = ? AND patient_id = ? ORDER BY created_at, row_id
                """, arguments: [cardId.uuidString, patientId.uuidString])
            return try Self.collect(receipts: receipts, patientId: patientId, db: db)
        }
    }

    /// 计划签名：卡类 + 回执所指实体 id 集合（`idx_ocr_card_commit_entity`）。
    public func collect(cardKind: String, entityIds: [UUID], patientId: UUID) async throws -> [ProfileSuggestion] {
        guard !entityIds.isEmpty else { return [] }
        return try await writer.read { db in
            let placeholders = entityIds.map { _ in "?" }.joined(separator: ",")
            let receipts = try Row.fetchAll(db, sql: """
                SELECT * FROM ocr_card_commit WHERE card_kind = ? AND patient_id = ? AND entity_id IN (\(placeholders))
                ORDER BY created_at, row_id
                """, arguments: StatementArguments([cardKind, patientId.uuidString] + entityIds.map(\.uuidString)))
            return try Self.collect(receipts: receipts, patientId: patientId, db: db)
        }
    }

    private struct Source {
        let cardKind: String
        let documentId: UUID?
        let pageIndex: Int
        let rowId: UUID?
    }

    static func collect(receipts: [Row], patientId: UUID, db: Database) throws -> [ProfileSuggestion] {
        guard !receipts.isEmpty else { return [] }
        let pid = patientId.uuidString
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile WHERE id = ? AND deleted_at IS NULL", arguments: [pid]) == 1 else {
            throw OCRCardStore.StoreError.invalidCard
        }
        var sources: [String: Source] = [:]
        var ordered: [(table: String, id: UUID)] = []
        for receipt in receipts {
            let table: String = receipt["entity_table"]
            guard sourceTables.contains(table), (receipt["patient_id"] as String) == pid,
                  let entity = UUID(uuidString: receipt["entity_id"]) else { continue }
            let key = "\(table)|\(entity.uuidString)"
            guard sources[key] == nil else { continue }
            sources[key] = Source(cardKind: receipt["card_kind"], documentId: UUID(uuidString: receipt["document_file_id"]),
                                  pageIndex: receipt["page_index"], rowId: UUID(uuidString: receipt["row_id"]))
            ordered.append((table, entity))
        }
        var narratives: [ProfileSuggestionExtractor.NarrativeField] = []
        var diagnoses: [Diagnosis] = []
        var labs: [LabResult] = []
        for (table, entity) in ordered {
            switch table {
            case "encounter":
                if let row = try Row.fetchOne(db, sql: """
                    SELECT date, past_history, allergy_history FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL
                    """, arguments: [entity.uuidString, pid]) {
                    let date = Date(timeIntervalSince1970: row["date"])
                    for key in ["past_history", "allergy_history"] {
                        if let text = row[key] as String? {
                            narratives.append(.init(entityTable: table, entityId: entity, key: key, text: text, occurredAt: date))
                        }
                    }
                }
            case "hospitalization":
                if let row = try Row.fetchOne(db, sql: """
                    SELECT admit_at, discharge_at, admit_diagnosis_text, discharge_diagnosis_text FROM hospitalization
                    WHERE id = ? AND patient_id = ? AND confirmed = 1
                    """, arguments: [entity.uuidString, pid]) {
                    let date = ((row["admit_at"] as Double?) ?? (row["discharge_at"] as Double?)).map(Date.init(timeIntervalSince1970:))
                    for key in ["admit_diagnosis_text", "discharge_diagnosis_text"] {
                        if let text = row[key] as String? {
                            narratives.append(.init(entityTable: table, entityId: entity, key: key, text: text, occurredAt: date))
                        }
                    }
                }
            case "diagnosis":
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM diagnosis WHERE id = ? AND patient_id = ? AND confirmed = 1",
                                              arguments: [entity.uuidString, pid]) {
                    diagnoses.append(try OCRCardStore.diagnosis(from: row))
                }
            case "lab_result":
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM lab_result WHERE id = ? AND patient_id = ?",
                                              arguments: [entity.uuidString, pid]) {
                    labs.append(try OCRCardStore.labResult(from: row))
                }
            default:
                continue
            }
        }
        diagnoses.sort { $0.ordinal < $1.ordinal }
        labs.sort { $0.ordinal < $1.ordinal }
        let existing = try snapshot(patientId: pid, db: db)
        let out = ProfileSuggestionExtractor.suggestions(narratives: narratives, diagnoses: diagnoses, labResults: labs, existing: existing) { table, id, key in
            let source = sources["\(table)|\(id.uuidString)"]
            return ProfileSuggestion.Provenance(cardKind: source?.cardKind ?? table, entityTable: table, entityId: id, fieldKey: key,
                                                documentId: source?.documentId, pageIndex: source?.pageIndex, rowId: source?.rowId)
        }
        guard !out.isEmpty else { return [] }
        let keys = out.map { handledKey($0, patientId: patientId) }
        let handledRows = try String.fetchAll(db, sql: """
            SELECT item_key FROM notification_state WHERE kind = ? AND archived_at IS NOT NULL
            AND item_key IN (\(keys.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments([stateKind] + keys))
        let handled = Set(handledRows)
        var visible: [ProfileSuggestion] = []
        for (suggestion, key) in zip(out, keys) where !handled.contains(key) { visible.append(suggestion) }
        return visible
    }

    static func snapshot(patientId pid: String, db: Database) throws -> ProfileSuggestionExtractor.ProfileSnapshot {
        let bloodType = try String.fetchOne(db, sql: "SELECT blood_type FROM patient_profile WHERE id = ? AND deleted_at IS NULL", arguments: [pid])
        let problems = try String.fetchAll(db, sql: "SELECT name FROM health_problem WHERE patient_id = ?", arguments: [pid])
        let allergies = try String.fetchAll(db, sql: "SELECT substance FROM allergy_event WHERE patient_id = ?", arguments: [pid])
        return ProfileSuggestionExtractor.ProfileSnapshot(bloodType: bloodType, problemNames: problems, allergySubstances: allergies)
    }

    // MARK: - accept（单事务）

    /// 逐项接受。过敏须 `allergySeverity`（展示词 轻/中/重 或 mild/moderate/severe），缺失或非枚举 → `invalidCard`（不占位、不推断）。
    public func accept(_ suggestion: ProfileSuggestion, patientId: UUID, allergySeverity: String? = nil,
                       now: Date = Date()) async throws -> AcceptOutcome {
        var severity: String?
        if suggestion.kind == .allergy {
            guard let given = allergySeverity.map(SevereReactionRules.canonicalSeverity), Self.severities.contains(given) else {
                throw OCRCardStore.StoreError.invalidCard
            }
            severity = given
        }
        let key = Self.handledKey(suggestion, patientId: patientId)
        let meta = try Self.auditMeta(suggestion)
        let value = suggestion.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw OCRCardStore.StoreError.invalidCard }
        return try await writer.write { db in
            try Self.validateSource(suggestion.provenance, patientId: patientId, db: db)
            let pid = patientId.uuidString
            let stamp = now.timeIntervalSince1970
            var written: (entityType: String, entityId: String)?
            switch suggestion.kind {
            case .bloodType:
                let current = try String.fetchOne(db, sql: "SELECT blood_type FROM patient_profile WHERE id = ? AND deleted_at IS NULL", arguments: [pid])
                if current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    written = nil
                } else {
                    try db.execute(sql: "UPDATE patient_profile SET blood_type = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [value, stamp, pid])
                    guard db.changesCount == 1 else { throw OCRCardStore.StoreError.invalidCard }
                    written = ("patient_profile", pid)
                }
            case .chronicCondition, .pastHistory:
                let folded = ProfileSuggestionExtractor.fold(value, kind: suggestion.kind)
                let names = try String.fetchAll(db, sql: "SELECT name FROM health_problem WHERE patient_id = ?", arguments: [pid])
                if names.contains(where: { ProfileSuggestionExtractor.fold($0, kind: suggestion.kind) == folded }) {
                    written = nil
                } else {
                    let id = UUID()
                    try db.execute(sql: """
                        INSERT INTO health_problem (id, patient_id, name, kind, archived, created_at, updated_at)
                        VALUES (?, ?, ?, NULL, 0, ?, ?)
                        """, arguments: [id.uuidString, pid, value, stamp, stamp])
                    if suggestion.provenance.entityTable == "diagnosis" {
                        // FR11.4：用户显式「采用为健康问题」→ 回填 diagnosis.health_problem_id（只补空，不改写既有采用）。
                        try db.execute(sql: """
                            UPDATE diagnosis SET health_problem_id = ?, updated_at = ?
                            WHERE id = ? AND patient_id = ? AND health_problem_id IS NULL
                            """, arguments: [id.uuidString, stamp, suggestion.provenance.entityId.uuidString, pid])
                    }
                    written = ("health_problem", id.uuidString)
                }
            case .allergy:
                let folded = ProfileSuggestionExtractor.fold(value, kind: .allergy)
                let substances = try String.fetchAll(db, sql: "SELECT substance FROM allergy_event WHERE patient_id = ?", arguments: [pid])
                if substances.contains(where: { ProfileSuggestionExtractor.fold($0, kind: .allergy) == folded }) {
                    written = nil
                } else {
                    let id = UUID()
                    let encounterId = suggestion.provenance.entityTable == "encounter" ? suggestion.provenance.entityId.uuidString : nil
                    try db.execute(sql: """
                        INSERT INTO allergy_event
                          (id, patient_id, substance, reaction_tags, severity, occurred_at, encounter_id, consulted_doctor, note, created_at, updated_at)
                        VALUES (?, ?, ?, '[]', ?, ?, ?, 0, 'source:profile_suggestion', ?, ?)
                        """, arguments: [id.uuidString, pid, value, severity, (suggestion.occurredAt ?? now).timeIntervalSince1970,
                                         encounterId, stamp, stamp])
                    written = ("allergy_event", id.uuidString)
                }
            }
            if let written {
                try AuditLogWriter.insert(action: Self.auditAction, entityType: written.entityType, entityId: written.entityId,
                                          actorLocal: "owner", meta: meta, db: db)
            }
            try Self.markHandled(key, now: now, db: db)
            return written == nil ? .skippedExisting : .written
        }
    }

    // MARK: - dismiss（持久忽略）

    public func dismiss(_ suggestion: ProfileSuggestion, patientId: UUID, now: Date = Date()) async throws {
        try await dismiss([suggestion], patientId: patientId, now: now)
    }

    public func dismiss(_ suggestions: [ProfileSuggestion], patientId: UUID, now: Date = Date()) async throws {
        guard !suggestions.isEmpty else { return }
        let keys = suggestions.map { Self.handledKey($0, patientId: patientId) }
        try await writer.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [patientId.uuidString]) == 1 else { throw OCRCardStore.StoreError.invalidCard }
            for key in keys { try Self.markHandled(key, now: now, db: db) }
        }
    }

    // MARK: - 助手

    /// 来源实体必须属于该成员（表名先过白名单再进 SQL）。
    static func validateSource(_ provenance: ProfileSuggestion.Provenance, patientId: UUID, db: Database) throws {
        guard sourceTables.contains(provenance.entityTable) else { throw OCRCardStore.StoreError.invalidCard }
        let pid = patientId.uuidString
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile WHERE id = ? AND deleted_at IS NULL", arguments: [pid]) == 1,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(provenance.entityTable) WHERE id = ? AND patient_id = ?",
                               arguments: [provenance.entityId.uuidString, pid]) == 1 else {
            throw OCRCardStore.StoreError.invalidCard
        }
    }

    /// 已处理 / 已忽略登记键：按成员分域的稳定哈希（不含建议原文）。
    static func handledKey(_ suggestion: ProfileSuggestion, patientId: UUID) -> String {
        "suggestion-" + CryptoKitContentHasher().sha256Hex(Data("\(patientId.uuidString.lowercased())|\(suggestion.dedupeKey)".utf8))
    }

    static func markHandled(_ key: String, now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO notification_state (item_key, kind, read_at, archived_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(item_key) DO UPDATE SET archived_at = excluded.archived_at
            """, arguments: [key, stateKind, now.timeIntervalSince1970, now.timeIntervalSince1970])
    }

    private struct AuditMeta: Encodable {
        let kind: String
        let provenance: ProfileSuggestion.Provenance
    }

    /// 审计 meta 只含类别与留痕（§6 日志最小化：不记建议原文）。
    static func auditMeta(_ suggestion: ProfileSuggestion) throws -> String {
        String(decoding: try JSONEncoder().encode(AuditMeta(kind: suggestion.kind.rawValue, provenance: suggestion.provenance)), as: UTF8.self)
    }
}
#endif
