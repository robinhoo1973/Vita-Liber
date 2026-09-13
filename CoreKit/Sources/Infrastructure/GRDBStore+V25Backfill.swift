// 平台守卫与 GRDBStore.swift 严格镜像（GRDB 仅 iOS/macOS 链接，ERR#8）。
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// v25 `recognition-fact-lines` 代码回填（discussions/2026-09-13-hospital-card-schema-round1 §D.0/§D.1；
/// 实施计划 D1-1 Step 5）。由 `GRDBStore.migrateIncremental` 的 `case 25` 在表重建 + FK 校验之后、
/// 版本推进之前于**同一事务**内调用；亦可独立重跑（幂等）。
extension GRDBStore {
    /// 只从 `ocr_result(engine_version = 'ocr-card-v22')` 的回执 JSON（`AuditRecord.shared/fields`，
    /// 全部为用户已确认字段）确定性生成：
    /// - 处方回执 → `prescription_line`（`drug_name→printed_name`、`spec`、`dosage→dose_text/dose_unit`、
    ///   `quantity→quantity_text/quantity_unit`、`frequency→frequency_text`、`route→route_text`、
    ///   `days→duration_text`、`note`；`raw_text` = 行字段 rawText 拼接；`confirmed = 1`）；
    /// - 就诊回执 `shared.present_illness / visit_summary` → `encounter` 叙事列（COALESCE 只补空）；
    /// - 票据回执 `shared.reimbursed_amount / out_of_pocket` → `claim_item`（COALESCE 只补空，不可解析保持 NULL）。
    ///
    /// 纪律：**绝不**从 `prescription.advice_text` 自由文本猜回（BR-003）；剂量/数量只存原文 + 单位
    /// （BR-006/007）；`ocr_result` 只增不改；解不开的回执跳过、不中止迁移。
    /// 幂等键：`prescription_line.source_row_id`（= 回执 row_id）/ `id`（= row_id，两台设备各自回填得到同一 id，
    /// 备份恢复不会因 UNIQUE(prescription_id, ordinal) 撞车）；叙事/金额列 COALESCE 只补空。
    /// 成员隔离：行只在表头 `prescription(id, patient_id)` 与回执 patient 一致时生成（父表缺失/跨成员 → 跳过）。
    static func backfillRecognitionFactLines(_ db: Database) throws {
        let decoder = JSONDecoder()
        var audits: [String: OCRCardStore.AuditRecord] = [:]           // "cardId/rowId" → 回执
        let jsons = try String.fetchAll(db, sql: "SELECT raw_blocks FROM ocr_result WHERE engine_version = ?",
                                        arguments: [OCRCardStore.auditEngine])
        for json in jsons {
            guard let audit = try? decoder.decode(OCRCardStore.AuditRecord.self, from: Data(json.utf8)) else { continue }   // try?-ok: 坏回执跳过不生成，不中止迁移（§D.1）
            audits["\(audit.cardId.uuidString)/\(audit.rowId.uuidString)"] = audit
        }
        // 只看「指向表头实体」的回执（entity_table = card_kind）：v25 搬运后全部如此；
        // D1-3 起新处方/费用行回执 entity_table = prescription_line/claim_line，重跑时不得当表头处理。
        let receipts = try Row.fetchAll(db, sql: """
            SELECT card_id, row_id, patient_id, page_index, card_kind, entity_id, created_at FROM ocr_card_commit
            WHERE card_kind IN ('prescription', 'encounter', 'claim_item') AND entity_table = card_kind
            ORDER BY entity_id, created_at, page_index, row_id
            """)
        var ordinalByHeader: [String: Int] = [:]
        for receipt in receipts {
            let cardId: String = receipt["card_id"], rowId: String = receipt["row_id"]
            guard let audit = audits["\(cardId)/\(rowId)"] else { continue }
            let shared = EntityCardProjection.confirmedValues(audit.shared)
            let fields = EntityCardProjection.confirmedValues(audit.fields)
            let entity: String = receipt["entity_id"], patient: String = receipt["patient_id"]
            let recordedAt: Double = receipt["created_at"], page: Int = receipt["page_index"]
            switch receipt["card_kind"] as String {
            case "prescription":
                guard let name = fields["drug_name"] else { continue }
                if ordinalByHeader[entity] == nil {   // Dictionary 的 default: 是非 throwing autoclosure，不能放 try
                    ordinalByHeader[entity] = try Int.fetchOne(db, sql: """
                        SELECT COALESCE(MAX(ordinal) + 1, 0) FROM prescription_line WHERE prescription_id = ?
                        """, arguments: [entity]) ?? 0
                }
                let ordinal = ordinalByHeader[entity] ?? 0
                let joinedRaw = audit.fields.compactMap(\.rawText).joined(separator: "\n")
                let rawText: String? = joinedRaw.isEmpty ? nil : joinedRaw
                try db.execute(sql: """
                    INSERT INTO prescription_line (id, prescription_id, patient_id, ordinal, printed_name, spec, dose_text, dose_unit,
                      quantity_text, quantity_unit, frequency_text, route_text, duration_text, note, raw_text,
                      source_page, source_row_id, confirmed, created_at, updated_at)
                    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?
                    WHERE NOT EXISTS (SELECT 1 FROM prescription_line WHERE source_row_id = ? OR id = ?)
                      AND EXISTS (SELECT 1 FROM prescription WHERE id = ? AND patient_id = ?)
                    """, arguments: [rowId, entity, patient, ordinal, name, fields["spec"],
                                     fields["dosage"], Self.confirmedUnit(audit, key: "dosage"),
                                     fields["quantity"], Self.confirmedUnit(audit, key: "quantity"),
                                     fields["frequency"], fields["route"], fields["days"], fields["note"], rawText,
                                     page, rowId, recordedAt, recordedAt,
                                     rowId, rowId, entity, patient])
                if db.changesCount == 1 { ordinalByHeader[entity] = ordinal + 1 }
            case "encounter":
                // §C.1：illness_summary 为 present_illness 的历史别名（同一确认字段，归一不推断）
                let presentIllness = shared["present_illness"] ?? shared["illness_summary"]
                try db.execute(sql: """
                    UPDATE encounter SET present_illness = COALESCE(present_illness, ?), visit_summary = COALESCE(visit_summary, ?)
                    WHERE id = ? AND patient_id = ?
                    """, arguments: [presentIllness, shared["visit_summary"], entity, patient])
            case "claim_item":
                try db.execute(sql: """
                    UPDATE claim_item SET reimbursed_amount = COALESCE(reimbursed_amount, ?), out_of_pocket = COALESCE(out_of_pocket, ?)
                    WHERE id = ? AND patient_id = ?
                    """, arguments: [Self.finiteAmount(shared["reimbursed_amount"]), Self.finiteAmount(shared["out_of_pocket"]), entity, patient])
            default:
                continue
            }
        }
    }

    /// 回执中该键（已确认）的单位原文；无则 NULL——不补默认单位（BR-006）。
    private static func confirmedUnit(_ audit: OCRCardStore.AuditRecord, key: String) -> String? {
        audit.fields.first { $0.key == key && $0.isConfirmed }?.unit
    }

    /// 金额（费用，非医学数值）：只接受可严格解析的有限数，否则 NULL（不猜）。
    private static func finiteAmount(_ text: String?) -> Double? {
        guard let value = text.flatMap(Double.init), value.isFinite else { return nil }
        return value
    }
}
#endif
