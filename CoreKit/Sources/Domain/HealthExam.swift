import Foundation

/// v27 `card-hierarchy`（子项目 J · round1 §E.1 / 融合方案 §五–§七 / 原 D3 §C.8–§C.9）DDL 镜像值类型：
/// `health_exam` / `clinical_conclusion` / `surgery` / `treatment_record`，字段与列同名同序（camelCase）；
/// `v_clinical_report` 只读视图的读模型 `ClinicalReportSummary`；`appointment.purpose` 与 `reminder.source_*` 值类型。
/// 纯 Domain、仅 Foundation；风格同 `ClinicalEpisodes.swift`。
///
/// 纪律：
/// - BR-003：OCR 产出为 D 级草稿（`confirmed=false`），用户显式确认保存时由 store 置 1；主卡草稿同样 D 级。
/// - BR-004/012：`ClinicalConclusion.severityText` 只存**打印文本**（正常/关注/异常/需复查…），不编码、不排序、不着色；
///   DDL 明确不加 `critical_flag`。
/// - BR-006/007：体检一般检查 `*Text` 原文保留；手术编码/级别、植入物、出血量、治疗药物一律原文，不拆行、不换算。

/// §E.1 体检（第三枢纽）。一般检查列为打印原文；可严格解析且 `MetricType` 有键者由 `EntityCardProjection.healthExamIntent`
/// 另投影 `metric_sample`（身高 / BMI / 腰围 / 视力无键——不投影、不造键）。
public struct HealthExam: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var patientId: UUID
    public var documentFileId: UUID?
    public var orgName: String?
    public var examNo: String?
    public var packageName: String?
    public var examDate: Date?
    public var totalDoctor: String?
    public var reportDate: Date?
    public var heightText: String?
    public var weightText: String?
    public var bmiText: String?
    public var systolicText: String?
    public var diastolicText: String?
    public var pulseText: String?
    public var waistText: String?
    public var visionLeftText: String?
    public var visionRightText: String?
    public var overallConclusion: String?
    public var healthGuidance: String?
    public var source: FactSource
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), patientId: UUID, documentFileId: UUID? = nil,
                orgName: String? = nil, examNo: String? = nil, packageName: String? = nil,
                examDate: Date? = nil, totalDoctor: String? = nil, reportDate: Date? = nil,
                heightText: String? = nil, weightText: String? = nil, bmiText: String? = nil,
                systolicText: String? = nil, diastolicText: String? = nil, pulseText: String? = nil, waistText: String? = nil,
                visionLeftText: String? = nil, visionRightText: String? = nil,
                overallConclusion: String? = nil, healthGuidance: String? = nil,
                source: FactSource, confirmed: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.patientId = patientId; self.documentFileId = documentFileId
        self.orgName = orgName; self.examNo = examNo; self.packageName = packageName
        self.examDate = examDate; self.totalDoctor = totalDoctor; self.reportDate = reportDate
        self.heightText = heightText; self.weightText = weightText; self.bmiText = bmiText
        self.systolicText = systolicText; self.diastolicText = diastolicText; self.pulseText = pulseText; self.waistText = waistText
        self.visionLeftText = visionLeftText; self.visionRightText = visionRightText
        self.overallConclusion = overallConclusion; self.healthGuidance = healthGuidance
        self.source = source; self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// §E.1 / 融合方案 §六-6.3 统一结论表：检验结论 / 检查结论 / 体检总检 / 异常发现 / 健康建议 / 复查建议 / 就医建议。
/// 三外键恰一非空（DDL CHECK，`hasExactlyOneParent`）；`content` 原文；`severityText` 只存打印文本（BR-004/012）。
public struct ClinicalConclusion: Sendable, Equatable, Codable, Identifiable {
    /// `conclusion_type` CHECK 枚举（SchemaV2 同拼写；展示经 fieldValueDisplay）。
    public static let conclusionTypes: [String] = ["lab", "exam", "health_exam_summary", "abnormal_finding", "health_advice", "recheck_advice", "visit_advice"]

    public var id: UUID
    public var patientId: UUID
    public var labReportId: UUID?
    public var examReportId: UUID?
    public var healthExamId: UUID?
    public var conclusionType: String
    public var content: String
    /// 打印原文（正常 / 关注 / 异常 / 需复查…），不编码、不排序、不着色（BR-004/012）。
    public var severityText: String?
    public var ordinal: Int
    public var sourcePage: Int?
    public var sourceRowId: UUID?
    public var createdAt: Date

    public init(id: UUID = UUID(), patientId: UUID, labReportId: UUID? = nil, examReportId: UUID? = nil, healthExamId: UUID? = nil,
                conclusionType: String, content: String, severityText: String? = nil, ordinal: Int,
                sourcePage: Int? = nil, sourceRowId: UUID? = nil, createdAt: Date) {
        self.id = id; self.patientId = patientId
        self.labReportId = labReportId; self.examReportId = examReportId; self.healthExamId = healthExamId
        self.conclusionType = conclusionType; self.content = content; self.severityText = severityText
        self.ordinal = ordinal; self.sourcePage = sourcePage; self.sourceRowId = sourceRowId; self.createdAt = createdAt
    }

    /// DDL `CHECK((lab_report_id IS NOT NULL) + (exam_report_id IS NOT NULL) + (health_exam_id IS NOT NULL) = 1)` 的值侧镜像。
    public var hasExactlyOneParent: Bool {
        [labReportId, examReportId, healthExamId].compactMap { $0 }.count == 1
    }

    /// 结论行类型的 D 级默认（同 v26 `report_type` 关键词派生纪律，仅作 Picker 默认；行 `conclusion_type` 字段覆盖）：
    /// 含「复查」→ recheck_advice；含「就医」「就诊」「专科」→ visit_advice；含「建议」「指导」→ health_advice；
    /// 含「异常」「偏高」「偏低」「阳性」→ abnormal_finding；其余 health_exam_summary。词表匹配、非医学解读。
    public static func conclusionType(forContent content: String) -> String {
        if content.contains("复查") || content.contains("復查") { return "recheck_advice" }
        if ["就医", "就醫", "就诊", "就診", "专科", "專科"].contains(where: content.contains) { return "visit_advice" }
        if ["建议", "建議", "指导", "指導"].contains(where: content.contains) { return "health_advice" }
        if ["异常", "異常", "偏高", "偏低", "阳性", "陽性"].contains(where: content.contains) { return "abnormal_finding" }
        return "health_exam_summary"
    }
}

/// §C.8 手术记录。编码 / 级别只存打印文本；植入物原文（MRI 禁忌 / 复查所需）；排除麻醉记录 / 安全核查 / 清点字段（仅附件）。
public struct Surgery: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID?
    public var documentFileId: UUID?
    public var hospital: String?
    public var department: String?
    public var surgeryAt: Date?
    public var endedAt: Date?
    public var surgeryName: String
    public var surgeryCodeText: String?
    public var surgeryLevelText: String?
    public var surgeon: String?
    public var assistants: String?
    public var anesthesiologist: String?
    public var anesthesiaMethod: String?
    public var preopDiagnosisText: String?
    public var postopDiagnosisText: String?
    public var procedureCourse: String?
    public var intraopFindings: String?
    public var implantsText: String?
    public var specimenText: String?
    public var bloodLossText: String?
    public var transfusionText: String?
    public var drainageText: String?
    public var postopOrders: String?
    public var complicationsText: String?
    public var source: FactSource
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID? = nil, documentFileId: UUID? = nil,
                hospital: String? = nil, department: String? = nil, surgeryAt: Date? = nil, endedAt: Date? = nil,
                surgeryName: String, surgeryCodeText: String? = nil, surgeryLevelText: String? = nil,
                surgeon: String? = nil, assistants: String? = nil, anesthesiologist: String? = nil, anesthesiaMethod: String? = nil,
                preopDiagnosisText: String? = nil, postopDiagnosisText: String? = nil,
                procedureCourse: String? = nil, intraopFindings: String? = nil,
                implantsText: String? = nil, specimenText: String? = nil, bloodLossText: String? = nil,
                transfusionText: String? = nil, drainageText: String? = nil,
                postopOrders: String? = nil, complicationsText: String? = nil,
                source: FactSource, confirmed: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId; self.documentFileId = documentFileId
        self.hospital = hospital; self.department = department; self.surgeryAt = surgeryAt; self.endedAt = endedAt
        self.surgeryName = surgeryName; self.surgeryCodeText = surgeryCodeText; self.surgeryLevelText = surgeryLevelText
        self.surgeon = surgeon; self.assistants = assistants; self.anesthesiologist = anesthesiologist; self.anesthesiaMethod = anesthesiaMethod
        self.preopDiagnosisText = preopDiagnosisText; self.postopDiagnosisText = postopDiagnosisText
        self.procedureCourse = procedureCourse; self.intraopFindings = intraopFindings
        self.implantsText = implantsText; self.specimenText = specimenText; self.bloodLossText = bloodLossText
        self.transfusionText = transfusionText; self.drainageText = drainageText
        self.postopOrders = postopOrders; self.complicationsText = complicationsText
        self.source = source; self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// §C.9 门诊治疗 / 输液 / 注射 / 理疗记录。`drugsText` 原文不拆行、不进 `prescription_line`/`medication`（避免双计）；
/// `allergyEventId` 只由用户显式关联 F23 事件。
public struct TreatmentRecord: Sendable, Equatable, Codable, Identifiable {
    /// `treatment_type` CHECK 枚举（SchemaV2 同拼写；展示经 fieldValueDisplay）。
    public static let treatmentTypes: [String] = ["infusion", "injection", "physiotherapy", "dressing", "other"]

    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID?
    public var documentFileId: UUID?
    public var treatmentType: String
    public var treatedAt: Date?
    public var hospital: String?
    public var department: String?
    public var doctor: String?
    public var executor: String?
    public var diagnosisText: String?
    public var content: String?
    public var drugsText: String?
    public var sessionText: String?
    public var adverseReactionText: String?
    public var allergyEventId: UUID?
    public var resultText: String?
    public var note: String?
    public var source: FactSource
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID? = nil, documentFileId: UUID? = nil,
                treatmentType: String, treatedAt: Date? = nil, hospital: String? = nil, department: String? = nil,
                doctor: String? = nil, executor: String? = nil, diagnosisText: String? = nil, content: String? = nil,
                drugsText: String? = nil, sessionText: String? = nil, adverseReactionText: String? = nil,
                allergyEventId: UUID? = nil, resultText: String? = nil, note: String? = nil,
                source: FactSource, confirmed: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId; self.documentFileId = documentFileId
        self.treatmentType = treatmentType; self.treatedAt = treatedAt; self.hospital = hospital; self.department = department
        self.doctor = doctor; self.executor = executor; self.diagnosisText = diagnosisText; self.content = content
        self.drugsText = drugsText; self.sessionText = sessionText; self.adverseReactionText = adverseReactionText
        self.allergyEventId = allergyEventId; self.resultText = resultText; self.note = note
        self.source = source; self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// `v_clinical_report.report_type` 字面量（检验表头 / 检查报告 / 体检）。
public enum ReportType: String, Sendable, Codable, Equatable, CaseIterable {
    case lab, exam, healthExam = "health_exam"
}

/// `lab_report.report_source` / `exam_report.report_source` CHECK 枚举（融合方案 §三-3）；NULL = v27 前未标注。
public enum ReportSource: String, Sendable, Codable, Equatable, CaseIterable {
    case outpatient, emergency, inpatient, healthExam = "health_exam"
}

/// `v_clinical_report` 只读视图的读模型（融合方案 §七-7.2 方案 A：视图兼容优于物理大表；不入备份）。
/// 列：report_id / patient_id / report_type / report_source / report_date / org_name / report_no / encounter_id / health_exam_id / document_file_id / confirmed。
public struct ClinicalReportSummary: Sendable, Equatable, Codable, Identifiable {
    public var reportId: UUID
    public var patientId: UUID
    public var reportType: ReportType
    /// 视图已按外键推断（体检子报告 → health_exam）；仍可为 nil（v27 前的孤立报告）。
    public var reportSource: ReportSource?
    public var reportDate: Date?
    public var orgName: String?
    public var reportNo: String?
    public var encounterId: UUID?
    public var healthExamId: UUID?
    public var documentFileId: UUID?
    public var confirmed: Bool
    public var id: UUID { reportId }

    public init(reportId: UUID, patientId: UUID, reportType: ReportType, reportSource: ReportSource?, reportDate: Date?,
                orgName: String?, reportNo: String?, encounterId: UUID?, healthExamId: UUID?, documentFileId: UUID?, confirmed: Bool) {
        self.reportId = reportId; self.patientId = patientId; self.reportType = reportType; self.reportSource = reportSource
        self.reportDate = reportDate; self.orgName = orgName; self.reportNo = reportNo
        self.encounterId = encounterId; self.healthExamId = healthExamId; self.documentFileId = documentFileId; self.confirmed = confirmed
    }
}

/// FR10.7 `appointment.purpose` CHECK 枚举（canonical raw；展示经 fieldValueDisplay）。
public enum AppointmentPurpose: String, Sendable, Codable, Equatable, CaseIterable {
    case visit, followUp, exam, healthExam
}

/// FR8.10/10.2 `reminder.source_table/source_id` 多态引用（无 FK；白名单由 store 校验——本类型只持白名单与判定）。
public struct ReminderSource: Sendable, Equatable, Codable, Hashable {
    /// 允许回指的来源表（round1 §E.1）；表名来自本常量方可拼入 SQL。
    public static let allowedTables: Set<String> = ["encounter", "appointment", "health_exam"]

    public var table: String
    public var id: UUID

    public init(table: String, id: UUID) { self.table = table; self.id = id }

    /// 白名单校验构造（未登记表 → nil）；store 亦须复核实体存在且同成员。
    public init?(validating table: String, id: UUID) {
        guard Self.allowedTables.contains(table) else { return nil }
        self.init(table: table, id: id)
    }

    public var isAllowed: Bool { Self.allowedTables.contains(table) }

    /// 来源为主卡时的枢纽（预约不是枢纽 → nil；预约来源的提醒经 `appointment.encounter_id` 到达就诊）。
    public var hub: RecordHub? {
        switch table {
        case "encounter": return .encounter
        case "health_exam": return .healthExam
        default: return nil
        }
    }
}
