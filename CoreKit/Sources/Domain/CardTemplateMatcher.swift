import Foundation

/// FR6.9（V3.61 业主裁决）卡模板匹配——识别后单页字段对每个卡片类型模板做匹配：
/// **全字段 ≥50% 且必填 ≥80%** 可从文本获取即匹配该卡；同类多实例每类一卡、卡内多行；
/// 同一卡类跨页各成一卡（`pageIndex` 不同即不同卡）。纯 Domain、零依赖。
///
/// 与 `CompletenessEvaluator` 的分工：本类型决定「出不出卡」（匹配门槛），四级完整度
/// 只作卡内徽章（`MatchedCard.level`）。规则表（必填/推荐）仍以 `CompletenessEvaluator.rules(for:)`
/// 为单一事实源（data-flow §17.2）。
public enum CardMatchThresholds {
    /// 模板全字段（必填+推荐）中可从文本获取的比例下限
    public static let allFields = 0.5
    /// 模板必填字段中可从文本获取的比例下限
    public static let requiredFields = 0.8
}

/// 卡模板：一个 data-flow §17.2 card_kind + 理解层字段键到模板字段键的映射。
public struct CardTemplate: Sendable, Equatable {
    public let kind: String
    /// 行触发键（理解层键）：每个该键实例开一行；nil = 单行卡
    public let rowKey: String?
    /// 理解层字段键 → 模板字段键（恒等映射也需登记，未登记键不参与）
    public let mapping: [String: String]
    /// 行级模板键（其余为卡级共享）
    public let rowLevelKeys: Set<String>
    /// 可派生的模板键（计入覆盖；值由匹配器按规则派生）
    public let derived: Set<String>
    /// 仅这些文档类型判定下参与匹配（nil = 不限）
    public let requiresDocumentType: Set<String>?

    public init(kind: String, rowKey: String?, mapping: [String: String],
                rowLevelKeys: Set<String> = [], derived: Set<String> = [],
                requiresDocumentType: Set<String>? = nil) {
        self.kind = kind; self.rowKey = rowKey; self.mapping = mapping
        self.rowLevelKeys = rowLevelKeys; self.derived = derived
        self.requiresDocumentType = requiresDocumentType
    }
}

public struct MatchedCardRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var fields: [FieldDraft]
    /// 该行缺失的行级必填键（保存时跳过本行、不阻断其他行）
    public var missingRequired: [String]
    public init(id: UUID = UUID(), fields: [FieldDraft], missingRequired: [String] = []) {
        self.id = id; self.fields = fields; self.missingRequired = missingRequired
    }
}

public struct MatchedCard: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: String
    /// 所属 OCR 记录的页号（0 起；单图恒 0）
    public let pageIndex: Int
    /// 卡级共享字段（日期/医院/科室…）
    public var shared: [FieldDraft]
    /// 同类多实例（检验项目/药品行）
    public var rows: [MatchedCardRow]
    public let allFieldCoverage: Double
    public let requiredCoverage: Double
    /// 卡级缺失必填（去重键口径；≤20%，卡内单行补填）
    public let missingRequired: [CompletenessFieldRule]
    /// 四级完整度徽章（`CompletenessEvaluator` 口径，不决定建卡）
    public let level: CompletenessLevel

    public init(id: UUID = UUID(), kind: String, pageIndex: Int, shared: [FieldDraft], rows: [MatchedCardRow],
                allFieldCoverage: Double, requiredCoverage: Double,
                missingRequired: [CompletenessFieldRule], level: CompletenessLevel) {
        self.id = id; self.kind = kind; self.pageIndex = pageIndex
        self.shared = shared; self.rows = rows
        self.allFieldCoverage = allFieldCoverage; self.requiredCoverage = requiredCoverage
        self.missingRequired = missingRequired; self.level = level
    }

    /// 卡内全部字段（共享 + 各行）——完整度徽章与持久化的统一读面
    public var allFields: [FieldDraft] { shared + rows.flatMap(\.fields) }
}

public enum CardTemplateMatcher {
    /// OCR 侧模板目录（可扩展：新增卡类 = 加一行模板 + 对应提取器；无映射的卡类恒不匹配）
    public static let ocrTemplates: [CardTemplate] = [
        CardTemplate(kind: "metric_sample", rowKey: "lab_item",
                     mapping: ["lab_item": "lab_item", "report_date": "measured_at",
                               "reference_range": "reference_range"],
                     rowLevelKeys: ["raw_label", "value", "unit", "metric_key", "ref_low", "ref_high"],
                     derived: ["metric_key"]),
        CardTemplate(kind: "encounter", rowKey: nil,
                     mapping: ["report_date": "date", "dept": "department",
                               "chief_complaint": "chief_complaint", "diagnosis": "diagnosis_text",
                               "treatment": "advice_text", "hospital": "hospital", "doctor": "doctor"],
                     derived: ["kind"],
                     requiresDocumentType: ["outpatient_record", "diagnosis_certificate"]),
        CardTemplate(kind: "prescription", rowKey: "drug_name",
                     mapping: ["drug_name": "drug_name", "prescribed_at": "prescribed_at",
                               "hospital": "hospital", "doctor": "doctor", "advice_text": "advice_text"],
                     rowLevelKeys: ["drug_name"]),
        // 目录登记、无提取器（本轮不匹配）——诚实标注，避免「支持」假象
        CardTemplate(kind: "medication", rowKey: "generic_name", mapping: [:], rowLevelKeys: ["generic_name"]),
        CardTemplate(kind: "immunization", rowKey: nil, mapping: [:]),
        CardTemplate(kind: "appointment", rowKey: nil, mapping: [:]),
        CardTemplate(kind: "claim_item", rowKey: nil, mapping: [:]),
    ]

    /// 单页匹配：返回全部达线卡（每类至多一张，按模板目录顺序）。
    public static func match(fields: [FieldDraft], pageIndex: Int, documentTypeKey: String?,
                             templates: [CardTemplate] = ocrTemplates) -> [MatchedCard] {
        templates.compactMap { template in
            if let required = template.requiresDocumentType {
                guard let documentTypeKey, required.contains(documentTypeKey) else { return nil }
            }
            return matchOne(template, fields: fields, pageIndex: pageIndex, documentTypeKey: documentTypeKey)
        }
    }

    // MARK: - 单模板匹配

    private static func matchOne(_ template: CardTemplate, fields: [FieldDraft], pageIndex: Int,
                                 documentTypeKey: String?) -> MatchedCard? {
        let rules = CompletenessEvaluator.rules(for: template.kind)
        guard !rules.isEmpty, !template.mapping.isEmpty else { return nil }
        let ruleKeys = Set(rules.map(\.key))
        let requiredRules = rules.filter(\.isRequired)

        // 1. 行：每个 rowKey 实例一行；同 rawText 的伴随字段（参考范围）归入该行
        var rows: [MatchedCardRow] = []
        var consumed = Set<Int>()   // 已归行的字段下标（不再进共享）
        if let rowKey = template.rowKey {
            for (index, draft) in fields.enumerated() where draft.key == rowKey {
                consumed.insert(index)
                var rowFields = rowFields(for: template, draft: draft)
                if let raw = draft.rawText {
                    for (companionIndex, companion) in fields.enumerated()
                    where companionIndex != index && companion.rawText == raw && companion.key != rowKey {
                        consumed.insert(companionIndex)
                        rowFields += companionFields(for: template, draft: companion)
                    }
                }
                let present = Set(rowFields.map(\.key))
                let missing = requiredRules.map(\.key).filter { template.rowLevelKeys.contains($0) && !present.contains($0) }
                rows.append(MatchedCardRow(fields: rowFields, missingRequired: missing))
            }
            guard !rows.isEmpty else { return nil }
        } else {
            rows = [MatchedCardRow(fields: [])]
        }

        // 2. 共享：其余已映射字段（同键取首个，保持原序）。规则表外的映射键
        //（如 encounter.diagnosis_text/advice_text）随卡携带供持久化，但不计覆盖。
        var shared: [FieldDraft] = []
        var sharedKeys = Set<String>()
        for (index, draft) in fields.enumerated() where !consumed.contains(index) {
            guard let mapped = template.mapping[draft.key],
                  !template.rowLevelKeys.contains(mapped), sharedKeys.insert(mapped).inserted else { continue }
            var copy = draft
            copy.key = mapped
            shared.append(copy)
        }
        // 派生共享键（就诊类型由文档判定派生）
        if template.derived.contains("kind"), ruleKeys.contains("kind"), let documentTypeKey {
            shared.append(FieldDraft(key: "kind", value: encounterKind(for: documentTypeKey), confidence: 0.9,
                                     source: .heuristic))
        }

        // 3. 覆盖率（去重键；派生键已作为字段写入共享/行，自然计入）
        var covered = Set(shared.map(\.key))
        for row in rows { covered.formUnion(row.fields.map(\.key)) }
        covered = covered.intersection(ruleKeys)
        let allCoverage = Double(covered.count) / Double(rules.count)
        let requiredCovered = requiredRules.filter { covered.contains($0.key) }.count
        let requiredCoverage = requiredRules.isEmpty ? 1 : Double(requiredCovered) / Double(requiredRules.count)
        guard allCoverage >= CardMatchThresholds.allFields,
              requiredCoverage >= CardMatchThresholds.requiredFields else { return nil }

        let missingRequired = requiredRules.filter { !covered.contains($0.key) }
        // 徽章：用共享 + 首行字段评估（行级重复键只计一次，与 assess 的去重语义一致）
        let badgeFields = shared + (rows.first?.fields ?? [])
        let level = CompletenessEvaluator.assess(fields: badgeFields, cardKind: template.kind).level
        return MatchedCard(kind: template.kind, pageIndex: pageIndex, shared: shared, rows: rows,
                           allFieldCoverage: allCoverage, requiredCoverage: requiredCoverage,
                           missingRequired: missingRequired, level: level)
    }

    /// 行触发字段 → 行级字段（检验项目「名称 数值」拆分 + 单位 + 派生 metric_key；药名恒等）
    private static func rowFields(for template: CardTemplate, draft: FieldDraft) -> [FieldDraft] {
        switch template.kind {
        case "metric_sample":
            let (name, number) = UnderstandingCodeResolution.splitReading(draft.value)
            var out: [FieldDraft] = []
            let label = name.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty {
                out.append(FieldDraft(key: "raw_label", value: label, confidence: draft.confidence,
                                      rawText: draft.rawText, source: draft.source, codeResolution: draft.codeResolution))
                // metric_key 派生：编码建议存在用编码，否则以原始名占位（F25 惰性，BR-003 确认后回填）
                let key = draft.codeResolution.map { "code.\($0.canonicalCode)" } ?? "lab.\(label)"
                out.append(FieldDraft(key: "metric_key", value: key, confidence: draft.confidence, source: .heuristic))
            }
            if let number, !number.isEmpty {
                out.append(FieldDraft(key: "value", value: number, confidence: draft.confidence, rawText: draft.rawText))
            }
            if let unit = draft.unit, !unit.isEmpty {
                out.append(FieldDraft(key: "unit", value: unit, confidence: draft.confidence, rawText: draft.rawText))
            }
            return out
        default:
            var copy = draft
            copy.key = template.mapping[draft.key] ?? draft.key
            return [copy]
        }
    }

    /// 同 rawText 伴随字段 → 行级字段（参考范围「低-高」拆 ref_low/ref_high）
    private static func companionFields(for template: CardTemplate, draft: FieldDraft) -> [FieldDraft] {
        guard template.kind == "metric_sample", draft.key == "reference_range",
              let (low, high) = referenceBounds(draft.value) else { return [] }
        return [FieldDraft(key: "ref_low", value: low, confidence: draft.confidence, rawText: draft.rawText),
                FieldDraft(key: "ref_high", value: high, confidence: draft.confidence, rawText: draft.rawText)]
    }

    /// 「3.5-9.5」「3.5～9.5」「3.5 ~ 9.5」→ (低, 高)；解析失败 nil（不猜范围）
    static func referenceBounds(_ text: String) -> (String, String)? {
        let separators = CharacterSet(charactersIn: "-–~～")
        let parts = text.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, Double(parts[0]) != nil, Double(parts[1]) != nil else { return nil }
        return (parts[0], parts[1])
    }

    /// 文档类型判定 → 就诊类型（诊断证明/门诊病历均按门诊；其余类型不出就诊卡）
    static func encounterKind(for documentTypeKey: String) -> String {
        switch documentTypeKey {
        case "outpatient_record", "diagnosis_certificate": return EncounterKind.outpatient.rawValue
        default: return EncounterKind.outpatient.rawValue
        }
    }
}

/// 确认后的检验项目 → `metric_sample` 医院来源行（FR7.9/FR7.2：A 级参考范围随行、
/// 原始指标名保真 FR25.4、编码只在用户确认建议后回填 FR25.11）。
public struct HospitalSample: Sendable, Equatable {
    public var metricKey: String
    public var rawLabel: String
    public var value: Double
    public var unit: String
    public var measuredAt: Date
    public var refLow: Double?
    public var refHigh: Double?
    public var refSourceLabel: String?
    public var codeConceptId: String?
    public init(metricKey: String, rawLabel: String, value: Double, unit: String, measuredAt: Date,
                refLow: Double? = nil, refHigh: Double? = nil, refSourceLabel: String? = nil,
                codeConceptId: String? = nil) {
        self.metricKey = metricKey; self.rawLabel = rawLabel; self.value = value; self.unit = unit
        self.measuredAt = measuredAt; self.refLow = refLow; self.refHigh = refHigh
        self.refSourceLabel = refSourceLabel; self.codeConceptId = codeConceptId
    }

    /// 文档页回链（`metric_sample.source_ref`）：`doc:<uuid>#p<index>`
    public static func sourceRef(documentId: UUID, pageIndex: Int) -> String {
        "doc:\(documentId.uuidString)#p\(pageIndex)"
    }
}
