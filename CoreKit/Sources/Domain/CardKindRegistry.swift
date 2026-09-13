import Foundation

/// FR6.9 卡类注册表条目（子项目 D · discussions/2026-09-13-hospital-card-schema-round1 §C.13）。
/// 一个 `card_kind` = 若干事实表（首元素为表头表，其余为行表）+ 共享/行级的必填与可选键集。
/// `sharedAllowed/rowAllowed` 是 `EntityCardProjection.invalidFields` 的放行面；可选键是
/// 确认页「添加字段」目录的来源（`optionalCatalog`）。必填键 = 建卡最小集（与
/// `CompletenessEvaluator.rules` 的 required 同源），可选键**不进**规则表——目录与门槛分离，
/// 新增可选字段不稀释 FR6.9 双阈值分母。
public struct CardKindEntry: Sendable, Equatable {
    public let kind: String
    /// 事实表；首元素 = 表头表（回执 `entity_table` 默认值），其余 = 行表（处方行/费用行）。
    public let entityTables: [String]
    public let sharedRequired: Set<String>
    public let sharedOptional: Set<String>
    public let rowRequired: Set<String>
    public let rowOptional: Set<String>
    /// 共享面日期键（解析失败即不落库，不猜日期）；nil = 无日期最小集（medication）。
    public let dateKey: String?
    /// 仅这些文档类型判定下参与匹配（nil = 不限）；与 `CardTemplate.requiresDocumentType` 同源。
    public let requiresDocumentType: Set<String>?
    /// 行触发键缺席时仍以一空行代表「表头即实体」（票据页无费用明细行）；空行不受 `rowRequired` 约束。
    public let allowsEmptyRows: Bool

    public var sharedAllowed: Set<String> { sharedRequired.union(sharedOptional) }
    public var rowAllowed: Set<String> { rowRequired.union(rowOptional) }
    /// 表头表（`OCRCardStore.factTable(for:)` 口径）。
    public var headerTable: String { entityTables.first ?? kind }

    public init(kind: String, entityTables: [String],
                sharedRequired: Set<String>, sharedOptional: Set<String>,
                rowRequired: Set<String>, rowOptional: Set<String>,
                dateKey: String?, requiresDocumentType: Set<String>? = nil, allowsEmptyRows: Bool = false) {
        self.kind = kind; self.entityTables = entityTables
        self.sharedRequired = sharedRequired; self.sharedOptional = sharedOptional
        self.rowRequired = rowRequired; self.rowOptional = rowOptional
        self.dateKey = dateKey; self.requiresDocumentType = requiresDocumentType
        self.allowsEmptyRows = allowsEmptyRows
    }
}

/// 卡类单一事实源（D1：六既有卡类；D2/D3 追加住院/诊断/检查/手术/治疗）。
/// 键名 = 模板键（`CardTemplate.mapping` 的值），与 `ocr_card_commit.entity_table` CHECK 枚举同拼写。
public enum CardKindRegistry {
    /// 处方行级键：`prescription_line` 列的模板键投影。剂量/数量/频次/疗程为原文（+单位），不解析不换算（BR-006/007）。
    private static let prescriptionRowOptional: Set<String> = [
        "spec", "dosage", "quantity", "frequency", "route", "days", "unit", "note",
        "drug_form", "generic_name", "brand_name", "start_date", "end_date", "as_needed", "medication_notes",
        "insurance_code", "item_code", "unit_price", "line_amount",
    ]

    /// v26 检验表头共享键（§C.5 `lab_report` 列的模板键投影；卡类仍是 metric_sample，回执 entity_table 分流）。
    private static let labHeaderOptional: Set<String> = [
        "hospital", "department", "lab_name", "report_no", "specimen_type", "specimen_no", "test_class", "clinical_diagnosis",
        "collected_at", "received_at", "reported_at", "send_doctor", "test_doctor", "review_doctor",
    ]
    /// v26 住院期可选键（§C.2 `hospitalization` 列；`*_text` 列的模板键去后缀；叙事列原文保存）。
    private static let hospitalizationOptional: Set<String> = [
        "admit_at", "discharge_at", "medical_record_no", "inpatient_times", "actual_days",
        "admit_dept", "discharge_dept", "ward", "bed_no", "admit_route", "payment_type", "discharge_way",
        "attending_physician", "admit_diagnosis", "discharge_diagnosis",
        "admit_condition", "treatment_course", "discharge_condition", "discharge_orders", "take_home_drugs",
        "total_cost", "summary_doctor", "summary_date",
    ]

    public static let entries: [CardKindEntry] = [
        // 检验卡（§C.5）：行最小集 raw_label + value（value = 打印结果原文，数值或定性）；unit 可选——
        // 「value 严格 Double 且有 unit → metric_sample，否则原文 → lab_result」由 EntityCardProjection.labProjection 分流。
        // entityTables：表头表仍为 metric_sample（历史回执语义不变），lab_report/lab_result 为 v26 分流目标。
        CardKindEntry(kind: "metric_sample", entityTables: ["metric_sample", "lab_report", "lab_result"],
                      sharedRequired: ["measured_at"], sharedOptional: labHeaderOptional,
                      rowRequired: ["raw_label", "value"],
                      rowOptional: ["unit", "ref_low", "ref_high", "metric_key", "reference_text", "abnormal_flag", "method"],
                      dateKey: "measured_at"),
        CardKindEntry(kind: "encounter", entityTables: ["encounter"],
                      sharedRequired: ["date", "kind"],
                      sharedOptional: ["hospital", "department", "doctor", "chief_complaint", "diagnosis_text", "advice_text",
                                       "present_illness", "illness_summary", "visit_summary",
                                       "past_history", "physical_exam", "allergy_history"],
                      rowRequired: [], rowOptional: [],
                      dateKey: "date", requiresDocumentType: ["outpatient_record", "diagnosis_certificate", "emergency_record"]),
        // v26 住院期（§C.2）：kind（inpatient|daySurgery）由文档类型键派生，store 据此新建/补空 encounter + hospitalization 一事务；
        // admit_at ?? discharge_at 二择一由 invalidFields 裁定（dateKey nil）。入院证（admission_certificate）不预建。
        CardKindEntry(kind: "hospitalization", entityTables: ["hospitalization", "encounter"],
                      sharedRequired: ["hospital", "kind"], sharedOptional: hospitalizationOptional,
                      rowRequired: [], rowOptional: [],
                      dateKey: nil, requiresDocumentType: ["inpatient_record", "discharge_summary", "day_surgery_record"]),
        // v26 诊断（§C.3）：每条一行；diagnosis_type 共享面 = 文档键派生默认（Picker 可改），行面可逐行覆盖（主/次诊断）；
        // 日期可继承同页就诊卡（dateKey nil）；仅病历类文档（§C.10「结构化目标卡」含 diagnosis 的类型）。
        CardKindEntry(kind: "diagnosis", entityTables: ["diagnosis"],
                      sharedRequired: [], sharedOptional: ["diagnosed_at", "hospital", "diagnosis_type"],
                      rowRequired: ["name"], rowOptional: ["code_text", "code_system", "diagnosis_type", "note"],
                      dateKey: nil,
                      requiresDocumentType: ["outpatient_record", "emergency_record", "diagnosis_certificate",
                                             "inpatient_record", "discharge_summary", "day_surgery_record", "pathology_report"]),
        // v26 检查报告（§C.4）：report_type canonical raw（CHECK 枚举）；exam_at ?? reported_at 与 impression ?? findings 由 invalidFields 裁定。
        CardKindEntry(kind: "exam_report", entityTables: ["exam_report"],
                      sharedRequired: ["report_type"],
                      sharedOptional: ["hospital", "department", "report_no", "exam_part", "exam_method", "exam_at", "reported_at",
                                       "findings", "impression", "apply_doctor", "report_doctor", "review_doctor"],
                      rowRequired: [], rowOptional: [],
                      dateKey: nil, requiresDocumentType: ["exam_report", "pathology_report", "checkup_report"]),
        // 行级键在无法唯一归行时（多药品页级用法/频次行）由匹配器保留为共享字段——共享面一并放行，
        // 防合法卡被 invalidFields 整体拒收；表头目录（optionalCatalog rowLevel=false）会剔除行级键。
        CardKindEntry(kind: "prescription", entityTables: ["prescription", "prescription_line"],
                      sharedRequired: ["prescribed_at"],
                      sharedOptional: Set(["hospital", "doctor", "advice_text", "department", "prescription_no", "prescription_type",
                                           "fee_type", "clinical_diagnosis", "pharmacist_names", "total_amount"]).union(prescriptionRowOptional),
                      rowRequired: ["drug_name"], rowOptional: prescriptionRowOptional,
                      dateKey: "prescribed_at"),
        CardKindEntry(kind: "claim_item", entityTables: ["claim_item", "claim_line"],
                      sharedRequired: ["amount", "currency", "date", "item_type"],
                      sharedOptional: ["merchant", "summary", "reimbursed_amount", "out_of_pocket",
                                       "personal_account_amount", "invoice_no", "insurance_type"],
                      rowRequired: ["item_name"],
                      rowOptional: ["item_amount", "unit_price", "item_quantity", "item_spec", "fee_category", "item_code",
                                    "insurance_code", "executing_dept", "self_pay_ratio", "fee_at"],
                      dateKey: "date", allowsEmptyRows: true),
        CardKindEntry(kind: "medication", entityTables: ["medication"],
                      sharedRequired: [], sharedOptional: [],
                      rowRequired: ["generic_name", "unit_kind"], rowOptional: ["brand_name", "spec", "dosage", "frequency", "route"],
                      dateKey: nil),
        CardKindEntry(kind: "immunization", entityTables: ["immunization"],
                      sharedRequired: ["vaccine_name", "dose_number", "administered_at", "provider"], sharedOptional: ["lot_number"],
                      rowRequired: [], rowOptional: [],
                      dateKey: "administered_at"),
    ]

    public static func entry(for kind: String) -> CardKindEntry? {
        entries.first { $0.kind == kind }
    }

    /// 「添加字段」目录 = 可选键 − 卡内已有键（解 O5；与 `CompletenessEvaluator.rules` 分母无关）。
    /// 表头面剔除行级键（行级键的补录入口在行内）；稳定排序供 UI 直接呈现。
    public static func optionalCatalog(kind: String, present: Set<String>, rowLevel: Bool) -> [String] {
        guard let entry = entry(for: kind) else { return [] }
        let candidates = rowLevel ? entry.rowOptional : entry.sharedOptional.subtracting(entry.rowAllowed)
        return candidates.subtracting(present).sorted()
    }
}
