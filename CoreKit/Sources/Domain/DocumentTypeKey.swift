import Foundation

/// FR5.5 文档类型稳定键（子项目 D §C.10 分类学，原 D3-2 逐字；子项目 J v27 定稿 25 类 + other/custom = 27 case）。
/// Domain 单一枚举：理解层 `OCRGrounding.documentTypes` 由此派生；`document_file.doc_type_key` 存 rawValue；
/// 三语标签留在 App 层 L10n（`docType.<key>`）——本类型只持稳定键、结构化目标卡与旧标签键映射。
/// `attachmentOnly` = 仅附件、不出字段抽取（医嘱单 / 护理记录 / 麻醉记录 / 手术核查 / 知情同意，§A.3 裁决）。
public enum DocumentTypeKey: String, CaseIterable, Sendable, Codable, Hashable {
    case outpatientRecord = "outpatient_record", emergencyRecord = "emergency_record", diagnosisCertificate = "diagnosis_certificate", admissionCertificate = "admission_certificate"
    case labReport = "lab_report", examReport = "exam_report", pathologyReport = "pathology_report", checkupReport = "checkup_report"
    case prescription, medicationGuide = "medication_guide", medicationLabel = "medication_label", invoice, feeDetail = "fee_detail"
    case inpatientRecord = "inpatient_record", dischargeSummary = "discharge_summary", surgeryRecord = "surgery_record", daySurgeryRecord = "day_surgery_record", treatmentRecord = "treatment_record"
    case vaccineRecord = "vaccine_record", allergyRecord = "allergy_record"
    case medicalOrder = "medical_order", nursingRecord = "nursing_record", anesthesiaRecord = "anesthesia_record", surgeryChecklist = "surgery_checklist", consentForm = "consent_form"
    case other, custom

    /// 仅附件：不出字段抽取、无结构化目标卡（§A.3 / §C.11）。
    public var attachmentOnly: Bool {
        [.medicalOrder, .nursingRecord, .anesthesiaRecord, .surgeryChecklist, .consentForm].contains(self)
    }

    /// §C.10「结构化目标卡」列（卡类 = `CardKindRegistry` kind）；首元素 = 该文档的代表卡类（J4 `CardKindIcon.spec(documentTypeKey:)` 取首卡类图标）。
    /// 仅附件 / other / custom / 入院证（不预建住院，§C.2）/ 过敏记录（手工为主，无 OCR 卡类）→ 空。
    public var targetCardKinds: [String] {
        switch self {
        case .outpatientRecord, .emergencyRecord, .diagnosisCertificate: return ["encounter", "diagnosis"]
        case .admissionCertificate: return []
        case .labReport: return ["metric_sample"]
        case .examReport: return ["exam_report"]
        case .pathologyReport: return ["exam_report", "diagnosis"]
        // v27：体检 = 第三枢纽——首页卡 + 检验/检查子报告 + 结论行
        case .checkupReport: return ["health_exam", "metric_sample", "exam_report", "clinical_conclusion"]
        case .prescription, .medicationGuide: return ["prescription"]
        case .medicationLabel: return ["medication"]
        case .invoice, .feeDetail: return ["claim_item"]
        case .inpatientRecord: return ["hospitalization", "diagnosis"]
        case .dischargeSummary: return ["hospitalization", "diagnosis", "surgery"]
        case .surgeryRecord: return ["surgery"]
        case .daySurgeryRecord: return ["hospitalization", "surgery"]
        case .treatmentRecord: return ["treatment_record"]
        case .vaccineRecord: return ["immunization"]
        case .allergyRecord: return []
        case .medicalOrder, .nursingRecord, .anesthesiaRecord, .surgeryChecklist, .consentForm: return []
        case .other, .custom: return []
        }
    }

    /// 文档类型 → 就诊场景提示（v26 §C.1 `encounter.kind`）：住院病案 / 出院小结 → inpatient；日间手术 → daySurgery；急诊病历 → emergency；
    /// 体检报告 → checkup；门诊病历 / 诊断证明 → outpatient；其余（处方 / 检验 / 票据…）无场景证据 → nil（不猜）。
    /// `CardTemplateMatcher.encounterKind(for:)`（就诊/住院卡派生 `kind`）与 `ParentCardDraftRules`（主卡草稿 `kind`）同源于此。
    public var encounterKindHint: EncounterKind? {
        switch self {
        case .inpatientRecord, .dischargeSummary: return .inpatient
        case .daySurgeryRecord: return .daySurgery
        case .emergencyRecord: return .emergency
        case .checkupReport: return .checkup
        case .outpatientRecord, .diagnosisCertificate: return .outpatient
        default: return nil
        }
    }

    /// 现行 `docTypeLabel.*` 15 标签键 → 稳定键（§C.10 括注）；App 首启回填按标签反查三语后经此映射，未命中 → `custom`。
    public static let legacyLabelKeys: [String: DocumentTypeKey] = [
        "outpatient": .outpatientRecord, "inpatient": .inpatientRecord, "labReport": .labReport, "imageReport": .examReport,
        "prescription": .prescription, "payment": .invoice, "dischargeSummary": .dischargeSummary, "diagnosisProof": .diagnosisCertificate,
        "vaccineRecord": .vaccineRecord, "checkupReport": .checkupReport, "pathologyReport": .pathologyReport, "surgeryRecord": .surgeryRecord,
        "allergyRecord": .allergyRecord, "other": .other, "custom": .custom,
    ]

    /// 旧标签键或已是稳定键者 → 稳定键；未知 → nil。
    public init?(legacyLabelKey key: String) {
        if let mapped = Self.legacyLabelKeys[key] { self = mapped; return }
        guard let stable = Self(rawValue: key) else { return nil }
        self = stable
    }
}
