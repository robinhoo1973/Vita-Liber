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
        // round5 Q4：键型取 Domain 单源 `EntityCardProjection.valueKind`（此前按卡种手写键表——被 detailColumns
        // 排除又不在手写表里的日期/数值键（如处方 prescribed_at、检验 collected_at）编辑后**静默不落**）。
        // 列名 == 模板键且须存在于事实表（`hasColumn`），否则跳过不猜列。
        for field in shared where fact.hasColumn(field.key) {
            switch EntityCardProjection.valueKind(kind: kind, key: field.key) {
            case .date: try setDate(field.key, from: field)
            case .number: try setDouble(field.key, from: field)
            case .integer: try setInt(field.key, from: field)
            default: break
            }
        }
        // 事实表列型与模板键型不一致的两处遗留（模板视为文本、列为 REAL/INTEGER）：沿用旧口径按列型写。
        func fieldValue(_ key: String) -> FieldDraft? { shared.first { $0.key == key } }
        if kind == "metric_sample" { try setDouble("value", from: fieldValue("value")) }
        if kind == "immunization" { try setInt("dose_number", from: fieldValue("dose_number")) }
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

        // —— 3.5 共同字段跨卡同步（业主 2026-10-19）——
        try propagateSharedCorrections(kind: kind, patientId: patientId, shared: shared,
                                       fact: fact, receipts: receipts, calendar: calendar, db: db)

        // —— 4. 回执审计 JSON 同步（重审一致性）——
        try syncAuditsForEdits(cardId: cardId, kind: kind, shared: shared, lines: lines,
                               receipts: receipts, calendar: calendar, db: db)
    }

    /// 共同字段跨卡同步（业主 2026-10-19：「在第一个信息卡里纠正了，之后的信息卡显示也应该纠正」）。
    ///
    /// 范围 = 同一 `document_file` 的兄弟卡（同一份资料的多张信息卡）。可同步概念由
    /// Domain `SharedFieldPool.sharedConcept` 单源裁定：日期键（各卡按自己的 `dateKey` 落位）
    /// 与 医院/科室/医生。安全闸：仅当兄弟卡当前值仍等于源卡**修正前的旧值**（或原本为空）
    /// 才覆盖——两卡本来就是不同医院/日期时，修正一张不抹掉另一张的事实。
    /// 审计 `ocr_result.raw_blocks` 不在此改写：它记录各卡自己的识别证据，事实列才是读面真值。
    private static func propagateSharedCorrections(kind: String, patientId: UUID, shared: [FieldDraft],
                                                   fact: Row, receipts: [Row],
                                                   calendar: Calendar, db: Database) throws {
        let documentIds = Set(receipts.compactMap { $0["document_file_id"] as String })
        guard let sourceCardId = receipts.compactMap({ $0["card_id"] as String }).first,
              !documentIds.isEmpty else { return }
        let sourceColumns = detailColumns(kind: kind)
        struct Correction {
            let concept: String
            let value: String
            let oldText: String?
            let oldDate: Double?
        }
        var corrections: [Correction] = []
        for field in shared {
            guard let concept = SharedFieldPool.sharedConcept(field.key) else { continue }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let column = sourceColumns.first(where: { $0.key == field.key })?.column ?? field.key
            guard fact.hasColumn(column) else { continue }
            corrections.append(Correction(concept: concept, value: value,
                                          oldText: fact[column] as String?,
                                          oldDate: fact[column] as Double?))
        }
        guard !corrections.isEmpty else { return }

        let marks = Array(repeating: "?", count: documentIds.count).joined(separator: ",")
        let args: [DatabaseValueConvertible] = [patientId.uuidString, sourceCardId]
            + documentIds.sorted().map { $0 as DatabaseValueConvertible }
        let siblings = try Row.fetchAll(db, sql: """
            SELECT DISTINCT card_kind, entity_id, entity_table FROM ocr_card_commit
            WHERE patient_id = ? AND card_id != ? AND document_file_id IN (\(marks))
            """, arguments: StatementArguments(args))
        var headerTables = Set(CardKindRegistry.entries.map(\.headerTable))
        headerTables.insert("lab_report")
        let now = Date().timeIntervalSince1970
        for sibling in siblings {
            guard let siblingKind = sibling["card_kind"] as String?,
                  let siblingEntity = sibling["entity_id"] as String?,
                  let table = sibling["entity_table"] as String?,
                  headerTables.contains(table),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ? AND patient_id = ?",
                                             arguments: [siblingEntity, patientId.uuidString]) else { continue }
            var sets: [String] = []
            var values: [DatabaseValueConvertible] = []
            for correction in corrections {
                guard let key = SharedFieldPool.targetKey(forConcept: correction.concept, kind: siblingKind),
                      let column = detailColumns(kind: siblingKind).first(where: { $0.key == key })?.column
                          ?? (row.hasColumn(key) ? key : nil),
                      row.hasColumn(column) else { continue }
                switch EntityCardProjection.valueKind(kind: siblingKind, key: key) {
                case .date:
                    guard let date = EntityCardProjection.parseDate(correction.value, calendar: calendar) else { continue }
                    let current = row[column] as Double?
                    guard SharedFieldPool.propagatesDate(current: current, old: correction.oldDate,
                                                         new: date.timeIntervalSince1970) else { continue }
                    sets.append("\(column) = ?")
                    values.append(date.timeIntervalSince1970)
                default:
                    let current = (row[column] as String?) ?? ""
                    let old = correction.oldText ?? ""
                    guard SharedFieldPool.propagatesText(current: current, old: old,
                                                         new: correction.value) else { continue }
                    sets.append("\(column) = ?")
                    values.append(correction.value)
                }
            }
            guard !sets.isEmpty else { continue }
            var sql = "UPDATE \(table) SET \(sets.joined(separator: ", "))"
            if row.hasColumn("updated_at") {
                sql += ", updated_at = ?"
                values.append(now)
            }
            sql += " WHERE id = ? AND patient_id = ?"
            values.append(siblingEntity)
            values.append(patientId.uuidString)
            try db.execute(sql: sql, arguments: StatementArguments(values))
        }
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
                    // round5 Q1：审计键 ↔ 行列经 `PrescriptionLineField.canonicalText` 单表（此前本处第四份字面量映射）。
                    audit.fields = audit.fields.map { field in
                        guard let line = linesByRowId[audit.rowId],
                              let column = PrescriptionLineField(rawValue: field.key) else { return field }
                        var updated = field
                        updated.value = column.canonicalText(of: line, calendar: calendar) ?? ""
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
