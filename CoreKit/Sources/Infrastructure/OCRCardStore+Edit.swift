#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 已确认卡字段编辑（业主 2026-09-20 第 4 项：信息卡保存后从健康档案进入相关字段编辑）。
///
/// 语义纪律：
/// - **编辑即确认**：从健康档案发起的字段更正是用户显式行为，写入事实列仍保持
///   confirmed = 1——这是最强的确认形态（用户看着原件改值），不经过 OCR 确认流的
///   D→C 闸门（BR-003 保护的是「未确认机器数据进事实」，不约束用户显式更正）。
/// - **只改值、不动身**：回执行（ocr_card_commit）的实体 id / 来源页 / 卡 id 不变，
///   原件（BR-002）不受影响；被改值的**回执审计 JSON 同步更正**——重审路径
///   （reviewState/mergeDraft 的 committedDataChanged 比对）以审计为真值，审计
///   不随更正走会让「改过的卡」在下次再确认时恒报冲突。
/// - **清空 = 不改**（期二登记：清空语义需回执手术，本版编辑只接受非空替换）。
/// - 值解析失败（日期/数值）抛 `invalidCard`——调用方（编辑表单）先按同口径预校验。
extension OCRCardStore {

    /// 字段值编辑（详情卡类；`lab_report` 聚合读面与 `encounter`/`health_exam`
    /// 有专用编辑面，不在本入口——`invalidCard`）。
    public func updateCardFields(kind: String, entityId: UUID, patientId: UUID,
                                 shared: [FieldDraft], lines: [PrescriptionLine] = []) async throws {
        guard Self.detailKinds.contains(kind), kind != "lab_report",
              kind != "encounter", kind != "health_exam" else { throw StoreError.invalidCard }
        try await writer.write { db in
            try Self.applyCardFieldEdits(kind: kind, entityId: entityId, patientId: patientId,
                                         shared: shared, lines: lines, db: db)
        }
    }

    /// 事务内的编辑主体（static，便于同一事务内其它写面复用）。
    static func applyCardFieldEdits(kind: String, entityId: UUID, patientId: UUID,
                                    shared: [FieldDraft], lines: [PrescriptionLine], db: Database) throws {
        let table = factTable(for: kind)
        guard let fact = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?",
                                          arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
        // 确认态守卫与 detail() 同口径（metric_sample 无 confirmed 列，不进此表）
        if ["prescription", "claim_item", "immunization", "hospitalization", "diagnosis", "exam_report",
            "surgery", "treatment_record"].contains(kind),
           (fact["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
        let receipts = try receipts(kind: kind, headerId: entityId, patientId: patientId, db: db)
        guard !receipts.isEmpty, let cardId = UUID(uuidString: receipts[0]["card_id"] as String) else {
            throw StoreError.invalidCard
        }
        for receipt in receipts { try validateReceipt(receipt, db: db) }
        let now = Date()

        // —— 1. 文本列更正（detailColumns 单一出口：模板键 → 列名，与读面同源）——
        var sets: [String] = []
        var args: [DatabaseValueConvertible] = []
        let calendar = Calendar(identifier: .gregorian)
        func nonNilText(_ field: FieldDraft) -> String? {
            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : field.value
        }
        for (key, column) in detailColumns(kind: kind) where fact.hasColumn(column) {
            guard let field = shared.first(where: { $0.key == key }), let value = nonNilText(field) else { continue }
            let current = (fact[column] as String?) ?? ""
            guard value != current else { continue }
            sets.append("\(column) = ?")
            args.append(value)
        }
        // —— 2. 日期/数值列更正（与 detail() 的类型追加同口径）——
        func setDate(_ column: String, from field: FieldDraft?) throws {
            guard let field, let text = nonNilText(field) else { return }
            guard let date = EntityCardProjection.parseDate(text, calendar: calendar) else { throw StoreError.invalidCard }
            sets.append("\(column) = ?")
            args.append(date.timeIntervalSince1970)
        }
        func setDouble(_ column: String, from field: FieldDraft?) throws {
            guard let field, let text = nonNilText(field) else { return }
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw StoreError.invalidCard }
            sets.append("\(column) = ?")
            args.append(value)
        }
        func setInt(_ column: String, from field: FieldDraft?) throws {
            guard let field, let text = nonNilText(field) else { return }
            guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw StoreError.invalidCard }
            sets.append("\(column) = ?")
            args.append(value)
        }
        func fieldValue(_ key: String) -> FieldDraft? { shared.first { $0.key == key } }
        switch kind {
        case "claim_item":
            for key in ["amount", "reimbursed_amount", "out_of_pocket", "personal_account_amount"] {
                try setDouble(key, from: fieldValue(key))
            }
        case "prescription":
            try setDouble("total_amount", from: fieldValue("total_amount"))
        case "immunization":
            try setInt("dose_number", from: fieldValue("dose_number"))
        case "hospitalization":
            for key in ["admit_at", "discharge_at", "summary_date"] { try setDate(key, from: fieldValue(key)) }
            for key in ["inpatient_times", "actual_days"] { try setInt(key, from: fieldValue(key)) }
            try setDouble("total_cost", from: fieldValue("total_cost"))
        case "diagnosis":
            try setDate("diagnosed_at", from: fieldValue("diagnosed_at"))
        case "exam_report":
            for key in ["exam_at", "reported_at"] { try setDate(key, from: fieldValue(key)) }
        case "surgery":
            for key in ["surgery_at", "ended_at"] { try setDate(key, from: fieldValue(key)) }
        case "treatment_record":
            try setDate("treated_at", from: fieldValue("treated_at"))
        case "metric_sample":
            for key in ["value", "ref_low", "ref_high"] { try setDouble(key, from: fieldValue(key)) }
        default:
            break
        }
        if !sets.isEmpty {
            args.append(now.timeIntervalSince1970)
            args.append(entityId.uuidString)
            args.append(patientId.uuidString)
            try db.execute(sql: "UPDATE \(table) SET \(sets.joined(separator: ", ")), updated_at = ? WHERE id = ? AND patient_id = ?",
                           arguments: StatementArguments(args))
            guard db.changesCount == 1 else { throw StoreError.invalidCard }
        }

        // —— 3. 处方行更正（事实列；provenance 列 raw_text/source_page/ordinal/confirmed 不动）——
        if kind == "prescription", !lines.isEmpty {
            for line in lines {
                try db.execute(sql: """
                    UPDATE prescription_line SET printed_name = ?, generic_name = ?, brand_name = ?, drug_form = ?, spec = ?,
                      dose_text = ?, dose_unit = ?, quantity_text = ?, quantity_unit = ?, frequency_text = ?, route_text = ?,
                      duration_text = ?, start_date = ?, end_date = ?, as_needed_text = ?, medication_notes = ?, note = ?,
                      insurance_code = ?, item_code_text = ?, unit_price = ?, amount = ?, updated_at = ?
                    WHERE id = ? AND prescription_id = ? AND patient_id = ?
                    """, arguments: [line.printedName, line.genericName, line.brandName, line.drugForm, line.spec,
                        line.doseText, line.doseUnit, line.quantityText, line.quantityUnit, line.frequencyText, line.routeText,
                        line.durationText, line.startDate?.timeIntervalSince1970, line.endDate?.timeIntervalSince1970,
                        line.asNeededText, line.medicationNotes, line.note, line.insuranceCode, line.itemCodeText,
                        line.unitPrice, line.amount, now.timeIntervalSince1970,
                        line.id.uuidString, entityId.uuidString, patientId.uuidString])
                guard db.changesCount == 1 else { throw StoreError.invalidCard }
            }
        }

        // —— 4. 回执审计 JSON 同步（重审一致性）——
        try syncAuditsForEdits(cardId: cardId, kind: kind, shared: shared, lines: lines,
                               receipts: receipts, calendar: calendar, db: db)
    }

    /// 更正后的共享面/行字段写回本卡的 ocr_result 审计行（decode → 替换 → re-encode）。
    /// 审计行按 (document_file_id, page_index) 定位——同一卡多来源页时逐页同步。
    private static func syncAuditsForEdits(cardId: UUID, kind: String, shared: [FieldDraft],
                                           lines: [PrescriptionLine], receipts: [Row],
                                           calendar: Calendar, db: Database) throws {
        let correctedShared = shared.filter { field in
            !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let sharedByKey = Dictionary(uniqueKeysWithValues: correctedShared.map { ($0.key, $0.value) })
        // 处方行：审计行 rowId ↔ line.sourceRowId；模板键 → 行事实列（读面同源键表）
        let linesByRowId = Dictionary(uniqueKeysWithValues: lines.compactMap { line in
            line.sourceRowId.map { ($0, line) }
        })
        var pages = Set<String>()
        for receipt in receipts {
            pages.insert("\(receipt["document_file_id"] as String)#\(receipt["page_index"] as Int)")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let dateText: (Date?) -> String? = { date in
            guard let date else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        }
        for page in pages {
            let pieces = page.split(separator: "#")
            guard pieces.count == 2, let pageIndex = Int(pieces[1]) else { continue }
            let document = String(pieces[0])
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, raw_blocks FROM ocr_result WHERE document_file_id = ? AND page_index = ?
                """, arguments: [document, pageIndex])
            for row in rows {
                guard let raw = row["raw_blocks"] as String?,
                      var audit = try? JSONDecoder().decode(AuditRecord.self, from: Data(raw.utf8)),   // try?-ok: 非本卡/旧格式审计跳过，不阻断编辑主流程
                      audit.cardId == cardId else { continue }
                audit.shared = audit.shared.map { field in
                    guard let value = sharedByKey[field.key] else { return field }
                    var updated = field
                    updated.value = value
                    return updated
                }
                if kind == "prescription" {
                    audit.fields = audit.fields.map { field in
                        guard let line = linesByRowId[audit.rowId] else { return field }
                        var updated = field
                        switch field.key {
                        case "drug_name": updated.value = line.printedName
                        case "spec": updated.value = line.spec ?? ""
                        case "dosage": updated.value = line.doseText ?? ""
                        case "unit": updated.value = line.doseUnit ?? ""
                        case "quantity": updated.value = line.quantityText ?? ""
                        case "frequency": updated.value = line.frequencyText ?? ""
                        case "route": updated.value = line.routeText ?? ""
                        case "days": updated.value = line.durationText ?? ""
                        case "note": updated.value = line.note ?? ""
                        case "drug_form": updated.value = line.drugForm ?? ""
                        case "generic_name": updated.value = line.genericName ?? ""
                        case "brand_name": updated.value = line.brandName ?? ""
                        case "start_date": updated.value = dateText(line.startDate) ?? ""
                        case "end_date": updated.value = dateText(line.endDate) ?? ""
                        case "as_needed": updated.value = line.asNeededText ?? ""
                        case "medication_notes": updated.value = line.medicationNotes ?? ""
                        case "insurance_code": updated.value = line.insuranceCode ?? ""
                        case "item_code": updated.value = line.itemCodeText ?? ""
                        case "unit_price": updated.value = line.unitPrice.map(String.init(describing:)) ?? ""
                        case "line_amount": updated.value = line.amount.map(String.init(describing:)) ?? ""
                        default: break
                        }
                        return updated
                    }
                }
                let json = String(decoding: try encoder.encode(audit), as: UTF8.self)
                try db.execute(sql: "UPDATE ocr_result SET raw_blocks = ? WHERE id = ?",
                               arguments: [json, row["id"] as String])
            }
        }
    }
}
#endif
