import Foundation

/// v27 `card-hierarchy`（子项目 J · round1 §E.7 V10 / 原 D3 §C.8–§C.9）：体检首页 / 结论行 / 手术 / 治疗卡 → 持久化意图。
/// 纯 Domain、零 IO；意图内实体的 `patientId` 为 `FactPlaceholder.unassignedId`、父键（`healthExamId/encounterId`）nil、
/// 时间戳为 `FactPlaceholder.unassignedDate`，由 store 落库时填写；`id = rowId`（与 v25 回填 `id = row_id` 同纪律）。
///
/// BR-006/007：一般检查 `*_text` 原文列全部保留；只有「严格十进制 + 白名单单位」且 `MetricType` 有键（体重 → weight、
/// 收缩压 → bloodPressureSys、舒张压 → bloodPressureDia、脉搏 → heartRate）才投影 `metric_sample`；身高 / BMI / 腰围 / 视力
/// 无键——不投影、不造键、不换算（「斤」不转 kg）。
extension EntityCardProjection {
    // MARK: - 意图类型

    /// 体检首页意图：`exam.id = rowId`；`generalSamples` = 一般检查投影点（`healthExamId = exam.id`，store 以 ensureHealthExam 返回 id 覆盖）。
    public struct HealthExamIntent: Sendable, Equatable {
        public var rowId: UUID
        public var exam: HealthExam
        public var generalSamples: [HospitalSample]
        public init(rowId: UUID, exam: HealthExam, generalSamples: [HospitalSample]) { self.rowId = rowId; self.exam = exam; self.generalSamples = generalSamples }
    }

    /// 结论行意图：`conclusion.id = rowId`、`sourceRowId = rowId`、`sourcePage = card.pageIndex`、`ordinal` = 卡内行序；父键由 store 填（体检 / 表头）。
    public struct ClinicalConclusionIntent: Sendable, Equatable {
        public var rowId: UUID
        public var conclusion: ClinicalConclusion
        public init(rowId: UUID, conclusion: ClinicalConclusion) { self.rowId = rowId; self.conclusion = conclusion }
    }

    /// 手术意图（§C.8）：单行卡 → 一条 `surgery`；`encounterId` 只由 store 取显式归属 / 主卡草稿。
    public struct SurgeryIntent: Sendable, Equatable {
        public var rowId: UUID
        public var surgery: Surgery
        public init(rowId: UUID, surgery: Surgery) { self.rowId = rowId; self.surgery = surgery }
    }

    /// 治疗记录意图（§C.9）：单行卡 → 一条 `treatment_record`；`drugsText` 原文不拆行；`allergyEventId` 恒 nil（用户显式关联）。
    public struct TreatmentRecordIntent: Sendable, Equatable {
        public var rowId: UUID
        public var record: TreatmentRecord
        public init(rowId: UUID, record: TreatmentRecord) { self.rowId = rowId; self.record = record }
    }

    // MARK: - 一般检查投影白名单

    /// F7 一般检查投影白名单：模板键 → (MetricType 键, 允许单位)。身高 / BMI / 腰围 / 视力无 MetricType 键——不投影、不造键。
    static let generalProjection: [(key: String, metric: String, units: Set<String>)] = [
        ("weight", MetricType.weight.rawValue, ["kg", "KG", "Kg", "千克", "公斤"]),
        ("systolic", MetricType.bloodPressureSys.rawValue, ["mmHg", "mmhg", "mm Hg", "毫米汞柱"]),
        ("diastolic", MetricType.bloodPressureDia.rawValue, ["mmHg", "mmhg", "mm Hg", "毫米汞柱"]),
        ("pulse", MetricType.heartRate.rawValue, ["bpm", "BPM", "次/分", "次/分钟", "次/分鐘"]),
    ]

    // MARK: - 体检首页

    /// 体检首页卡 → 意图：须 `org_name` 与可解析 `exam_date`（不猜日期）；任一字段无效 → nil（留待办）。
    public static func healthExamIntent(from card: MatchedCard, calendar: Calendar) -> HealthExamIntent? {
        let shared = dictionary(card.shared)
        func date(_ key: String) -> Date? { shared[key].flatMap { parseDate($0, calendar: calendar) } }
        guard card.kind == "health_exam", let row = card.rows.first,
              invalidFields(in: card, row: row, calendar: calendar).isEmpty,
              let org = shared["org_name"], let examDate = date("exam_date") else { return nil }
        let exam = HealthExam(
            id: row.id, patientId: FactPlaceholder.unassignedId,
            orgName: org, examNo: shared["exam_no"], packageName: shared["package_name"],
            examDate: examDate, totalDoctor: shared["total_doctor"], reportDate: date("report_date"),
            heightText: shared["height"], weightText: shared["weight"], bmiText: shared["bmi"],
            systolicText: shared["systolic"], diastolicText: shared["diastolic"], pulseText: shared["pulse"], waistText: shared["waist"],
            visionLeftText: shared["vision_left"], visionRightText: shared["vision_right"],
            overallConclusion: shared["overall_conclusion"], healthGuidance: shared["health_guidance"],
            source: .ocr, confirmed: false, createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate)
        let samples = generalProjection.compactMap { spec -> HospitalSample? in
            // 严格十进制（同检验分流 strictDecimal：「约72」「170cm」「0x80」不投）+ 单位白名单（「斤」不换算不投）。
            guard let field = card.shared.first(where: { $0.key == spec.key && $0.isConfirmed && $0.grade != .rejected }),
                  let value = strictDecimal(field.value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let unit = field.unit?.trimmingCharacters(in: .whitespacesAndNewlines), spec.units.contains(unit) else { return nil }
            return HospitalSample(metricKey: spec.metric, rawLabel: spec.key, value: value, unit: unit, measuredAt: examDate,
                                  refSourceLabel: org, healthExamId: row.id)
        }
        return HealthExamIntent(rowId: row.id, exam: exam, generalSamples: samples)
    }

    // MARK: - 结论行

    /// 结论卡 → 逐行意图（任一行无效或空卡 → nil，与诊断同构）。行 `conclusion_type` 覆盖关键词派生默认；`severity` 原文。
    public static func clinicalConclusionIntents(from card: MatchedCard, calendar: Calendar) -> [ClinicalConclusionIntent]? {
        guard card.kind == "clinical_conclusion", !card.rows.isEmpty,
              card.rows.allSatisfy({ invalidFields(in: card, row: $0, calendar: calendar).isEmpty }) else { return nil }
        var intents: [ClinicalConclusionIntent] = []
        for row in card.rows {
            let fields = dictionary(row.fields)
            guard let content = fields["content"] else { return nil }
            intents.append(ClinicalConclusionIntent(rowId: row.id, conclusion: ClinicalConclusion(
                id: row.id, patientId: FactPlaceholder.unassignedId,
                conclusionType: fields["conclusion_type"] ?? ClinicalConclusion.conclusionType(forContent: content),
                content: content, severityText: fields["severity"], ordinal: intents.count,
                sourcePage: card.pageIndex, sourceRowId: row.id, createdAt: FactPlaceholder.unassignedDate)))
        }
        return intents
    }

    // MARK: - 手术 / 治疗

    /// 手术卡 → 意图：须 `surgery_name` 与可解析 `surgery_at`；其余列原文；任一缺席/无效 → nil。
    public static func surgeryIntent(from card: MatchedCard, calendar: Calendar) -> SurgeryIntent? {
        let shared = dictionary(card.shared)
        func date(_ key: String) -> Date? { shared[key].flatMap { parseDate($0, calendar: calendar) } }
        guard card.kind == "surgery", let row = card.rows.first,
              invalidFields(in: card, row: row, calendar: calendar).isEmpty,
              let name = shared["surgery_name"], let surgeryAt = date("surgery_at") else { return nil }
        return SurgeryIntent(rowId: row.id, surgery: Surgery(
            id: row.id, patientId: FactPlaceholder.unassignedId,
            hospital: shared["hospital"], department: shared["department"], surgeryAt: surgeryAt, endedAt: date("ended_at"),
            surgeryName: name, surgeryCodeText: shared["surgery_code"], surgeryLevelText: shared["surgery_level"],
            surgeon: shared["surgeon"], assistants: shared["assistants"], anesthesiologist: shared["anesthesiologist"], anesthesiaMethod: shared["anesthesia_method"],
            preopDiagnosisText: shared["preop_diagnosis"], postopDiagnosisText: shared["postop_diagnosis"],
            procedureCourse: shared["procedure_course"], intraopFindings: shared["intraop_findings"],
            implantsText: shared["implants"], specimenText: shared["specimen"], bloodLossText: shared["blood_loss"],
            transfusionText: shared["transfusion"], drainageText: shared["drainage"],
            postopOrders: shared["postop_orders"], complicationsText: shared["complications"],
            source: .ocr, confirmed: false, createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate))
    }

    /// 治疗卡 → 意图：须 canonical `treatment_type`、可解析 `treated_at`、`content ?? drugs_text`；任一缺席/无效 → nil。
    public static func treatmentRecordIntent(from card: MatchedCard, calendar: Calendar) -> TreatmentRecordIntent? {
        let shared = dictionary(card.shared)
        guard card.kind == "treatment_record", let row = card.rows.first,
              invalidFields(in: card, row: row, calendar: calendar).isEmpty,
              let type = shared["treatment_type"], TreatmentRecord.treatmentTypes.contains(type),
              let treatedAt = shared["treated_at"].flatMap({ parseDate($0, calendar: calendar) }),
              shared["content"] ?? shared["drugs_text"] != nil else { return nil }
        return TreatmentRecordIntent(rowId: row.id, record: TreatmentRecord(
            id: row.id, patientId: FactPlaceholder.unassignedId,
            treatmentType: type, treatedAt: treatedAt, hospital: shared["hospital"], department: shared["department"],
            doctor: shared["doctor"], executor: shared["executor"], diagnosisText: shared["diagnosis_text"], content: shared["content"],
            drugsText: shared["drugs_text"], sessionText: shared["session"], adverseReactionText: shared["adverse_reaction"],
            resultText: shared["result"], note: shared["note"],
            source: .ocr, confirmed: false, createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate))
    }
}
