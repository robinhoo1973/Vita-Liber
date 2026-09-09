import Foundation

/// FR6.9 识别卡片完整度评估（data-flow §17 单一事实源）：
/// 识别文本（OCR/语音/手工）经理解层产出 `FieldDraft[]` 后、生成信息卡片前，
/// 先按卡片类型的 required_fields/recommended_fields 权重计分，四级完整度
/// 决定走向：完整/基本完整 → FR17.13 确认流程；部分完整 → 确认卡提供
/// 「跳过稍后」→ pending_card 待办；严重缺失 → 不建卡退回原始记录。
/// 纯函数、零依赖（BR 规则落 Domain 的四规则之一）。

public enum CompletenessLevel: String, Sendable, Equatable, Codable {
    case complete            // 完整：required 全识别且 score ≥ 0.85
    case basicallyComplete   // 基本完整：required 全识别但低置信/建议字段缺失
    case partiallyComplete   // 部分完整：≥50% required 识别 → 可跳过稍后
    case severelyIncomplete  // 严重缺失：<50% required → 不建卡退回原文
}

/// 单个字段的完整度规则（data-flow §17.2 矩阵的行投影）。
public struct CompletenessFieldRule: Sendable, Equatable {
    public var key: String
    public var isRequired: Bool
    public var weight: Double   // required=1.0 / recommended=0.3（§17.1.2）

    public init(key: String, isRequired: Bool) {
        self.key = key
        self.isRequired = isRequired
        self.weight = isRequired ? 1.0 : 0.3
    }
}

/// 评估结果（值类型，视图/存储零逻辑）。
public struct CompletenessAssessment: Sendable, Equatable {
    public var level: CompletenessLevel
    public var score: Double
    /// 已识别的 required 字段键（value 非空即识别，confidence 单独呈现）
    public var recognizedRequired: [String]
    /// 缺失字段规则清单（含 key/label 语义由调用方经 L10n 呈现）
    public var missingFields: [CompletenessFieldRule]
    /// 已识别但 confidence < 0.85 的字段键（§17.1.1 低置信黄标复核）
    public var lowConfidenceFields: [String]
    /// required 识别率（0..1）
    public var requiredCoverage: Double

    public init(level: CompletenessLevel, score: Double,
                recognizedRequired: [String], missingFields: [CompletenessFieldRule],
                lowConfidenceFields: [String], requiredCoverage: Double) {
        self.level = level
        self.score = score
        self.recognizedRequired = recognizedRequired
        self.missingFields = missingFields
        self.lowConfidenceFields = lowConfidenceFields
        self.requiredCoverage = requiredCoverage
    }
}

public enum CompletenessEvaluator {
    /// patient_id 为上下文字段（成员上下文恒存在），非识别产物——权重计满。
    public static let contextSatisfiedKeys: Set<String> = ["patient_id"]

    /// data-flow §17.2 各类卡片完整度矩阵（单一事实源）。
    /// 未登记的 card_kind 按保守口径：无 required 规则 → 恒完整
    /// （自动生成实体 alert_event/sent_message/emergency_card_selection
    /// 极少缺失，§21.1 跳过待办机制）。
    public static func rules(for cardKind: String) -> [CompletenessFieldRule] {
        switch cardKind {
        case "prescription":
            return [
                .init(key: "drug_name", isRequired: true),
                .init(key: "prescribed_at", isRequired: true),
                .init(key: "hospital", isRequired: false),
                .init(key: "doctor", isRequired: false),
                .init(key: "advice_text", isRequired: false),
            ]
        case "medication":
            return [
                .init(key: "generic_name", isRequired: true),
                .init(key: "unit_kind", isRequired: true),
                .init(key: "brand_name", isRequired: false),
                .init(key: "spec", isRequired: false),
                .init(key: "drug_key", isRequired: false),
            ]
        case "medication_plan":
            return [
                .init(key: "medication_id", isRequired: true),
                .init(key: "schedule_json", isRequired: true),
                .init(key: "start_date", isRequired: true),
                .init(key: "end_date", isRequired: false),
                .init(key: "dose_plan_units", isRequired: false),
            ]
        case "stock_lot":
            return [
                .init(key: "medication_id", isRequired: true),
                .init(key: "total_units", isRequired: true),
                .init(key: "prescription_id", isRequired: false),
                .init(key: "expire_at", isRequired: false),
                .init(key: "storage_note", isRequired: false),
            ]
        case "reminder":
            return [
                .init(key: "kind", isRequired: true),
                .init(key: "title", isRequired: true),
                .init(key: "at_date", isRequired: true),
                .init(key: "repeats", isRequired: false),
                .init(key: "channel_pref", isRequired: false),
            ]
        case "encounter":
            return [
                .init(key: "date", isRequired: true),
                .init(key: "kind", isRequired: true),
                .init(key: "hospital", isRequired: false),
                .init(key: "department", isRequired: false),
                .init(key: "doctor", isRequired: false),
                .init(key: "chief_complaint", isRequired: false),
            ]
        case "metric_sample":
            return [
                .init(key: "metric_key", isRequired: true),
                .init(key: "value", isRequired: true),
                .init(key: "unit", isRequired: true),
                .init(key: "measured_at", isRequired: true),
                .init(key: "ref_low", isRequired: false),
                .init(key: "ref_high", isRequired: false),
                .init(key: "raw_label", isRequired: false),
                .init(key: "code_concept_id", isRequired: false),
            ]
        case "document_file":
            return [
                .init(key: "doc_type", isRequired: true),
                .init(key: "ocr_text", isRequired: false),
                .init(key: "grade", isRequired: false),
            ]
        case "health_problem":
            return [
                .init(key: "name", isRequired: true),
                .init(key: "kind", isRequired: false),
            ]
        case "voice_note":
            return [
                .init(key: "body", isRequired: true),
                .init(key: "occurred_at", isRequired: true),
                .init(key: "in_timeline", isRequired: true),
                .init(key: "tags", isRequired: false),
                .init(key: "encounter_id", isRequired: false),
            ]
        case "observation":
            return [
                .init(key: "kind", isRequired: true),
                .init(key: "occurred_at", isRequired: true),
                .init(key: "consulted_doctor", isRequired: true),
                .init(key: "description", isRequired: false),
                .init(key: "body_part", isRequired: false),
                .init(key: "duration_min", isRequired: false),
                .init(key: "frequency", isRequired: false),
            ]
        case "allergy_event":
            return [
                .init(key: "substance", isRequired: true),
                .init(key: "reaction_tags", isRequired: true),
                .init(key: "severity", isRequired: true),
                .init(key: "consulted_doctor", isRequired: true),
                .init(key: "occurred_at", isRequired: false),
                .init(key: "duration_min", isRequired: false),
                .init(key: "treatment_note", isRequired: false),
            ]
        case "immunization":
            return [
                .init(key: "vaccine_name", isRequired: true),
                .init(key: "dose_number", isRequired: true),
                .init(key: "administered_at", isRequired: true),
                .init(key: "provider", isRequired: true),
                .init(key: "lot_number", isRequired: false),
                .init(key: "encounter_id", isRequired: false),
            ]
        case "appointment":
            return [
                .init(key: "hospital", isRequired: true),
                .init(key: "starts_at", isRequired: true),
                .init(key: "kind", isRequired: true),
                .init(key: "department", isRequired: false),
                .init(key: "doctor", isRequired: false),
                .init(key: "address", isRequired: false),
                .init(key: "booking_no", isRequired: false),
            ]
        case "claim_item":
            return [
                .init(key: "amount", isRequired: true),
                .init(key: "currency", isRequired: true),
                .init(key: "date", isRequired: true),
                .init(key: "item_type", isRequired: true),
                .init(key: "encounter_id", isRequired: false),
                .init(key: "document_file_id", isRequired: false),
                .init(key: "merchant", isRequired: false),
                .init(key: "summary", isRequired: false),
            ]
        default:
            return []
        }
    }

    /// §17.1.2 评估公式：
    /// score = Σ(field.weight × field.confidence) / Σ(field.weight)
    /// 缺失字段 confidence = 0；上下文字段（patient_id）计满。
    /// 判定：score ≥ 0.85 且 required 全在 → 完整；
    /// score ≥ 0.60 且 required 全在 → 基本完整；
    /// score ≥ 0.40 且 ≥50% required → 部分完整；否则严重缺失。
    public static func assess(fields: [FieldDraft], cardKind: String) -> CompletenessAssessment {
        let rules = rules(for: cardKind)
        let byKey = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var totalWeight = 0.0
        var weightedConfidence = 0.0
        var recognized: [String] = []
        var missing: [CompletenessFieldRule] = []
        var lowConfidence: [String] = []
        let required = rules.filter(\.isRequired)
        let requiredCount = required.count

        for rule in rules {
            totalWeight += rule.weight
            if contextSatisfiedKeys.contains(rule.key) {
                weightedConfidence += rule.weight * 1.0
                if rule.isRequired { recognized.append(rule.key) }
                continue
            }
            guard let draft = byKey[rule.key], !draft.value.isEmpty else {
                missing.append(rule)
                continue  // confidence = 0
            }
            if rule.isRequired { recognized.append(rule.key) }
            weightedConfidence += rule.weight * min(max(draft.confidence, 0), 1)
            if draft.confidence < 0.85 { lowConfidence.append(rule.key) }
        }

        let score = totalWeight > 0 ? weightedConfidence / totalWeight : 1.0
        let allRequiredPresent = recognized.count >= requiredCount
        let coverage = requiredCount > 0
            ? Double(recognized.count) / Double(requiredCount)
            : 1.0

        let level: CompletenessLevel
        if allRequiredPresent && score >= 0.85 {
            level = .complete
        } else if allRequiredPresent && score >= 0.60 {
            level = .basicallyComplete
        } else if coverage >= 0.5 && score >= 0.40 {
            level = .partiallyComplete
        } else {
            level = .severelyIncomplete
        }
        return CompletenessAssessment(level: level, score: score,
                                      recognizedRequired: recognized,
                                      missingFields: missing,
                                      lowConfidenceFields: lowConfidence,
                                      requiredCoverage: coverage)
    }

    /// 处方 OCR 路径键归一：该路径字段是 rx_line_N + L10n 标签（非 §17.2
    /// 稳定键）——按标签身份归一到稳定键再评估：
    /// drugName → drug_name；hospital → hospital；doctor → doctor；
    /// 含年份日期的行 → prescribed_at（宽松判定，仅作完整度输入，
    /// 不产生任何事实）。其余行保留 rx_line_N（不进 required 统计）。
    public static func prescriptionFieldDrafts(
        fields: [CandidateField], labels: PrescriptionFieldMapper.Labels
    ) -> [FieldDraft] {
        let datePattern = try? NSRegularExpression(pattern: #"\d{4}\s*[-/年.]\s*\d{1,2}"#)   // try?-ok: 静态正则字面量，构造失败仅日期行归一降级，不阻断评估
        var out: [FieldDraft] = []
        for field in fields {
            let key: String
            if field.displayLabel == labels.drugName {
                key = "drug_name"
            } else if field.displayLabel == labels.hospital {
                key = "hospital"
            } else if field.displayLabel == labels.doctor {
                key = "doctor"
            } else if datePattern?.firstMatch(
                in: field.value, range: NSRange(field.value.startIndex..., in: field.value)) != nil {
                key = "prescribed_at"
            } else {
                continue   // 未归一化行不参与评估（dosage/frequency 等非 §17.2 键）
            }
            out.append(FieldDraft(key: key, value: field.value,
                                  confidence: field.confidence,
                                  rawText: field.rawText))
        }
        return out
    }
}
