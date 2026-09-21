import Foundation

/// 字段值类型（round5 Q4，2026-09-20）：UI 控件选择（日期选择器 / 数字键盘 / 枚举 Picker / 文本框）、
/// 落库校验（`EntityCardProjection.invalidFields`）与编辑面预校验（`CardFieldEditSheet`）的**同一张表**。
/// 此前「哪个键是日期」散落四处（投影私有表 / `CardKindRegistry.dateKey` / `ExtractionSpec .date` / 编辑面手抄），
/// 控件与校验一旦不同源，就会出现「识别到却拒收」或「给了选择器却存不进去」。
public enum FieldValueKind: Equatable, Sendable {
    case text
    /// 日期（当日零点；UI 用 `DatePicker(.date)`，写 `yyyy-MM-dd` 规范文本）。
    case date
    /// 十进制数（REAL 列）。
    case number
    /// 整数（INTEGER 列）。
    case integer
    /// 枚举（CHECK 目录 canonical raw；UI 用 Picker，展示文案由 App 映射）。
    case enumerated(options: [String])
}

extension EntityCardProjection {
    /// 日期字段的**规范文本** `yyyy-MM-dd`（公历、给定时区当日）——`parseDate` 可逆解析。
    /// 单源：日期选择器写回、审计 JSON 同步、处方行表 `canonicalText`、编辑面初值此前各持一份格式化闭包。
    public static func canonicalDateText(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// 必填面上的数值键（不在 `numericKeys` 可选表里，但 `applyCardKindChecks` 按数值裁定）。
    static let requiredNumericKeys: [String: Set<String>] = [
        "claim_item": ["amount"],
    ]

    /// 某卡种全部日期键 = 共享必填日期键（`CardKindRegistry.dateKey`）∪ 可选日期键（`optionalDateKeys`）。
    public static func dateKeys(kind: String) -> Set<String> {
        var keys = optionalDateKeys[kind] ?? []
        if let required = CardKindRegistry.entry(for: kind)?.dateKey { keys.insert(required) }
        return keys
    }

    /// 字段值类型单源。枚举目录按键全局（与 App `DocumentsDisplay.enumOptions` 既有语义一致）；
    /// 未知卡种一律 `.text`（不猜）。
    public static func valueKind(kind: String, key: String) -> FieldValueKind {
        if let options = enumeratedOptions(forKey: key) { return .enumerated(options: options) }
        guard CardKindRegistry.entry(for: kind) != nil else { return .text }
        if dateKeys(kind: kind).contains(key) { return .date }
        if integerKeys[kind]?.contains(key) == true { return .integer }
        if numericKeys[kind]?.contains(key) == true || requiredNumericKeys[kind]?.contains(key) == true { return .number }
        return .text
    }

    /// 枚举槽位 canonical 目录（自 App `DocumentsDisplay.enumOptions` 迁入 Domain——目录是数据不是展示；
    /// App 侧委托本处并只负责标签文案）。
    public static func enumeratedOptions(forKey key: String) -> [String]? {
        switch key {
        case "kind": return EncounterKind.allCases.map(\.rawValue)
        case "item_type": return ["invoice", "fee", "receipt"]
        case "unit_kind": return ["tablet", "capsule", "patch", "vial"]
        case "currency": return ["CNY", "HKD", "MOP", "TWD", "USD", "EUR", "JPY", "GBP"]
        case "prescription_type":
            return ["general", "emergency", "pediatric", "narcotic", "psychotropic", "tcm", "other"].filter { prescriptionTypes.contains($0) }
        case "diagnosis_type": return Diagnosis.diagnosisTypes
        case "report_type": return ExamReport.reportTypes
        case "treatment_type": return TreatmentRecord.treatmentTypes
        case "conclusion_type": return ClinicalConclusion.conclusionTypes
        default: return nil
        }
    }
}
