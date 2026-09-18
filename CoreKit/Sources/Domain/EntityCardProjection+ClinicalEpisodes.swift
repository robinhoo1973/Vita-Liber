import Foundation

/// v26 `clinical-episodes`（子项目 D §C.2–§C.5 / D2-2）：住院 / 诊断 / 检查卡 → 持久化意图；检验卡数值/定性分流。
/// 纯 Domain、零 IO；意图内实体的 `patientId/encounterId/labReportId` 为 `FactPlaceholder.unassignedId`、
/// 时间戳为 `FactPlaceholder.unassignedDate`，由 store 落库时填写；`id = rowId`（与 v25 回填 `id = row_id` 同纪律）。
extension EntityCardProjection {
    // MARK: - 意图类型

    /// 检验报告表头（§C.5 `lab_report`）：同一确认卡的数值行与定性行共用一条，store 以 `source_card_id = card.id` 幂等建/补。
    /// `reportedAt` = `reported_at` ?? `measured_at`（与 v26 SQL 回填同义）；`collectedAt` 仅取显式采集时间。
    public struct LabReportIntent: Sendable, Equatable {
        public var hospital: String?
        public var department: String?
        public var labName: String?
        public var reportNo: String?
        public var specimenType: String?
        public var specimenNo: String?
        public var testClassText: String?
        public var clinicalDiagnosis: String?
        public var sendDoctor: String?
        public var testDoctor: String?
        public var reviewDoctor: String?
        public var collectedAt: Date?
        public var receivedAt: Date?
        public var reportedAt: Date?
        public init(hospital: String? = nil, department: String? = nil, labName: String? = nil, reportNo: String? = nil,
                    specimenType: String? = nil, specimenNo: String? = nil, testClassText: String? = nil, clinicalDiagnosis: String? = nil,
                    sendDoctor: String? = nil, testDoctor: String? = nil, reviewDoctor: String? = nil,
                    collectedAt: Date? = nil, receivedAt: Date? = nil, reportedAt: Date? = nil) {
            self.hospital = hospital; self.department = department; self.labName = labName; self.reportNo = reportNo
            self.specimenType = specimenType; self.specimenNo = specimenNo; self.testClassText = testClassText
            self.clinicalDiagnosis = clinicalDiagnosis; self.sendDoctor = sendDoctor; self.testDoctor = testDoctor
            self.reviewDoctor = reviewDoctor; self.collectedAt = collectedAt; self.receivedAt = receivedAt; self.reportedAt = reportedAt
        }
    }

    /// 定性/比较符行意图（§C.5 `lab_result`）：`result.id = rowId`、`sourceRowId = rowId`、`sourcePage = card.pageIndex`；
    /// `ordinal` = 卡内行序（含数值行，保持报告打印顺序；store 按表内 `MAX(ordinal)+1` 偏移以防同卡分批提交冲突）。
    public struct LabResultIntent: Sendable, Equatable {
        public var rowId: UUID
        public var result: LabResult
        public init(rowId: UUID, result: LabResult) { self.rowId = rowId; self.result = result }
    }

    /// 检验卡分流结果（§C.5 不双写）：`samples`（趋势点，`rowIds` 与之平行）/ `qualitative`（原文行）/ `header` / `remainingRows`（无效行）。
    public struct LabProjection: Sendable, Equatable {
        public var samples: [HospitalSample]
        /// 与 `samples` 平行的行 id（回执 `entity_table='metric_sample'`）。
        public var rowIds: [UUID]
        public var qualitative: [LabResultIntent]
        public var header: LabReportIntent
        public var remainingRows: [MatchedCardRow]
        public init(samples: [HospitalSample], rowIds: [UUID], qualitative: [LabResultIntent], header: LabReportIntent, remainingRows: [MatchedCardRow]) {
            self.samples = samples; self.rowIds = rowIds; self.qualitative = qualitative; self.header = header; self.remainingRows = remainingRows
        }
    }

    /// 住院卡意图（§C.2）：`episodeDate = admitAt ?? dischargeAt`（构造时已保证非空）、`encounterKind ∈ inpatient|daySurgery`
    ///（匹配器按文档类型键派生的共享 `kind`）；store 无显式归属时据此新建 `encounter(kind, date, hospital, department=admitDept)`。
    public struct HospitalizationIntent: Sendable, Equatable {
        public var rowId: UUID
        public var hospitalization: Hospitalization
        public var episodeDate: Date
        public var encounterKind: String
        public var hospital: String? { hospitalization.hospital }
        public var admitDept: String? { hospitalization.admitDept }
        public init(rowId: UUID, hospitalization: Hospitalization, episodeDate: Date, encounterKind: String) {
            self.rowId = rowId; self.hospitalization = hospitalization; self.episodeDate = episodeDate; self.encounterKind = encounterKind
        }
    }

    /// 诊断行意图（§C.3）：`diagnosis.id = rowId`；`encounterId` 只由 store 取显式归属；`healthProblemId` 永为 nil（用户采用后回填）。
    public struct DiagnosisIntent: Sendable, Equatable {
        public var rowId: UUID
        public var diagnosis: Diagnosis
        public init(rowId: UUID, diagnosis: Diagnosis) { self.rowId = rowId; self.diagnosis = diagnosis }
    }

    /// 检查报告意图（§C.4）：单行卡 → 一条 `exam_report`。
    public struct ExamReportIntent: Sendable, Equatable {
        public var rowId: UUID
        public var report: ExamReport
        public init(rowId: UUID, report: ExamReport) { self.rowId = rowId; self.report = report }
    }

    // MARK: - 派生默认（D 级建议，Picker 可改）

    /// 文档类型键 → `diagnosis_type` 默认：诊断证明 → certificate、出院小结 → discharge、病理报告 → pathology、其余 unspecified。
    public static func diagnosisType(forDocumentType key: String?) -> String {
        switch key {
        case "diagnosis_certificate": return "certificate"
        case "discharge_summary": return "discharge"
        case "pathology_report": return "pathology"
        default: return "unspecified"
        }
    }

    // MARK: - 检验分流

    /// 共享面 → 表头意图（字段缺席为 nil，不猜）。
    public static func labHeaderIntent(from card: MatchedCard, calendar: Calendar) -> LabReportIntent {
        let shared = dictionary(card.shared)
        return LabReportIntent(hospital: shared["hospital"], department: shared["department"], labName: shared["lab_name"],
                               reportNo: shared["report_no"], specimenType: shared["specimen_type"], specimenNo: shared["specimen_no"],
                               testClassText: shared["test_class"], clinicalDiagnosis: shared["clinical_diagnosis"],
                               sendDoctor: shared["send_doctor"], testDoctor: shared["test_doctor"], reviewDoctor: shared["review_doctor"],
                               collectedAt: sharedDate("collected_at", in: shared, calendar: calendar),
                               receivedAt: sharedDate("received_at", in: shared, calendar: calendar),
                               reportedAt: sharedDate("reported_at", in: shared, calendar: calendar)
                                   ?? sharedDate("measured_at", in: shared, calendar: calendar))
    }

    /// 分流规则（§C.5，不双写）：行 `value` 为严格十进制数且有 `unit` → `samples`（趋势点，`measuredAt = collectedAt ?? reportedAt`）；
    /// 否则 `value` 原文 → `qualitative`（`resultText` 完整保留，`comparator` 抄录首部 < ≤ > ≥；不折成数值、不丢行）；
    /// 无效字段行 → `remainingRows`；无有效日期 → 整卡 `remainingRows`（不猜日期）。
    public static func labProjection(from card: MatchedCard, calendar: Calendar) -> LabProjection {
        let shared = dictionary(card.shared)
        let header = labHeaderIntent(from: card, calendar: calendar)
        let measuredAt = header.collectedAt ?? header.reportedAt
        var samples: [HospitalSample] = []
        var rowIds: [UUID] = []
        var qualitative: [LabResultIntent] = []
        var remaining: [MatchedCardRow] = []
        for (ordinal, row) in card.rows.enumerated() {
            let invalid = invalidFields(in: card, row: row, calendar: calendar)
            let fields = dictionary(row.fields)
            guard invalid.isEmpty, let measuredAt, let label = fields["raw_label"], let printed = fields["value"] else {
                var residual = row; residual.missingRequired = invalid
                remaining.append(residual)
                continue
            }
            if let value = strictDecimal(printed), let unit = fields["unit"] {
                let labelField = row.fields.first { $0.key == "raw_label" }
                let approval = labelField?.codeApproval
                let code = approval?.label == label && approval?.unit == unit && labelField?.isConfirmed == true
                    && approval?.resolution.kind == .metric
                    && approval?.resolution == labelField?.codeResolution ? approval?.resolution : nil
                samples.append(HospitalSample(
                    metricKey: code.map { "code.\($0.canonicalCode)" } ?? "lab.\(label)", rawLabel: label, value: value, unit: unit,
                    measuredAt: measuredAt,
                    refLow: fields["ref_low"].flatMap(Double.init), refHigh: fields["ref_high"].flatMap(Double.init),
                    refSourceLabel: shared["hospital"],
                    codeConceptId: code?.conceptId, abnormalFlag: fields["abnormal_flag"]))
                rowIds.append(row.id)
            } else {
                qualitative.append(LabResultIntent(rowId: row.id, result: LabResult(
                    id: row.id, patientId: FactPlaceholder.unassignedId, labReportId: FactPlaceholder.unassignedId, ordinal: ordinal,
                    itemName: label, resultText: printed, comparator: leadingComparator(printed), unit: fields["unit"],
                    referenceText: fields["reference_text"], abnormalFlag: fields["abnormal_flag"], method: fields["method"],
                    sourcePage: card.pageIndex, sourceRowId: row.id, createdAt: FactPlaceholder.unassignedDate)))
            }
        }
        return LabProjection(samples: samples, rowIds: rowIds, qualitative: qualitative, header: header, remainingRows: remaining)
    }

    /// 严格十进制数值（`[+-]?digits[.digits][e±digits]`，有限）；十六进制/inf/nan/带单位串一律 nil → 定性原文。
    static func strictDecimal(_ text: String) -> Double? {
        guard text.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// 原文首部比较符抄录（< ≤ > ≥ <= >=），无则 nil；`resultText` 仍保留完整原文。
    static func leadingComparator(_ text: String) -> String? {
        ["<=", ">=", "≤", "≥", "<", ">"].first { text.hasPrefix($0) && text.count > $0.count }
    }

    // MARK: - 住院 / 诊断 / 检查

    /// 住院卡 → 意图：须 `hospital`、派生 `kind ∈ inpatient|daySurgery`、`admit_at ?? discharge_at`；任一缺席/无效 → nil（留待办）。
    public static func hospitalizationIntent(from card: MatchedCard, calendar: Calendar) -> HospitalizationIntent? {
        let shared = dictionary(card.shared)
        guard card.kind == "hospitalization", let row = card.rows.first,
              invalidFields(in: card, row: row, calendar: calendar).isEmpty,
              let hospital = shared["hospital"], let kind = shared["kind"], hospitalizationKinds.contains(kind) else { return nil }
        let admitAt = sharedDate("admit_at", in: shared, calendar: calendar)
        let dischargeAt = sharedDate("discharge_at", in: shared, calendar: calendar)
        guard let episodeDate = admitAt ?? dischargeAt else { return nil }
        let hospitalization = Hospitalization(
            id: row.id, patientId: FactPlaceholder.unassignedId, encounterId: FactPlaceholder.unassignedId,
            hospital: hospital, medicalRecordNo: shared["medical_record_no"], inpatientTimes: shared["inpatient_times"].flatMap(Int.init),
            admitAt: admitAt, dischargeAt: dischargeAt, actualDays: shared["actual_days"].flatMap(Int.init),
            admitDept: shared["admit_dept"], dischargeDept: shared["discharge_dept"], ward: shared["ward"], bedNo: shared["bed_no"],
            admitRouteText: shared["admit_route"], paymentTypeText: shared["payment_type"], dischargeWayText: shared["discharge_way"],
            attendingPhysician: shared["attending_physician"],
            admitDiagnosisText: shared["admit_diagnosis"], dischargeDiagnosisText: shared["discharge_diagnosis"],
            admitCondition: shared["admit_condition"], treatmentCourse: shared["treatment_course"], dischargeCondition: shared["discharge_condition"],
            dischargeOrders: shared["discharge_orders"], takeHomeDrugsText: shared["take_home_drugs"],
            totalCost: shared["total_cost"].flatMap(Double.init), summaryDoctor: shared["summary_doctor"],
            summaryDate: sharedDate("summary_date", in: shared, calendar: calendar),
            source: .ocr, confirmed: false, createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate)
        return HospitalizationIntent(rowId: row.id, hospitalization: hospitalization, episodeDate: episodeDate, encounterKind: kind)
    }

    /// 诊断卡 → 逐行意图（任一行无效或空卡 → nil，与处方同构）。行 `diagnosis_type` 覆盖共享派生默认，均缺省 unspecified；
    /// 日期取共享 `diagnosed_at`（可缺：store 可继承显式归属就诊的日期，不猜）。
    public static func diagnosisIntents(from card: MatchedCard, calendar: Calendar) -> [DiagnosisIntent]? {
        guard card.kind == "diagnosis", !card.rows.isEmpty,
              card.rows.allSatisfy({ invalidFields(in: card, row: $0, calendar: calendar).isEmpty }) else { return nil }
        let shared = dictionary(card.shared)
        let diagnosedAt = shared["diagnosed_at"].flatMap { parseDate($0, calendar: calendar) }
        var intents: [DiagnosisIntent] = []
        for row in card.rows {
            let fields = dictionary(row.fields)
            guard let name = fields["name"] else { return nil }
            intents.append(DiagnosisIntent(rowId: row.id, diagnosis: Diagnosis(
                id: row.id, patientId: FactPlaceholder.unassignedId, ordinal: intents.count,
                diagnosisType: fields["diagnosis_type"] ?? shared["diagnosis_type"] ?? "unspecified",
                name: name, codeText: fields["code_text"], codeSystemText: fields["code_system"], diagnosedAt: diagnosedAt,
                note: fields["note"], sourcePage: card.pageIndex, sourceRowId: row.id, confirmed: false,
                createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate)))
        }
        return intents
    }

    /// 检查卡 → 意图：须 canonical `report_type`、`exam_at ?? reported_at`、`impression ?? findings`；任一缺席/无效 → nil。
    public static func examReportIntent(from card: MatchedCard, calendar: Calendar) -> ExamReportIntent? {
        let shared = dictionary(card.shared)
        guard card.kind == "exam_report", let row = card.rows.first,
              invalidFields(in: card, row: row, calendar: calendar).isEmpty,
              let type = shared["report_type"], ExamReport.reportTypes.contains(type) else { return nil }
        let examAt = sharedDate("exam_at", in: shared, calendar: calendar)
        let reportedAt = sharedDate("reported_at", in: shared, calendar: calendar)
        guard examAt ?? reportedAt != nil, shared["impression"] ?? shared["findings"] != nil else { return nil }
        return ExamReportIntent(rowId: row.id, report: ExamReport(
            id: row.id, patientId: FactPlaceholder.unassignedId, reportType: type,
            hospital: shared["hospital"], department: shared["department"], reportNo: shared["report_no"],
            examPart: shared["exam_part"], examMethod: shared["exam_method"], examAt: examAt, reportedAt: reportedAt,
            findings: shared["findings"], impression: shared["impression"],
            applyDoctor: shared["apply_doctor"], reportDoctor: shared["report_doctor"], reviewDoctor: shared["review_doctor"],
            source: .ocr, confirmed: false, createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate))
    }
}
