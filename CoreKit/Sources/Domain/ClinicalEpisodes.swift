import Foundation

/// v26 `clinical-episodes`（子项目 D §C.2–§C.5）DDL 镜像值类型：`hospitalization` / `diagnosis` / `exam_report` /
/// `lab_report` / `lab_result`，字段与列同名同序（camelCase）。纯 Domain、仅 Foundation。
///
/// 纪律：
/// - BR-003：OCR 产出为 D 级草稿（`confirmed=false`），用户显式确认保存时由 store 置 1；`health_problem_id` 只由用户
///   「采用为健康问题」后回填，Domain 不自动派生。
/// - BR-004/012：`abnormal_flag` 是报告**打印**的 ↑↓/H/L 原文（A 级来源事实），App 不计算、不解释、不触发提示；
///   DDL 明确排除 `critical_value_flag`。
/// - BR-006/007：出院带药、定性结果、参考范围一律原文 `*Text`，不解析、不换算、不推算。
/// - 编码只存打印文本 `codeText/codeSystemText`（不 FK、不接 F25 码表）。

/// `source` 列 CHECK 枚举（`CHECK(source IN ('ocr','manual'))`）。
public enum FactSource: String, Sendable, Codable, Equatable {
    case ocr, manual
}

/// 父键/时间戳占位：`EntityCardProjection` 产出的意图尚无成员/表头/事务上下文，store 落库时填写。
public enum FactPlaceholder {
    /// 与 `PrescriptionLine.unassignedId` 同一常量（全零 UUID）。
    public static let unassignedId: UUID = PrescriptionLine.unassignedId
    public static let unassignedDate = Date(timeIntervalSince1970: 0)
}

/// §C.2 住院期（1:0..1 `encounter`，`UNIQUE(encounter_id)`）。入院途径/付费方式/离院方式只存打印文本。
public struct Hospitalization: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID
    public var documentFileId: UUID?
    public var hospital: String?
    public var medicalRecordNo: String?
    public var inpatientTimes: Int?
    public var admitAt: Date?
    public var dischargeAt: Date?
    public var actualDays: Int?
    public var admitDept: String?
    public var dischargeDept: String?
    public var ward: String?
    public var bedNo: String?
    public var admitRouteText: String?
    public var paymentTypeText: String?
    public var dischargeWayText: String?
    public var attendingPhysician: String?
    public var admitDiagnosisText: String?
    public var dischargeDiagnosisText: String?
    public var admitCondition: String?
    public var treatmentCourse: String?
    public var dischargeCondition: String?
    public var dischargeOrders: String?
    public var takeHomeDrugsText: String?
    public var totalCost: Double?
    public var summaryDoctor: String?
    public var summaryDate: Date?
    public var source: FactSource
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID, documentFileId: UUID? = nil,
                hospital: String? = nil, medicalRecordNo: String? = nil, inpatientTimes: Int? = nil,
                admitAt: Date? = nil, dischargeAt: Date? = nil, actualDays: Int? = nil,
                admitDept: String? = nil, dischargeDept: String? = nil, ward: String? = nil, bedNo: String? = nil,
                admitRouteText: String? = nil, paymentTypeText: String? = nil, dischargeWayText: String? = nil,
                attendingPhysician: String? = nil, admitDiagnosisText: String? = nil, dischargeDiagnosisText: String? = nil,
                admitCondition: String? = nil, treatmentCourse: String? = nil, dischargeCondition: String? = nil,
                dischargeOrders: String? = nil, takeHomeDrugsText: String? = nil, totalCost: Double? = nil,
                summaryDoctor: String? = nil, summaryDate: Date? = nil,
                source: FactSource, confirmed: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId; self.documentFileId = documentFileId
        self.hospital = hospital; self.medicalRecordNo = medicalRecordNo; self.inpatientTimes = inpatientTimes
        self.admitAt = admitAt; self.dischargeAt = dischargeAt; self.actualDays = actualDays
        self.admitDept = admitDept; self.dischargeDept = dischargeDept; self.ward = ward; self.bedNo = bedNo
        self.admitRouteText = admitRouteText; self.paymentTypeText = paymentTypeText; self.dischargeWayText = dischargeWayText
        self.attendingPhysician = attendingPhysician; self.admitDiagnosisText = admitDiagnosisText
        self.dischargeDiagnosisText = dischargeDiagnosisText; self.admitCondition = admitCondition
        self.treatmentCourse = treatmentCourse; self.dischargeCondition = dischargeCondition
        self.dischargeOrders = dischargeOrders; self.takeHomeDrugsText = takeHomeDrugsText; self.totalCost = totalCost
        self.summaryDoctor = summaryDoctor; self.summaryDate = summaryDate
        self.source = source; self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// §C.3 诊断逐条投影（`encounter.diagnosis_text` 原文块保留，两者不互相派生）。
public struct Diagnosis: Sendable, Equatable, Codable, Identifiable {
    /// `diagnosis_type` CHECK 枚举（SchemaV2 同拼写；展示经 fieldValueDisplay）。
    public static let diagnosisTypes: [String] = ["primary", "secondary", "admission", "discharge", "preop", "postop", "pathology", "certificate", "unspecified"]

    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID?
    public var ordinal: Int
    public var diagnosisType: String
    /// 医生原文，不改写。
    public var name: String
    public var codeText: String?
    public var codeSystemText: String?
    public var diagnosedAt: Date?
    /// 只由用户显式「采用为健康问题」后回填（FR11.4）。
    public var healthProblemId: UUID?
    public var note: String?
    public var sourcePage: Int?
    public var sourceRowId: UUID?
    public var documentFileId: UUID?
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID? = nil, ordinal: Int, diagnosisType: String = "unspecified",
                name: String, codeText: String? = nil, codeSystemText: String? = nil, diagnosedAt: Date? = nil,
                healthProblemId: UUID? = nil, note: String? = nil, sourcePage: Int? = nil, sourceRowId: UUID? = nil,
                documentFileId: UUID? = nil, confirmed: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId; self.ordinal = ordinal
        self.diagnosisType = diagnosisType; self.name = name; self.codeText = codeText; self.codeSystemText = codeSystemText
        self.diagnosedAt = diagnosedAt; self.healthProblemId = healthProblemId; self.note = note
        self.sourcePage = sourcePage; self.sourceRowId = sourceRowId; self.documentFileId = documentFileId
        self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// §C.4 检查/影像/病理报告。`findings/impression` 原文叙事；**无** `critical_value_flag`（BR-004/012）。
public struct ExamReport: Sendable, Equatable, Codable, Identifiable {
    /// `report_type` CHECK 枚举（SchemaV2 同拼写；展示经 fieldValueDisplay）。
    public static let reportTypes: [String] = ["ct", "mri", "xray", "ultrasound", "ecg", "endoscopy", "pathology", "nuclear", "other"]

    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID?
    public var documentFileId: UUID?
    public var reportType: String
    public var hospital: String?
    public var department: String?
    public var reportNo: String?
    public var examPart: String?
    public var examMethod: String?
    public var examAt: Date?
    public var reportedAt: Date?
    public var findings: String?
    public var impression: String?
    public var applyDoctor: String?
    public var reportDoctor: String?
    public var reviewDoctor: String?
    public var source: FactSource
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// v27：报告来源（`ReportSource` raw；nil = v27 前未标注，读侧按外键推断呈现、不回填）与体检枢纽回指。
    public var reportSource: String?
    public var healthExamId: UUID?

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID? = nil, documentFileId: UUID? = nil, reportType: String,
                hospital: String? = nil, department: String? = nil, reportNo: String? = nil, examPart: String? = nil, examMethod: String? = nil,
                examAt: Date? = nil, reportedAt: Date? = nil, findings: String? = nil, impression: String? = nil,
                applyDoctor: String? = nil, reportDoctor: String? = nil, reviewDoctor: String? = nil,
                source: FactSource, confirmed: Bool = false, createdAt: Date, updatedAt: Date,
                reportSource: String? = nil, healthExamId: UUID? = nil) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId; self.documentFileId = documentFileId
        self.reportType = reportType; self.hospital = hospital; self.department = department; self.reportNo = reportNo
        self.examPart = examPart; self.examMethod = examMethod; self.examAt = examAt; self.reportedAt = reportedAt
        self.findings = findings; self.impression = impression
        self.applyDoctor = applyDoctor; self.reportDoctor = reportDoctor; self.reviewDoctor = reviewDoctor
        self.source = source; self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.reportSource = reportSource; self.healthExamId = healthExamId
    }
}

/// §C.5 检验报告表头（同一确认卡的数值行/定性行共用；幂等键 `sourceCardId` UNIQUE，手工录入 nil）。
public struct LabReport: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID?
    public var documentFileId: UUID?
    public var hospital: String?
    public var department: String?
    public var labName: String?
    public var reportNo: String?
    public var specimenType: String?
    public var specimenNo: String?
    public var testClassText: String?
    public var clinicalDiagnosis: String?
    public var collectedAt: Date?
    public var receivedAt: Date?
    public var reportedAt: Date?
    public var sendDoctor: String?
    public var testDoctor: String?
    public var reviewDoctor: String?
    public var sourceCardId: UUID?
    public var source: FactSource
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// v27：报告来源（`ReportSource` raw；nil = v27 前未标注，读侧按外键推断呈现、不回填）与体检枢纽回指。
    public var reportSource: String?
    public var healthExamId: UUID?

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID? = nil, documentFileId: UUID? = nil,
                hospital: String? = nil, department: String? = nil, labName: String? = nil, reportNo: String? = nil,
                specimenType: String? = nil, specimenNo: String? = nil, testClassText: String? = nil, clinicalDiagnosis: String? = nil,
                collectedAt: Date? = nil, receivedAt: Date? = nil, reportedAt: Date? = nil,
                sendDoctor: String? = nil, testDoctor: String? = nil, reviewDoctor: String? = nil, sourceCardId: UUID? = nil,
                source: FactSource, confirmed: Bool = false, createdAt: Date, updatedAt: Date,
                reportSource: String? = nil, healthExamId: UUID? = nil) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId; self.documentFileId = documentFileId
        self.hospital = hospital; self.department = department; self.labName = labName; self.reportNo = reportNo
        self.specimenType = specimenType; self.specimenNo = specimenNo; self.testClassText = testClassText
        self.clinicalDiagnosis = clinicalDiagnosis; self.collectedAt = collectedAt; self.receivedAt = receivedAt; self.reportedAt = reportedAt
        self.sendDoctor = sendDoctor; self.testDoctor = testDoctor; self.reviewDoctor = reviewDoctor; self.sourceCardId = sourceCardId
        self.source = source; self.confirmed = confirmed; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.reportSource = reportSource; self.healthExamId = healthExamId
    }
}

/// §C.5 非数值/半定量检验项目（阴性 / 阳性(+) / <0.5 / 未检出）：原文保存、不猜数值、不进趋势。
/// `comparator` 为原文首部比较符（< ≤ > ≥）的抄录，`resultText` 仍保留完整原文。DDL 无 `confirmed/updated_at` 列。
public struct LabResult: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var patientId: UUID
    public var labReportId: UUID
    public var ordinal: Int
    public var itemName: String
    public var itemCodeText: String?
    public var resultText: String
    public var comparator: String?
    public var unit: String?
    public var referenceText: String?
    public var abnormalFlag: String?
    public var method: String?
    /// 仅用户批准的 F25 建议。
    public var codeConceptId: String?
    public var sourcePage: Int?
    public var sourceRowId: UUID?
    public var createdAt: Date

    public init(id: UUID = UUID(), patientId: UUID, labReportId: UUID, ordinal: Int, itemName: String, itemCodeText: String? = nil,
                resultText: String, comparator: String? = nil, unit: String? = nil, referenceText: String? = nil,
                abnormalFlag: String? = nil, method: String? = nil, codeConceptId: String? = nil,
                sourcePage: Int? = nil, sourceRowId: UUID? = nil, createdAt: Date) {
        self.id = id; self.patientId = patientId; self.labReportId = labReportId; self.ordinal = ordinal
        self.itemName = itemName; self.itemCodeText = itemCodeText; self.resultText = resultText; self.comparator = comparator
        self.unit = unit; self.referenceText = referenceText; self.abnormalFlag = abnormalFlag; self.method = method
        self.codeConceptId = codeConceptId; self.sourcePage = sourcePage; self.sourceRowId = sourceRowId; self.createdAt = createdAt
    }
}
