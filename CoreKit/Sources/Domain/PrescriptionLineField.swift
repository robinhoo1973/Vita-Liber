import Foundation

/// 处方行「模板键 ↔ 事实列」**唯一**登记表（round5 Q1，2026-09-20）。
///
/// 此前四处手工并行：`EntityCardProjection.prescriptionIntent`（键→列写入）、`PrescriptionLinePresentation.fields`
/// （列→展示）、`OCRCardStore.syncAuditsForEdits`（列→审计键）、`CardFieldEditSheet`（6 列编辑）——加上
/// `CardKindRegistry.prescriptionRowOptional`（目录）是第五份。目录含 `unit` 而投影不认识 → 用户在确认页
/// 「添加字段 → 单位」（`showUnit: false` 下改剂量单位的唯一路径）后被**静默丢弃**（审计却把 unit 当 doseUnit）。
/// 现在四消费方读同一张表；契约测试断言目录键集 == 表键集。
///
/// 语义：`unit` = 剂量单位兜底（`dosage` 字段自带 `.unit` 属性优先——机器抽取形态；独立 `unit` 字段是用户补填形态）。
public enum PrescriptionLineField: String, CaseIterable, Sendable {
    case drugName = "drug_name"
    case genericName = "generic_name"
    case brandName = "brand_name"
    case drugForm = "drug_form"
    case spec
    case dosage
    case unit
    case quantity
    case frequency
    case route
    case days
    case startDate = "start_date"
    case endDate = "end_date"
    case asNeeded = "as_needed"
    case medicationNotes = "medication_notes"
    case note
    case insuranceCode = "insurance_code"
    case itemCode = "item_code"
    case unitPrice = "unit_price"
    case lineAmount = "line_amount"

    public var key: String { rawValue }

    /// 值类型单源（`EntityCardProjection.valueKind`）——控件/校验/编辑同一口径。
    public var valueKind: FieldValueKind { EntityCardProjection.valueKind(kind: "prescription", key: key) }

    /// 展示时并入 `dosage` 行（「原文 + 单位」），自身不单独成行。
    public var isUnitCompanion: Bool { self == .unit }

    /// 把确认值写入行实体（投影用）。`unitText` = 该字段的 `.unit` 属性（仅 dosage/quantity 消费）。
    /// 日期/数值解析失败保持 nil——调用方（`invalidFields`）已在此之前拒收不可解析值，这里不再抛。
    public func apply(_ text: String, unitText: String?, to line: inout PrescriptionLine, calendar: Calendar) {
        switch self {
        case .drugName: line.printedName = text
        case .genericName: line.genericName = text
        case .brandName: line.brandName = text
        case .drugForm: line.drugForm = text
        case .spec: line.spec = text
        case .dosage:
            line.doseText = text
            if let unitText { line.doseUnit = unitText }
        case .unit:
            if line.doseUnit == nil { line.doseUnit = text }
        case .quantity:
            line.quantityText = text
            if let unitText { line.quantityUnit = unitText }
        case .frequency: line.frequencyText = text
        case .route: line.routeText = text
        case .days: line.durationText = text
        case .startDate: line.startDate = EntityCardProjection.parseDate(text, calendar: calendar)
        case .endDate: line.endDate = EntityCardProjection.parseDate(text, calendar: calendar)
        case .asNeeded: line.asNeededText = text
        case .medicationNotes: line.medicationNotes = text
        case .note: line.note = text
        case .insuranceCode: line.insuranceCode = text
        case .itemCode: line.itemCodeText = text
        case .unitPrice: line.unitPrice = Double(text)
        case .lineAmount: line.amount = Double(text)
        }
    }

    /// 行实体 → 规范文本（审计 JSON 同步 / 编辑面初值 / 契约测试）：日期 `yyyy-MM-dd`、数值 `String(describing:)`。
    public func canonicalText(of line: PrescriptionLine, calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        func ymd(_ date: Date?) -> String? { date.map { EntityCardProjection.canonicalDateText($0, calendar: calendar) } }
        switch self {
        case .drugName: return line.printedName.isEmpty ? nil : line.printedName
        case .genericName: return line.genericName
        case .brandName: return line.brandName
        case .drugForm: return line.drugForm
        case .spec: return line.spec
        case .dosage: return line.doseText
        case .unit: return line.doseUnit
        case .quantity: return line.quantityText
        case .frequency: return line.frequencyText
        case .route: return line.routeText
        case .days: return line.durationText
        case .startDate: return ymd(line.startDate)
        case .endDate: return ymd(line.endDate)
        case .asNeeded: return line.asNeededText
        case .medicationNotes: return line.medicationNotes
        case .note: return line.note
        case .insuranceCode: return line.insuranceCode
        case .itemCode: return line.itemCodeText
        case .unitPrice: return line.unitPrice.map { String(describing: $0) }
        case .lineAmount: return line.amount.map { String(describing: $0) }
        }
    }

    /// 非空展示值（规范文本形态；App 按 `valueKind` 再做日期/金额格式化）。
    public func displayValue(of line: PrescriptionLine) -> String? {
        guard let text = canonicalText(of: line), !text.isEmpty else { return nil }
        return text
    }

    /// 编辑面写回：文本 → 行实体（空串 = 清空该列，nil 语义与事实列一致；日期/数值不可解析保持原值）。
    public func write(_ text: String, to line: inout PrescriptionLine, calendar: Calendar = Calendar(identifier: .gregorian)) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear(in: &line)
            return
        }
        switch self {
        case .startDate:
            if let date = EntityCardProjection.parseDate(trimmed, calendar: calendar) { line.startDate = date }
        case .endDate:
            if let date = EntityCardProjection.parseDate(trimmed, calendar: calendar) { line.endDate = date }
        case .unitPrice:
            if let value = Double(trimmed) { line.unitPrice = value }
        case .lineAmount:
            if let value = Double(trimmed) { line.amount = value }
        case .unit:
            line.doseUnit = trimmed
        case .dosage:
            line.doseText = trimmed
        case .quantity:
            line.quantityText = trimmed
        default:
            apply(trimmed, unitText: nil, to: &line, calendar: calendar)
        }
    }

    private func clear(in line: inout PrescriptionLine) {
        switch self {
        case .drugName: break                    // 必填身份列不清空
        case .genericName: line.genericName = nil
        case .brandName: line.brandName = nil
        case .drugForm: line.drugForm = nil
        case .spec: line.spec = nil
        case .dosage: line.doseText = nil
        case .unit: line.doseUnit = nil
        case .quantity: line.quantityText = nil
        case .frequency: line.frequencyText = nil
        case .route: line.routeText = nil
        case .days: line.durationText = nil
        case .startDate: line.startDate = nil
        case .endDate: line.endDate = nil
        case .asNeeded: line.asNeededText = nil
        case .medicationNotes: line.medicationNotes = nil
        case .note: line.note = nil
        case .insuranceCode: line.insuranceCode = nil
        case .itemCode: line.itemCodeText = nil
        case .unitPrice: line.unitPrice = nil
        case .lineAmount: line.amount = nil
        }
    }
}
