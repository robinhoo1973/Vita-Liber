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
    /// 行触发键无实例时仍产一空行（表头即实体；票据页无费用明细行时行为不变）。与 `CardKindEntry.allowsEmptyRows` 同源。
    public let allowsEmptyRows: Bool

    public init(kind: String, rowKey: String?, mapping: [String: String],
                rowLevelKeys: Set<String> = [], derived: Set<String> = [],
                requiresDocumentType: Set<String>? = nil, allowsEmptyRows: Bool = false) {
        self.kind = kind; self.rowKey = rowKey; self.mapping = mapping
        self.rowLevelKeys = rowLevelKeys; self.derived = derived
        self.requiresDocumentType = requiresDocumentType
        self.allowsEmptyRows = allowsEmptyRows
    }
}

public struct MatchedCardRow: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var fields: [FieldDraft]
    /// 该行缺失的行级必填键（保存时跳过本行、不阻断其他行）
    public var missingRequired: [String]
    public init(id: UUID = UUID(), fields: [FieldDraft], missingRequired: [String] = []) {
        self.id = id; self.fields = fields; self.missingRequired = missingRequired
    }
}

public struct MatchedCard: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: String
    /// 所属 OCR 记录的页号（0 起；单图恒 0）
    public let pageIndex: Int
    /// 卡级共享字段（日期/医院/科室…）
    public var shared: [FieldDraft]
    /// 同类多实例（检验项目/药品行）
    public var rows: [MatchedCardRow]
    public var encounterAssociation: EncounterAssociation
    public let allFieldCoverage: Double
    public let requiredCoverage: Double
    /// 卡级缺失必填（去重键口径；≤20%，卡内单行补填）
    public let missingRequired: [CompletenessFieldRule]
    /// 四级完整度徽章（`CompletenessEvaluator` 口径，不决定建卡）
    public let level: CompletenessLevel

    public init(id: UUID = UUID(), kind: String, pageIndex: Int, shared: [FieldDraft], rows: [MatchedCardRow],
                allFieldCoverage: Double, requiredCoverage: Double,
                 missingRequired: [CompletenessFieldRule], level: CompletenessLevel,
                 encounterAssociation: EncounterAssociation = .unselected) {
        self.id = id; self.kind = kind; self.pageIndex = pageIndex
        self.shared = shared; self.rows = rows
        self.allFieldCoverage = allFieldCoverage; self.requiredCoverage = requiredCoverage
        self.missingRequired = missingRequired; self.level = level
        self.encounterAssociation = encounterAssociation
    }

    /// 卡内全部字段（共享 + 各行）——完整度徽章与持久化的统一读面
    public var allFields: [FieldDraft] { shared + rows.flatMap(\.fields) }

    /// Row identity survives editing; a label/unit edit invalidates the whole coding suggestion.
    /// 规则主体在 `CardConfirmationRules.revise`（Domain 单一事实源，结构轮 2026-09-15）——
    /// 本方法为值模型上的薄转发，调用点零改。
    public mutating func reviseField(at index: Int, rowId: UUID? = nil, to value: String) {
        CardConfirmationRules.revise(&self, at: index, rowId: rowId, to: value)
    }

    /// FR6.9 卡级确认（V3.66 立，**2026-09-17 判据改判**）：保存前把本卡**符合资格谓词**
    /// 的字段升级为已确认——非拒绝 ∧ 有值 ∧ 置信 ≥0.6 ∧ 无待定歧义 ∧ **非必填**；
    /// 必填（含行级身份键）一律逐一确认，用户以**卡级显式确认动作**（[确认保存]）完成
    /// 其余合格字段的 D→C。规则主体在 `CardConfirmationRules.confirmingAllFields`（单一事实源）。
    public func confirmingAllFields() -> MatchedCard {
        CardConfirmationRules.confirmingAllFields(self)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pageIndex, shared, rows, allFieldCoverage, requiredCoverage, missingRequired, level, encounterAssociation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        shared = try c.decode([FieldDraft].self, forKey: .shared)
        rows = try c.decode([MatchedCardRow].self, forKey: .rows)
        allFieldCoverage = try c.decode(Double.self, forKey: .allFieldCoverage)
        requiredCoverage = try c.decode(Double.self, forKey: .requiredCoverage)
        let missing = try c.decode([String].self, forKey: .missingRequired)
        missingRequired = missing.map { CompletenessFieldRule(key: $0, isRequired: true) }
        level = try c.decode(CompletenessLevel.self, forKey: .level)
        encounterAssociation = try c.decodeIfPresent(EncounterAssociation.self, forKey: .encounterAssociation) ?? .unselected
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind)
        try c.encode(pageIndex, forKey: .pageIndex); try c.encode(shared, forKey: .shared)
        try c.encode(rows, forKey: .rows); try c.encode(allFieldCoverage, forKey: .allFieldCoverage)
        try c.encode(requiredCoverage, forKey: .requiredCoverage)
        try c.encode(missingRequired.map(\.key), forKey: .missingRequired); try c.encode(level, forKey: .level)
        try c.encode(encounterAssociation, forKey: .encounterAssociation)
    }
}

public enum CardTemplateMatcher {
    /// OCR 侧模板目录（可扩展：新增卡类 = 加一行模板 + 对应提取器；无映射的卡类恒不匹配）
    public static let ocrTemplates: [CardTemplate] = [
        // v26 检验「表头 + 行」（§C.5）：表头键与 lab_report 列一一对应（collect_time/report_time 为理解层别名）；
        // 行级 abnormal_flag/reference_text/method 经同 rawText 伴随归行（打印原文，不计算不解释——BR-004/012）。
        CardTemplate(kind: "metric_sample", rowKey: "lab_item",
                     mapping: ["lab_item": "lab_item", "report_date": "measured_at",
                               "reference_range": "reference_range", "hospital": "hospital",
                               "dept": "department", "lab_name": "lab_name", "report_no": "report_no",
                               "specimen_type": "specimen_type", "specimen_no": "specimen_no", "test_class": "test_class",
                               "clinical_diagnosis": "clinical_diagnosis",
                               "collected_at": "collected_at", "collect_time": "collected_at", "received_at": "received_at",
                               "reported_at": "reported_at", "report_time": "reported_at",
                               "send_doctor": "send_doctor", "test_doctor": "test_doctor", "review_doctor": "review_doctor",
                               "abnormal_flag": "abnormal_flag", "reference_text": "reference_text", "method": "method"],
                     rowLevelKeys: ["raw_label", "value", "unit", "metric_key", "ref_low", "ref_high", "abnormal_flag", "reference_text", "method"],
                     derived: ["metric_key"]),
        CardTemplate(kind: "encounter", rowKey: nil,
                     mapping: ["report_date": "date", "dept": "department",
                               "chief_complaint": "chief_complaint", "diagnosis": "diagnosis_text",
                               "treatment": "advice_text", "hospital": "hospital", "doctor": "doctor",
                               "present_illness": "present_illness", "illness_summary": "present_illness",
                               "visit_summary": "visit_summary",
                               // v25 叙事列（§C.1）：原文保存；allergy_history 兼作资料建议来源（D4）。
                               "past_history": "past_history", "physical_exam": "physical_exam", "allergy_history": "allergy_history"],
                     derived: ["kind"],
                     requiresDocumentType: ["outpatient_record", "diagnosis_certificate", "emergency_record"]),
        // v26 住院期（§C.2）：单行卡；kind（inpatient|daySurgery）由文档类型键派生；叙事列原文保存；带药只存原文（BR-006）。
        CardTemplate(kind: "hospitalization", rowKey: nil,
                     mapping: ["hospital": "hospital", "admit_at": "admit_at", "discharge_at": "discharge_at",
                               "medical_record_no": "medical_record_no", "inpatient_times": "inpatient_times", "actual_days": "actual_days",
                               "admit_dept": "admit_dept", "discharge_dept": "discharge_dept", "ward": "ward", "bed_no": "bed_no",
                               "admit_route": "admit_route", "payment_type": "payment_type", "discharge_way": "discharge_way",
                               "attending_physician": "attending_physician",
                               "admit_diagnosis": "admit_diagnosis", "discharge_diagnosis": "discharge_diagnosis",
                               "admit_condition": "admit_condition", "treatment_course": "treatment_course",
                               "discharge_condition": "discharge_condition", "discharge_orders": "discharge_orders",
                               "take_home_drugs": "take_home_drugs", "total_cost": "total_cost",
                               "summary_doctor": "summary_doctor", "summary_date": "summary_date"],
                     derived: ["kind"],
                     requiresDocumentType: ["inpatient_record", "discharge_summary", "day_surgery_record"]),
        // v26 诊断（§C.3）：diagnosis_item 每实例一行；同行 diagnosis_code/diagnosis_type 归行；共享 diagnosis_type = 文档键派生默认。
        CardTemplate(kind: "diagnosis", rowKey: "diagnosis_item",
                     mapping: ["diagnosis_item": "name", "diagnosis_code": "code_text", "code_system": "code_system",
                               "diagnosis_type": "diagnosis_type", "diagnosed_at": "diagnosed_at", "report_date": "diagnosed_at",
                               "hospital": "hospital"],
                     rowLevelKeys: ["name", "code_text", "code_system", "diagnosis_type"],
                     derived: ["diagnosis_type"],
                     requiresDocumentType: ["outpatient_record", "emergency_record", "diagnosis_certificate",
                                            "inpatient_record", "discharge_summary", "day_surgery_record", "pathology_report"]),
        // v26 检查报告（§C.4）：单行卡；report_type 由理解层/标题词表归一为 canonical raw，病理文档键派生 pathology。
        CardTemplate(kind: "exam_report", rowKey: nil,
                     mapping: ["report_type": "report_type", "hospital": "hospital", "dept": "department", "report_no": "report_no",
                               "exam_part": "exam_part", "exam_method": "exam_method",
                               "exam_at": "exam_at", "report_date": "exam_at", "reported_at": "reported_at",
                               "findings": "findings", "impression": "impression",
                               "apply_doctor": "apply_doctor", "report_doctor": "report_doctor", "review_doctor": "review_doctor"],
                     derived: ["report_type"],
                     requiresDocumentType: ["exam_report", "pathology_report", "checkup_report"]),
        // v25 处方「表头 + 行」（§C.6）：表头七键共享；行级键与 prescription_line 列一一对应（键集见 CardKindRegistry）。
        CardTemplate(kind: "prescription", rowKey: "drug_name",
                     mapping: ["drug_name": "drug_name", "prescribed_at": "prescribed_at",
                               // 2026-09-19 审查修复：通用「日期」键桥接进处方日期——他轨
                               // （NL/fallback）产出 report_date 草稿时此前被 buildShared 静默丢弃，
                               // prescribed_at 为空 → requiredCoverage 0.5 < 0.8 整卡可被拒。
                               "report_date": "prescribed_at",
                               "hospital": "hospital", "doctor": "doctor", "advice_text": "advice_text",
                               "dept": "department", "prescription_no": "prescription_no", "prescription_type": "prescription_type",
                               "fee_type": "fee_type", "clinical_diagnosis": "clinical_diagnosis",
                               "pharmacist_names": "pharmacist_names", "total_amount": "total_amount",
                               "spec": "spec", "dosage": "dosage", "quantity": "quantity",
                               "frequency": "frequency", "route": "route", "days": "days", "note": "note",
                               "drug_form": "drug_form", "generic_name": "generic_name", "brand_name": "brand_name",
                               "start_date": "start_date", "end_date": "end_date", "as_needed": "as_needed",
                               "medication_notes": "medication_notes", "insurance_code": "insurance_code",
                               "item_code": "item_code", "unit_price": "unit_price", "line_amount": "line_amount"],
                     rowLevelKeys: ["drug_name", "spec", "dosage", "quantity", "frequency", "route", "days", "note",
                                    "drug_form", "generic_name", "brand_name", "start_date", "end_date", "as_needed",
                                    "medication_notes", "insurance_code", "item_code", "unit_price", "line_amount"]),
        // v27 体检首页（子项目 J · round1 §E.1）：单行卡；机构（体检机构常印为「医院」）/ 编号 / 套餐 / 体检日期 / 总检医师 / 报告日期 +
        // 一般检查原文（blood_pressure「128/82」在匹配前拆 systolic/diastolic）+ 总检结论 / 健康指导（多段并入）。仅体检报告文档。
        CardTemplate(kind: "health_exam", rowKey: nil,
                     mapping: ["org_name": "org_name", "hospital": "org_name", "exam_no": "exam_no", "package_name": "package_name",
                               "exam_date": "exam_date", "report_date": "exam_date", "reported_at": "report_date", "total_doctor": "total_doctor",
                               "height": "height", "weight": "weight", "bmi": "bmi", "systolic": "systolic", "diastolic": "diastolic",
                               "pulse": "pulse", "waist": "waist", "vision_left": "vision_left", "vision_right": "vision_right",
                               "overall_conclusion": "overall_conclusion", "health_guidance": "health_guidance"],
                     requiresDocumentType: ["checkup_report"]),
        // v27 结论页（§E.1 / 融合方案 §六-6.3）：conclusion_item 每实例一行；同行 conclusion_type / severity 归行（严重度为打印原文，
        // 不编码不着色——BR-004/012）；共享机构 / 日期 / 编号随卡携带供主卡草稿派生。本轮只从体检文档产出（父 = 体检）。
        CardTemplate(kind: "clinical_conclusion", rowKey: "conclusion_item",
                     mapping: ["conclusion_item": "content", "conclusion_type": "conclusion_type", "severity": "severity",
                               "org_name": "org_name", "hospital": "org_name", "exam_date": "exam_date", "report_date": "exam_date", "exam_no": "exam_no"],
                     rowLevelKeys: ["content", "conclusion_type", "severity"],
                     requiresDocumentType: ["checkup_report"]),
        // v27 手术记录（原 D3 §C.8）：单行卡；编码 / 级别 / 植入物 / 出血量等一律打印原文。泛日期（report_date）**不**冒充手术日期——
        // 出院小结多日期并存，只认「手术日期」显式标签（不猜日期）。
        CardTemplate(kind: "surgery", rowKey: nil,
                     mapping: ["hospital": "hospital", "dept": "department", "surgery_at": "surgery_at", "ended_at": "ended_at",
                               "surgery_name": "surgery_name", "surgery_code": "surgery_code", "surgery_level": "surgery_level",
                               "surgeon": "surgeon", "assistants": "assistants", "anesthesiologist": "anesthesiologist", "anesthesia_method": "anesthesia_method",
                               "preop_diagnosis": "preop_diagnosis", "postop_diagnosis": "postop_diagnosis",
                               "procedure_course": "procedure_course", "intraop_findings": "intraop_findings",
                               "implants": "implants", "specimen": "specimen", "blood_loss": "blood_loss", "transfusion": "transfusion", "drainage": "drainage",
                               "postop_orders": "postop_orders", "complications": "complications"],
                     requiresDocumentType: ["surgery_record", "day_surgery_record", "discharge_summary"]),
        // v27 门诊治疗 / 输液 / 注射 / 理疗（原 D3 §C.9）：单行卡；单日期文书——泛日期即治疗日期（同处方 / 票据纪律）；
        // 药物原文 drugs_text 不拆行、不进 prescription_line / medication（BR-006/007，避免双计）。
        CardTemplate(kind: "treatment_record", rowKey: nil,
                     mapping: ["treatment_type": "treatment_type", "treated_at": "treated_at", "report_date": "treated_at",
                               "hospital": "hospital", "dept": "department", "doctor": "doctor", "executor": "executor",
                               "diagnosis": "diagnosis_text", "clinical_diagnosis": "diagnosis_text", "content": "content", "drugs_text": "drugs_text",
                               "session": "session", "adverse_reaction": "adverse_reaction", "result": "result", "note": "note"],
                     requiresDocumentType: ["treatment_record"]),
        CardTemplate(kind: "medication", rowKey: "generic_name",
                     mapping: ["generic_name":"generic_name", "brand_name":"brand_name", "spec":"spec", "unit_kind":"unit_kind"],
                     rowLevelKeys: ["generic_name", "brand_name", "spec", "unit_kind"]),
        CardTemplate(kind: "immunization", rowKey: nil,
                     mapping: ["vaccine_name":"vaccine_name", "dose_number":"dose_number", "administered_at":"administered_at", "provider":"provider", "lot_number":"lot_number"]),
        CardTemplate(kind: "appointment", rowKey: nil, mapping: [:]),
        // v25 票据「表头 + 费用明细行」（§C.7）：fee_item 每实例一行（清单页）；票据页无 fee_item 仍产一空行（行为不变）。
        CardTemplate(kind: "claim_item", rowKey: "fee_item",
                     mapping: ["amount":"amount", "currency":"currency", "report_date":"date", "item_type":"item_type", "merchant":"merchant", "hospital":"merchant", "summary":"summary",
                               "reimbursed_amount": "reimbursed_amount", "out_of_pocket": "out_of_pocket",
                               "personal_account_amount": "personal_account_amount", "invoice_no": "invoice_no", "insurance_type": "insurance_type",
                               "fee_item": "item_name", "item_amount": "item_amount", "unit_price": "unit_price", "item_quantity": "item_quantity",
                               "item_spec": "item_spec", "fee_category": "fee_category", "item_code": "item_code", "insurance_code": "insurance_code",
                               "executing_dept": "executing_dept", "self_pay_ratio": "self_pay_ratio", "fee_at": "fee_at"],
                     rowLevelKeys: ["item_name", "item_amount", "unit_price", "item_quantity", "item_spec", "fee_category", "item_code",
                                    "insurance_code", "executing_dept", "self_pay_ratio", "fee_at"],
                     allowsEmptyRows: true),
    ]

    /// 同键多段并入（换行拼接）的共享叙事键；其余共享键同键首个非空值胜出。
    private static let narrativeSharedKeys: Set<String> = [
        "advice_text", "present_illness", "visit_summary", "past_history", "physical_exam", "allergy_history",
        // 2026-09-19 审查修复：诊断系键（诊断/临床诊断/主诉）此前不在并入集——多行诊断
        // 只保留首行、后续行静默丢弃（BR-002 内容丢失）。并入与 fallback 轨 narrativeFieldKeys
        // 的「刻意不含 diagnosis/treatment」不同——此处是逐字锚定的同键草稿合并，不存在
        // 吞并后续结构化行的风险（吸收边界由 fallback 轨负责），故三键入集。
        "diagnosis_text", "clinical_diagnosis", "chief_complaint",
        // v26 住院/检查叙事列（§C.2/§C.4）
        "admit_diagnosis", "discharge_diagnosis", "admit_condition", "treatment_course", "discharge_condition", "discharge_orders", "take_home_drugs",
        "findings", "impression",
        // v27 体检 / 手术 / 治疗叙事列（子项目 J）：总检结论与健康指导多段；手术经过 / 术中所见 / 术后医嘱；治疗内容 / 药物原文
        "overall_conclusion", "health_guidance", "procedure_course", "intraop_findings", "postop_orders", "complications",
        "content", "drugs_text", "adverse_reaction",
    ]

    /// 检验行同 rawText 伴随键（参考范围拆 ref_low/ref_high；打印标记/参考原文/方法原样归行）。
    private static let labCompanionKeys: [String] = ["reference_range", "abnormal_flag", "reference_text", "method"]

    /// 行级伴随字段按同行/页内唯一证据归行的卡类（药品行/费用明细行/诊断行/结论行）。
    private static let rowCompanionKinds: Set<String> = ["medication", "prescription", "claim_item", "diagnosis", "clinical_conclusion"]

    /// v27 体检首页：理解层 `blood_pressure`「128/82」（打印的收缩/舒张合体）在匹配前按分隔符拆为 systolic / diastolic 两草稿
    /// （同 reference_range 拆 ref_low/ref_high 的纪律：只拆打印分隔，不猜、不换算；拆不开原样保留由用户处理）。
    private static func expandedFields(for template: CardTemplate, fields: [FieldDraft]) -> [FieldDraft] {
        guard template.kind == "health_exam", fields.contains(where: { $0.key == "blood_pressure" }) else { return fields }
        return fields.flatMap { draft -> [FieldDraft] in
            guard draft.key == "blood_pressure" else { return [draft] }
            guard let (systolic, diastolic) = ClinicalFieldLabels.splitBloodPressure(draft.value) else { return [draft] }
            let raw = draft.rawText ?? draft.originalValue
            return [FieldDraft(key: "systolic", value: systolic, unit: draft.unit, confidence: draft.confidence, rawText: raw, source: draft.source, sourceLineIndex: draft.sourceLineIndex),
                    FieldDraft(key: "diastolic", value: diastolic, unit: draft.unit, confidence: draft.confidence, rawText: raw, source: draft.source, sourceLineIndex: draft.sourceLineIndex)]
        }
    }

    /// 文档类型键派生的共享键值（D 级默认，Picker 可改）：就诊/住院 `kind`、诊断 `diagnosis_type`、病理文档 `report_type`。
    static func derivedValue(for key: String, documentTypeKey: String) -> String? {
        switch key {
        case "kind": return encounterKind(for: documentTypeKey)
        case "diagnosis_type": return EntityCardProjection.diagnosisType(forDocumentType: documentTypeKey)
        case "report_type": return documentTypeKey == "pathology_report" ? "pathology" : nil
        default: return nil
        }
    }

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

    private static func matchOne(_ template: CardTemplate, fields incoming: [FieldDraft], pageIndex: Int,
                                 documentTypeKey: String?) -> MatchedCard? {
        let rules = CompletenessEvaluator.rules(for: template.kind)
        guard !rules.isEmpty, !template.mapping.isEmpty else { return nil }
        let fields = expandedFields(for: template, fields: incoming)
        let ruleKeys = Set(rules.map(\.key))
        let requiredRules = rules.filter(\.isRequired)

        // 1. 行：每个 rowKey 实例一行；同 rawText 的伴随字段（参考范围）归入该行
        var consumed = Set<Int>()   // 已归行的字段下标（不再进共享）
        guard let rows = buildRows(for: template, fields: fields,
                                   requiredRules: requiredRules, consumed: &consumed) else { return nil }

        // 2. 共享：其余已映射字段（同键取首个，保持原序）+ 文档判定派生的共享键。
        let shared = buildShared(for: template, fields: fields, consumed: consumed,
                                 documentTypeKey: documentTypeKey, ruleKeys: ruleKeys)

        // 3. 覆盖率（去重键；派生键已作为字段写入共享/行，自然计入）
        var covered = Set((shared + rows.flatMap(\.fields)).filter {
            $0.grade != .rejected && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.key))
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

    /// 行装配：每个 rowKey 实例一行；检验伴随键（参考范围等）按同 rawText 归入该行、
    /// 药品/费用/诊断行的行级伴随字段按同行/唯一证据归行。无行触发键（单行卡）→
    /// 单一空行；行触发键无实例时 `allowsEmptyRows` 才产空行（票据页），否则 nil。
    private static func buildRows(for template: CardTemplate, fields: [FieldDraft],
                                  requiredRules: [CompletenessFieldRule],
                                  consumed: inout Set<Int>) -> [MatchedCardRow]? {
        guard let rowKey = template.rowKey else { return [MatchedCardRow(fields: [])] }
        var rows: [MatchedCardRow] = []
        for (index, draft) in fields.enumerated() where draft.key == rowKey {
            consumed.insert(index)
            var rowFields = rowFields(for: template, draft: draft)
            if let raw = draft.rawText,
               fields.filter({ $0.key == rowKey && $0.rawText == raw }).count == 1 {
                for companionKey in labCompanionKeys {
                    let companions = fields.enumerated().filter { $0.element.rawText == raw && $0.element.key == companionKey }
                    if companions.count == 1, let companion = companions.first {
                        let attached = companionFields(for: template, draft: companion.element)
                        if !attached.isEmpty {
                            consumed.insert(companion.offset)
                            rowFields += attached
                        }
                    }
                }
            }
            // 行级伴随字段归行（药品行/费用明细行/诊断行；检验行走 companionFields 的同 rawText 伴随路径）。
            if rowCompanionKinds.contains(template.kind) {
                let triggers = fields.filter { $0.key == rowKey }
                let sameLineTriggers = triggers.filter { $0.sourceLineIndex == draft.sourceLineIndex }
                for (otherIndex, other) in fields.enumerated() where otherIndex != index {
                    guard let key = template.mapping[other.key], template.rowLevelKeys.contains(key),
                          key != rowKey, other.key != rowKey,
                          !consumed.contains(otherIndex),
                          !rowFields.contains(where: { $0.key == key }) else { continue }
                    // 审查修复（误归防线）：单一触发行跨行吸收其余行级字段时，
                    // 该字段键必须页内唯一——双标签页 OCR 漏检一个「通用名称」
                    // 时，另一标签的规格/计量单位行不得并入已识别药品行
                    // （误归他药规格会被「一键确认」升为 C 级事实，BR-003 事实
                    // 纯度受损）。同行伴随（与触发行同 sourceLineIndex）证据
                    // 强，无需唯一性约束——分组显式括号，防 comma-AND 吞并。
                    let uniqueOnPage = fields.filter { template.mapping[$0.key] == key }.count == 1
                    let sameLineEvidence = draft.sourceLineIndex != nil
                        && sameLineTriggers.count == 1 && draft.sourceLineIndex == other.sourceLineIndex
                    guard (uniqueOnPage && triggers.count == 1) || sameLineEvidence else { continue }
                    var copy = other; copy.key = key
                    rowFields.append(copy); consumed.insert(otherIndex)
                }
            }
            let present = Set(rowFields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key))
            let missing = requiredRules.map(\.key).filter { template.rowLevelKeys.contains($0) && !present.contains($0) }
            rows.append(MatchedCardRow(fields: rowFields, missingRequired: missing))
        }
        if rows.isEmpty {
            // 票据页无费用明细行：表头即实体，仍以一空行承载（v25 前 claim_item 单行卡语义不变）。
            guard template.allowsEmptyRows else { return nil }
            rows = [MatchedCardRow(fields: [])]
        }
        return rows
    }

    /// 共享面装配：未归行字段按映射键并入（同键取首个非空、叙事键换行并段；
    /// 处方行级字段无法唯一归行时保留为共享，绝不静默丢数据）+ 文档判定派生的共享键。
    private static func buildShared(for template: CardTemplate, fields: [FieldDraft],
                                    consumed: Set<Int>, documentTypeKey: String?,
                                    ruleKeys: Set<String>) -> [FieldDraft] {
        // 规则表外的映射键（如 encounter.diagnosis_text/advice_text）随卡携带供持久化，但不计覆盖。
        // 审查修复：同键首个为空值的草稿会把后续非空草稿挡在去重之外——
        // 覆盖键永远缺席、覆盖率 <0.5、整卡被拒（数据明明在场）。同键保留
        // 首个非空值，后续非空值替换先前的空值。
        var shared: [FieldDraft] = []
        var sharedKeys: [String: Int] = [:]
        for (index, draft) in fields.enumerated() where !consumed.contains(index) {
            // 处方行级字段（spec/dosage/quantity/frequency/route/days）在无法唯一归行时
            // （多触发行且非同行的页级用法/频次行）保留为共享字段，绝不静默丢数据；
            // medication 维持原语义（误归防线：行级字段只进唯一归属行）。
            guard let mapped = template.mapping[draft.key],
                  (!template.rowLevelKeys.contains(mapped) || template.kind == "prescription") else { continue }
            // Ambiguous/unparsed ranges remain distinct drafts, never guessed row data.
            if mapped != "reference_range" {
                let isEmpty = draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let existingIndex = sharedKeys[mapped] {
                    if isEmpty { continue }
                    let existingValue = shared[existingIndex].value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if existingValue.isEmpty {
                        var copy = draft
                        copy.key = mapped
                        shared[existingIndex] = copy
                    } else if narrativeSharedKeys.contains(mapped), !existingValue.contains(draft.value) {
                        // 多行用法/用量（多药品处方每药一行）与多段病史（现病史+病情说明
                        // 归一同一键；既往史/体格检查/过敏史/就诊总结多行）并入同一共享键——
                        // 旧实现 continue 丢弃后续行，处方只保留第一条医嘱（round10 审查：多条医嘱静默丢行）。
                        var merged = shared[existingIndex]
                        merged.value = existingValue + "\n" + draft.value
                        shared[existingIndex] = merged
                    }
                    continue
                }
                sharedKeys[mapped] = shared.count
            }
            var copy = draft
            copy.key = mapped
            shared.append(copy)
        }
        // 派生共享键（由文档判定派生：就诊/住院 kind、诊断类型默认、病理报告类型——D 级，Picker 可改）；
        // 字段已携带同键（如理解层给出的 report_type）时不覆盖。
        if let documentTypeKey {
            for key in template.derived.sorted() where ruleKeys.contains(key) && !shared.contains(where: { $0.key == key }) {
                guard let value = derivedValue(for: key, documentTypeKey: documentTypeKey) else { continue }
                shared.append(FieldDraft(key: key, value: value, confidence: 0.9, source: .heuristic))
            }
        }
        return shared
    }

    /// 行触发字段 → 行级字段（检验项目「名称 数值」拆分 + 单位 + 派生 metric_key；药名恒等）。
    /// v26（§C.5）：尾段非数值但为定性词/比较符文法（阴性 / <0.5 / + / ≥1:160）时拆为「名称 + 结果原文」——`value` 承载
    /// 打印结果原文，由 `EntityCardProjection.labProjection` 分流进 `lab_result`（不折成数值、不丢行）；其余不猜。
    private static func rowFields(for template: CardTemplate, draft: FieldDraft) -> [FieldDraft] {
        switch template.kind {
        case "metric_sample":
            var (name, number) = UnderstandingCodeResolution.splitReading(draft.value)
            if number == nil, let split = ClinicalFieldLabels.splitQualitativeReading(draft.value) {
                name = split.name; number = split.result
            }
            var out: [FieldDraft] = []
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(FieldDraft(key: "raw_label", value: label, unit: draft.unit, confidence: draft.confidence,
                                  rawText: draft.rawText ?? draft.originalValue, source: draft.source, codeResolution: draft.codeResolution))
            if !label.isEmpty {
                // Suggestions are not approvals. Persistence derives the final key again.
                let key = "lab.\(label)"
                out.append(FieldDraft(key: "metric_key", value: key, confidence: draft.confidence, source: .heuristic))
            }
            if let number, !number.isEmpty {
                out.append(FieldDraft(key: "value", value: number, confidence: draft.confidence,
                                      rawText: draft.rawText ?? draft.originalValue, source: draft.source))
            }
            if let unit = draft.unit, !unit.isEmpty {
                out.append(FieldDraft(key: "unit", value: unit, confidence: draft.confidence,
                                      rawText: draft.rawText ?? draft.originalValue, source: draft.source))
            }
            return out
        default:
            var copy = draft
            copy.key = template.mapping[draft.key] ?? draft.key
            return [copy]
        }
    }

    /// 同 rawText 伴随字段 → 行级字段（参考范围「低-高」拆 ref_low/ref_high；打印标记 abnormal_flag / 参考原文 reference_text /
    /// 方法 method 原样归行——A 级来源事实，不计算不解释）。
    private static func companionFields(for template: CardTemplate, draft: FieldDraft) -> [FieldDraft] {
        guard template.kind == "metric_sample" else { return [] }
        switch draft.key {
        case "reference_range":
            guard let (low, high) = referenceBounds(draft.value) else { return [] }
            return [FieldDraft(key: "ref_low", value: low, confidence: draft.confidence, rawText: draft.rawText ?? draft.originalValue, source: draft.source),
                    FieldDraft(key: "ref_high", value: high, confidence: draft.confidence, rawText: draft.rawText ?? draft.originalValue, source: draft.source)]
        case "abnormal_flag", "reference_text", "method":
            guard let mapped = template.mapping[draft.key], !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            var copy = draft; copy.key = mapped
            return [copy]
        default:
            return []
        }
    }

    /// 「3.5-9.5」「3.5～9.5」→ (低, 高)——实现主体在 `ExtractionPatterns.referenceBounds`
    /// （结构轮 2026-09-15 迁出：该数值文法是多轨共享语法资产）；本方法为兼容转发。
    static func referenceBounds(_ text: String) -> (String, String)? {
        ExtractionPatterns.referenceBounds(text).map { ($0.low, $0.high) }
    }

    /// 文档类型判定 → 就诊类型（v26 §C.1）：住院病案/出院小结 → inpatient；日间手术 → daySurgery；急诊病历 → emergency；
    /// 诊断证明/门诊病历及其余 → outpatient（住院族经 hospitalization 卡建就诊，就诊卡本身不在住院族文档上产出）。
    /// v27：单一事实源 = `DocumentTypeKey.encounterKindHint`（主卡草稿 `ParentCardDraftRules` 同源）；无提示 → outpatient。
    static func encounterKind(for documentTypeKey: String) -> String {
        (DocumentTypeKey(rawValue: documentTypeKey)?.encounterKindHint ?? .outpatient).rawValue
    }
}
