import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// 子项目 J · J2（原 D3-2 逐字 + round1 §C.10）：FR5.5 文档类型稳定键分类学（25 类 + other/custom = 27 case）、
/// 仅附件键无结构化目标卡、理解层 documentTypes 由枚举派生、旧 15 标签键 → 稳定键映射（App 首启回填读侧）、
/// 就诊类型派生提示；§5.45 路由 `healthExamDetail`。纯 Domain，Linux 可跑。
@Suite("FR5.5 DocumentTypeKey 分类学 + 体检详情路由")
struct DocumentTypeKeyTests {
    /// 原名：二十七键rawValue唯一且全snake_case
    @Test func twentySevenKeysHaveUniqueSnakeCaseRawValues() throws {
        let raws = DocumentTypeKey.allCases.map(\.rawValue)
        #expect(raws.count == 27 && Set(raws).count == 27)
        for raw in raws {
            #expect(raw.range(of: #"^[a-z]+(?:_[a-z]+)*$"#, options: .regularExpression) != nil, "\(raw)")
        }
        #expect(DocumentTypeKey(rawValue: "checkup_report") == .checkupReport && DocumentTypeKey.custom.rawValue == "custom")
        #expect(try JSONDecoder().decode(DocumentTypeKey.self, from: Data(#""day_surgery_record""#.utf8)) == .daySurgeryRecord)
    }

    /// 原名：五仅附件键targetCardKinds为空_其余结构化目标卡皆为注册卡类
    @Test func fiveAttachmentOnlyKeysHaveEmptyTargetCardKindsRestAreRegistered() {
        let attachmentOnly = DocumentTypeKey.allCases.filter(\.attachmentOnly)
        #expect(Set(attachmentOnly) == [.medicalOrder, .nursingRecord, .anesthesiaRecord, .surgeryChecklist, .consentForm])
        #expect(attachmentOnly.allSatisfy { $0.targetCardKinds.isEmpty })
        #expect(DocumentTypeKey.other.targetCardKinds.isEmpty && DocumentTypeKey.custom.targetCardKinds.isEmpty)
        let registered = Set(CardKindRegistry.entries.map(\.kind))
        for key in DocumentTypeKey.allCases {
            #expect(Set(key.targetCardKinds).isSubset(of: registered), "\(key.rawValue): \(key.targetCardKinds)")
        }
        #expect(DocumentTypeKey.checkupReport.targetCardKinds.first == "health_exam", "体检文档首卡类 = 体检枢纽（J4 spec(documentTypeKey:) 取首卡类图标）")
        #expect(DocumentTypeKey.dischargeSummary.targetCardKinds.contains("surgery") && DocumentTypeKey.daySurgeryRecord.targetCardKinds.contains("surgery"))
        #expect(DocumentTypeKey.emergencyRecord.targetCardKinds == ["encounter", "diagnosis"] && DocumentTypeKey.treatmentRecord.targetCardKinds == ["treatment_record"])
        #expect(DocumentTypeKey.admissionCertificate.targetCardKinds.isEmpty, "入院证不预建住院（§C.2）")
    }

    /// 原名：理解层documentTypes由枚举派生且包含既有七键
    @Test func understandingDocumentTypesDerivedFromEnumIncludeSevenExistingKeys() {
        #expect(OCRGrounding.documentTypes.isSuperset(of: ["prescription", "lab_report", "outpatient_record", "diagnosis_certificate", "vaccine_record", "invoice", "medication_label"]))
        #expect(OCRGrounding.documentTypes == Set(DocumentTypeKey.allCases.map(\.rawValue)))
    }

    /// 原名：旧十五标签键映射稳定键_未知为nil
    @Test func legacyFifteenLabelKeysMapToStableKeysUnknownIsNil() {
        let legacy = ["outpatient": "outpatient_record", "inpatient": "inpatient_record", "labReport": "lab_report", "imageReport": "exam_report",
                      "prescription": "prescription", "payment": "invoice", "dischargeSummary": "discharge_summary", "diagnosisProof": "diagnosis_certificate",
                      "vaccineRecord": "vaccine_record", "checkupReport": "checkup_report", "pathologyReport": "pathology_report", "surgeryRecord": "surgery_record",
                      "allergyRecord": "allergy_record", "other": "other", "custom": "custom"]
        #expect(DocumentTypeKey.legacyLabelKeys.count == 15)
        for (label, raw) in legacy {
            #expect(DocumentTypeKey(legacyLabelKey: label)?.rawValue == raw, "\(label)")
        }
        #expect(DocumentTypeKey(legacyLabelKey: "unknown") == nil)
        #expect(DocumentTypeKey(legacyLabelKey: "exam_report") == .examReport, "已是稳定键者原样接受（幂等回填）")
    }

    /// 原名：就诊类型派生提示_与模板派生同源
    @Test func encounterKindHintSharesSourceWithTemplateDerivation() {
        #expect(DocumentTypeKey.emergencyRecord.encounterKindHint == .emergency)
        #expect(DocumentTypeKey.inpatientRecord.encounterKindHint == .inpatient && DocumentTypeKey.dischargeSummary.encounterKindHint == .inpatient)
        #expect(DocumentTypeKey.daySurgeryRecord.encounterKindHint == .daySurgery)
        #expect(DocumentTypeKey.checkupReport.encounterKindHint == .checkup)
        #expect(DocumentTypeKey.outpatientRecord.encounterKindHint == .outpatient && DocumentTypeKey.diagnosisCertificate.encounterKindHint == .outpatient)
        #expect(DocumentTypeKey.prescription.encounterKindHint == nil && DocumentTypeKey.labReport.encounterKindHint == nil, "无就诊场景证据 → 不猜")
        #expect(CardTemplateMatcher.encounterKind(for: "emergency_record") == "emergency" && CardTemplateMatcher.encounterKind(for: "prescription") == "outpatient")
    }

    /// 原名：体检详情路由可编解码且归档案Tab
    @Test func healthExamDetailRouteCodableAndTabbedUnderRecords() throws {
        let route = AppRoute.healthExamDetail(patientId: UUID(), id: UUID())
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(AppRoute.self, from: data) == route)
        #expect(MainModuleID.tab(of: route) == .records)
        #expect(route != AppRoute.healthExamDetail(patientId: UUID(), id: UUID()))
    }
}
