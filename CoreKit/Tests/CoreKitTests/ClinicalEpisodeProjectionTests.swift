import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// 子项目 D · D2-2（v26 `clinical-episodes`）Domain 层：`EncounterKind.daySurgery`；住院/诊断/检查三卡注册；
/// 检验卡数值/定性分流（§C.5 不双写、不猜数值）；诊断行 → D 级健康问题候选（BR-003 不自动写）。
/// 纯 Domain，Linux 可跑（`refactor/scripts/run-domain-tests.sh`）。
@Suite("D2-2 · 住院/诊断/检查卡 + 检验分流 + 诊断候选")
struct ClinicalEpisodeProjectionTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

    // MARK: - 1. daySurgery

    @Test func daySurgery可解码且文档键派生就诊类型() throws {
        #expect(EncounterKind(rawValue: "daySurgery") == .daySurgery)
        #expect(EncounterKind.allCases.contains(.daySurgery))
        #expect(try JSONDecoder().decode(EncounterKind.self, from: Data(#""daySurgery""#.utf8)) == .daySurgery)
        // L10n 键随 rawValue：`encounter.kind.daySurgery`（D2-3 三语落键）
        #expect(EncounterKind.daySurgery.rawValue == "daySurgery")
        #expect(CardTemplateMatcher.encounterKind(for: "inpatient_record") == EncounterKind.inpatient.rawValue)
        #expect(CardTemplateMatcher.encounterKind(for: "discharge_summary") == EncounterKind.inpatient.rawValue)
        #expect(CardTemplateMatcher.encounterKind(for: "day_surgery_record") == EncounterKind.daySurgery.rawValue)
        #expect(CardTemplateMatcher.encounterKind(for: "emergency_record") == EncounterKind.emergency.rawValue)
        #expect(CardTemplateMatcher.encounterKind(for: "outpatient_record") == EncounterKind.outpatient.rawValue)
        #expect(CardTemplateMatcher.encounterKind(for: "diagnosis_certificate") == EncounterKind.outpatient.rawValue)
    }

    // MARK: - 2. 注册表

    @Test func 注册表新增三卡并扩检验表头() throws {
        let hosp = try #require(CardKindRegistry.entry(for: "hospitalization"))
        #expect(hosp.entityTables == ["hospitalization", "encounter"] && hosp.headerTable == "hospitalization")
        #expect(hosp.sharedRequired == ["hospital", "kind"])
        #expect(hosp.sharedOptional.isSuperset(of: ["admit_at", "discharge_at", "admit_dept", "discharge_dept", "ward", "bed_no", "medical_record_no",
                                                     "payment_type", "discharge_way", "admit_route", "attending_physician",
                                                     "admit_condition", "treatment_course", "discharge_condition", "discharge_orders", "take_home_drugs"]))
        #expect(hosp.requiresDocumentType == ["inpatient_record", "discharge_summary", "day_surgery_record"], "入院证不预建住院（§C.2 建议）")
        #expect(hosp.rowRequired.isEmpty && hosp.rowOptional.isEmpty && hosp.dateKey == nil, "admit_at ?? discharge_at 二择一由 invalidFields 裁定")

        let dx = try #require(CardKindRegistry.entry(for: "diagnosis"))
        #expect(dx.entityTables == ["diagnosis"] && dx.rowRequired == ["name"])
        #expect(dx.rowOptional.isSuperset(of: ["code_text", "code_system", "diagnosis_type"]))
        #expect(dx.sharedOptional.isSuperset(of: ["diagnosed_at", "hospital", "diagnosis_type"]) && dx.sharedRequired.isEmpty)
        #expect(dx.requiresDocumentType == ["outpatient_record", "emergency_record", "diagnosis_certificate", "inpatient_record", "discharge_summary", "day_surgery_record", "pathology_report"])

        let exam = try #require(CardKindRegistry.entry(for: "exam_report"))
        #expect(exam.entityTables == ["exam_report"] && exam.sharedRequired == ["report_type"])
        #expect(exam.sharedOptional.isSuperset(of: ["hospital", "department", "report_no", "exam_part", "exam_method", "exam_at", "reported_at",
                                                     "findings", "impression", "apply_doctor", "report_doctor", "review_doctor"]))
        #expect(exam.requiresDocumentType == ["exam_report", "pathology_report", "checkup_report"])

        let lab = try #require(CardKindRegistry.entry(for: "metric_sample"))
        #expect(lab.entityTables == ["metric_sample", "lab_report", "lab_result"] && lab.headerTable == "metric_sample", "卡类不变，回执 entity_table 分流")
        #expect(lab.sharedRequired == ["measured_at"])
        #expect(lab.sharedOptional.isSuperset(of: ["hospital", "department", "lab_name", "report_no", "specimen_type", "specimen_no", "test_class",
                                                    "clinical_diagnosis", "collected_at", "received_at", "reported_at", "send_doctor", "test_doctor", "review_doctor"]))
        #expect(lab.rowRequired == ["raw_label", "value"], "unit 不再是行必填：定性行无单位（分流进 lab_result）")
        #expect(lab.rowOptional.isSuperset(of: ["unit", "ref_low", "ref_high", "metric_key", "reference_text", "abnormal_flag", "method"]))
        #expect(CardKindRegistry.entry(for: "encounter")?.requiresDocumentType == ["outpatient_record", "diagnosis_certificate", "emergency_record"])
        #expect(CardKindRegistry.entries.map(\.kind).count == Set(CardKindRegistry.entries.map(\.kind)).count, "kind 唯一")
    }

    @Test func 新卡类有模板与建卡最小集规则() throws {
        for kind in ["hospitalization", "diagnosis", "exam_report"] {
            #expect(CardTemplateMatcher.ocrTemplates.contains { $0.kind == kind }, "\(kind)")
            let rules = CompletenessEvaluator.rules(for: kind)
            #expect(!rules.isEmpty && rules.contains(where: \.isRequired), "\(kind)")
        }
        #expect(Set(CompletenessEvaluator.rules(for: "hospitalization").filter(\.isRequired).map(\.key)) == ["hospital", "kind"])
        #expect(Set(CompletenessEvaluator.rules(for: "diagnosis").filter(\.isRequired).map(\.key)) == ["name"])
        #expect(Set(CompletenessEvaluator.rules(for: "exam_report").filter(\.isRequired).map(\.key)) == ["report_type", "exam_at"])
        // 既有金样分母不动（目录与门槛分离）
        #expect(CompletenessEvaluator.rules(for: "metric_sample").count == 8)
        #expect(CompletenessEvaluator.rules(for: "encounter").count == 6)
        // 「添加字段」目录：住院表头列全部可补录
        let catalog = CardKindRegistry.optionalCatalog(kind: "hospitalization", present: ["hospital", "admit_at"], rowLevel: false)
        #expect(catalog.contains("discharge_orders") && catalog.contains("take_home_drugs") && !catalog.contains("admit_at") && !catalog.contains("hospital"))
        #expect(CardKindRegistry.optionalCatalog(kind: "metric_sample", present: [], rowLevel: true).contains("abnormal_flag"))
        #expect(CardKindRegistry.optionalCatalog(kind: "metric_sample", present: [], rowLevel: false).contains("specimen_type"))
    }

    // MARK: - 3. DDL 镜像值类型

    @Test func 五值类型Codable往返且占位符统一() throws {
        let t0 = Date(timeIntervalSince1970: 1), t1 = Date(timeIntervalSince1970: 2)
        let hosp = Hospitalization(id: UUID(), patientId: UUID(), encounterId: UUID(), hospital: "市一医院", admitAt: day(2026, 1, 2), dischargeAt: day(2026, 1, 9),
                                   actualDays: 7, dischargeOrders: "低盐饮食", takeHomeDrugsText: "阿司匹林 100mg qd", totalCost: 12345.6,
                                   source: .ocr, confirmed: true, createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(Hospitalization.self, from: JSONEncoder().encode(hosp)) == hosp)
        let dx = Diagnosis(id: UUID(), patientId: UUID(), ordinal: 1, diagnosisType: "discharge", name: "高血压 2 级", codeText: "I10.x02",
                           codeSystemText: "ICD-10", diagnosedAt: day(2026, 1, 9), sourcePage: 0, sourceRowId: UUID(), createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(Diagnosis.self, from: JSONEncoder().encode(dx)) == dx)
        #expect(dx.confirmed == false && dx.encounterId == nil && dx.healthProblemId == nil, "BR-003：D 级草稿；health_problem_id 只由用户显式采用回填")
        let exam = ExamReport(id: UUID(), patientId: UUID(), reportType: "ct", examPart: "胸部", examAt: day(2026, 1, 3), findings: "双肺纹理清晰",
                              impression: "未见明显异常", source: .ocr, createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(ExamReport.self, from: JSONEncoder().encode(exam)) == exam)
        let report = LabReport(id: UUID(), patientId: UUID(), hospital: "市一医院", specimenType: "静脉血", collectedAt: day(2026, 1, 2), reportedAt: day(2026, 1, 3),
                               reviewDoctor: "王", sourceCardId: UUID(), source: .ocr, confirmed: true, createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(LabReport.self, from: JSONEncoder().encode(report)) == report)
        let result = LabResult(id: UUID(), patientId: UUID(), labReportId: UUID(), ordinal: 3, itemName: "HBsAg", resultText: "阴性",
                               referenceText: "阴性", abnormalFlag: nil, sourcePage: 1, sourceRowId: UUID(), createdAt: t0)
        #expect(try JSONDecoder().decode(LabResult.self, from: JSONEncoder().encode(result)) == result)
        #expect(FactPlaceholder.unassignedId == PrescriptionLine.unassignedId, "父键占位与处方行同一常量")
        #expect(FactSource.ocr.rawValue == "ocr" && FactSource.manual.rawValue == "manual", "与 DDL CHECK(source IN ('ocr','manual')) 同拼写")
        #expect(ExamReport.reportTypes == ["ct", "mri", "xray", "ultrasound", "ecg", "endoscopy", "pathology", "nuclear", "other"])
        #expect(Diagnosis.diagnosisTypes == ["primary", "secondary", "admission", "discharge", "preop", "postop", "pathology", "certificate", "unspecified"])
    }

    // MARK: - 5. 检验分流（§C.5：value 严格 Double 且有 unit → metric_sample；否则原文 → lab_result；不双写、不猜数值）

    private func labCard(shared: [FieldDraft] = [FieldDraft(key: "measured_at", value: "2026-09-01")], rows: [[FieldDraft]]) -> MatchedCard {
        MatchedCard(kind: "metric_sample", pageIndex: 2, shared: shared, rows: rows.map { MatchedCardRow(fields: $0) },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
    }

    @Test func 阴性行进qualitative不进samples() throws {
        let card = labCard(rows: [[.init(key: "raw_label", value: "HBsAg"), .init(key: "value", value: "阴性")]])
        #expect(EntityCardProjection.invalidFields(in: card, row: card.rows[0], calendar: utc).isEmpty, "定性行无单位仍有效")
        let projection = EntityCardProjection.labProjection(from: card, calendar: utc)
        #expect(projection.samples.isEmpty && projection.rowIds.isEmpty && projection.remainingRows.isEmpty)
        let qualitative = try #require(projection.qualitative.first)
        #expect(projection.qualitative.count == 1 && qualitative.rowId == card.rows[0].id)
        #expect(qualitative.result.itemName == "HBsAg" && qualitative.result.resultText == "阴性" && qualitative.result.comparator == nil && qualitative.result.unit == nil)
        #expect(qualitative.result.id == card.rows[0].id && qualitative.result.sourceRowId == card.rows[0].id && qualitative.result.sourcePage == 2 && qualitative.result.ordinal == 0)
        #expect(qualitative.result.labReportId == FactPlaceholder.unassignedId && qualitative.result.patientId == FactPlaceholder.unassignedId, "表头/成员由 store 填")
        #expect(qualitative.result.codeConceptId == nil, "F25 编码只经用户批准")
    }

    @Test func 比较符与半定量行保留原文不转数值() throws {
        let card = labCard(rows: [
            [.init(key: "raw_label", value: "AFP"), .init(key: "value", value: "<0.5"), .init(key: "unit", value: "ng/mL"), .init(key: "reference_text", value: "<7")],
            [.init(key: "raw_label", value: "ANA"), .init(key: "value", value: "≥1:160"), .init(key: "abnormal_flag", value: "阳性")],
            [.init(key: "raw_label", value: "尿蛋白"), .init(key: "value", value: "+")],
            [.init(key: "raw_label", value: "HCV-RNA"), .init(key: "value", value: "未检出"), .init(key: "method", value: "PCR")],
        ])
        let projection = EntityCardProjection.labProjection(from: card, calendar: utc)
        #expect(projection.samples.isEmpty && projection.remainingRows.isEmpty && projection.qualitative.count == 4)
        let afp = projection.qualitative[0].result
        #expect(afp.resultText == "<0.5" && afp.comparator == "<" && afp.unit == "ng/mL" && afp.referenceText == "<7", "比较符抄录，原文完整保留（不折成 0.5）")
        let ana = projection.qualitative[1].result
        #expect(ana.resultText == "≥1:160" && ana.comparator == "≥" && ana.abnormalFlag == "阳性", "abnormal_flag 为打印原文，不解释")
        #expect(projection.qualitative[2].result.resultText == "+" && projection.qualitative[2].result.comparator == nil)
        #expect(projection.qualitative[3].result.resultText == "未检出" && projection.qualitative[3].result.method == "PCR")
        #expect(projection.qualitative.map(\.result.ordinal) == [0, 1, 2, 3])
    }

    @Test func 数值行进samples携带打印abnormal_flag且无单位数值按原文进定性() throws {
        let card = labCard(rows: [
            [.init(key: "raw_label", value: "血红蛋白"), .init(key: "value", value: "150"), .init(key: "unit", value: "g/L"), .init(key: "abnormal_flag", value: "↑"),
             .init(key: "ref_low", value: "115"), .init(key: "ref_high", value: "150")],
            [.init(key: "raw_label", value: "红细胞"), .init(key: "value", value: "4.5")],
        ])
        let projection = EntityCardProjection.labProjection(from: card, calendar: utc)
        #expect(projection.samples.count == 1 && projection.rowIds == [card.rows[0].id])
        let sample = try #require(projection.samples.first)
        #expect(sample.rawLabel == "血红蛋白" && sample.value == 150 && sample.unit == "g/L" && sample.refLow == 115 && sample.refHigh == 150)
        #expect(sample.abnormalFlag == "↑", "趋势点携带打印标记（A 级来源事实），App 不计算")
        #expect(projection.qualitative.count == 1 && projection.qualitative[0].result.resultText == "4.5" && projection.qualitative[0].result.unit == nil,
                "无单位不进趋势（unit NOT NULL），原文进 lab_result 不丢")
        #expect(projection.remainingRows.isEmpty)
        // 薄封装：既有 hospitalSamples 读面 = 数值行；定性行对其视作跳过
        let legacy = EntityCardProjection.hospitalSamples(from: card, calendar: utc)
        #expect(legacy.samples == projection.samples && legacy.rowIds == projection.rowIds && legacy.skippedRows == 1)
    }

    @Test func 参考范围非法行与无日期整卡留remaining() {
        let bad = labCard(rows: [
            [.init(key: "raw_label", value: "A"), .init(key: "value", value: "12"), .init(key: "unit", value: "g/L"), .init(key: "ref_low", value: "abc")],
            [.init(key: "raw_label", value: "B"), .init(key: "value", value: "阴性")],
        ])
        let projection = EntityCardProjection.labProjection(from: bad, calendar: utc)
        #expect(projection.samples.isEmpty && projection.qualitative.count == 1 && projection.remainingRows.count == 1)
        #expect(projection.remainingRows[0].missingRequired == ["ref_low"])
        let undated = labCard(shared: [], rows: [[.init(key: "raw_label", value: "A"), .init(key: "value", value: "12"), .init(key: "unit", value: "g/L")],
                                                 [.init(key: "raw_label", value: "B"), .init(key: "value", value: "阴性")]])
        let none = EntityCardProjection.labProjection(from: undated, calendar: utc)
        #expect(none.samples.isEmpty && none.qualitative.isEmpty && none.remainingRows.count == 2, "无日期不猜：整卡 remaining")
        #expect(none.header.reportedAt == nil && none.header.collectedAt == nil)
    }

    @Test func 表头意图取共享键_采集时间为趋势x轴_报告时间回落measured_at() throws {
        let card = labCard(shared: [.init(key: "measured_at", value: "2026-09-03"), .init(key: "collected_at", value: "2026-09-02"),
                                    .init(key: "hospital", value: "市一医院"), .init(key: "department", value: "检验科"), .init(key: "lab_name", value: "临检室"),
                                    .init(key: "report_no", value: "L001"), .init(key: "specimen_type", value: "静脉血"), .init(key: "specimen_no", value: "S9"),
                                    .init(key: "test_class", value: "生化"), .init(key: "clinical_diagnosis", value: "体检"),
                                    .init(key: "send_doctor", value: "张"), .init(key: "test_doctor", value: "李"), .init(key: "review_doctor", value: "王")],
                           rows: [[.init(key: "raw_label", value: "血糖"), .init(key: "value", value: "5.6"), .init(key: "unit", value: "mmol/L")]])
        let projection = EntityCardProjection.labProjection(from: card, calendar: utc)
        let header = projection.header
        #expect(header.hospital == "市一医院" && header.department == "检验科" && header.labName == "临检室" && header.reportNo == "L001")
        #expect(header.specimenType == "静脉血" && header.specimenNo == "S9" && header.testClassText == "生化" && header.clinicalDiagnosis == "体检")
        #expect(header.sendDoctor == "张" && header.testDoctor == "李" && header.reviewDoctor == "王")
        #expect(header.collectedAt == day(2026, 9, 2) && header.reportedAt == day(2026, 9, 3) && header.receivedAt == nil, "reported_at 缺席回落 measured_at（与 v26 回填同义）")
        #expect(projection.samples.first?.measuredAt == day(2026, 9, 2), "趋势 x 轴 = collected_at ?? reported_at")
        #expect(projection.samples.first?.refSourceLabel == "市一医院")
        #expect(EntityCardProjection.labHeaderIntent(from: card, calendar: utc) == header)
        let explicit = labCard(shared: [.init(key: "measured_at", value: "2026-09-03"), .init(key: "reported_at", value: "2026-09-05"), .init(key: "received_at", value: "2026-09-04")],
                               rows: [[.init(key: "raw_label", value: "血糖"), .init(key: "value", value: "5.6"), .init(key: "unit", value: "mmol/L")]])
        let h2 = EntityCardProjection.labProjection(from: explicit, calendar: utc)
        #expect(h2.header.reportedAt == day(2026, 9, 5) && h2.header.receivedAt == day(2026, 9, 4) && h2.samples.first?.measuredAt == day(2026, 9, 5))
        let badDate = labCard(shared: [.init(key: "measured_at", value: "2026-09-03"), .init(key: "collected_at", value: "昨天")],
                              rows: [[.init(key: "raw_label", value: "血糖"), .init(key: "value", value: "5.6"), .init(key: "unit", value: "mmol/L")]])
        #expect(EntityCardProjection.invalidFields(in: badDate, row: badDate.rows[0], calendar: utc) == ["collected_at"], "可选日期键出现即须可解析")
    }

    // MARK: - 5. 住院 / 诊断 / 检查意图

    private func card(_ kind: String, pageIndex: Int = 0, shared: [FieldDraft], rows: [[FieldDraft]] = [[]]) -> MatchedCard {
        MatchedCard(kind: kind, pageIndex: pageIndex, shared: shared, rows: rows.map { MatchedCardRow(fields: $0) },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
    }

    @Test func 住院意图_就诊类型按派生kind_日期二择一_叙事与带药原文() throws {
        let full = card("hospitalization", pageIndex: 1, shared: [
            .init(key: "hospital", value: "市一医院"), .init(key: "kind", value: "inpatient"),
            .init(key: "admit_at", value: "2026-01-02"), .init(key: "discharge_at", value: "2026年1月9日"),
            .init(key: "admit_dept", value: "心内科"), .init(key: "discharge_dept", value: "心内科"), .init(key: "ward", value: "3 病区"), .init(key: "bed_no", value: "12"),
            .init(key: "medical_record_no", value: "ZY0001"), .init(key: "inpatient_times", value: "2"), .init(key: "actual_days", value: "7"),
            .init(key: "admit_route", value: "急诊"), .init(key: "payment_type", value: "城镇职工医保"), .init(key: "discharge_way", value: "医嘱离院"),
            .init(key: "attending_physician", value: "张主任"),
            .init(key: "admit_diagnosis", value: "胸痛待查"), .init(key: "discharge_diagnosis", value: "不稳定型心绞痛"),
            .init(key: "admit_condition", value: "胸痛 3 小时"), .init(key: "treatment_course", value: "予抗血小板…"), .init(key: "discharge_condition", value: "好转"),
            .init(key: "discharge_orders", value: "低盐饮食，两周后复诊"), .init(key: "take_home_drugs", value: "阿司匹林 100mg qd ×14"),
            .init(key: "total_cost", value: "12345.6"), .init(key: "summary_doctor", value: "李"), .init(key: "summary_date", value: "2026-01-09"),
        ])
        #expect(EntityCardProjection.invalidFields(in: full, row: full.rows[0], calendar: utc).isEmpty)
        let intent = try #require(EntityCardProjection.hospitalizationIntent(from: full, calendar: utc))
        #expect(intent.rowId == full.rows[0].id && intent.episodeDate == day(2026, 1, 2) && intent.encounterKind == "inpatient")
        #expect(intent.hospital == "市一医院" && intent.admitDept == "心内科")
        let h = intent.hospitalization
        #expect(h.admitAt == day(2026, 1, 2) && h.dischargeAt == day(2026, 1, 9) && h.summaryDate == day(2026, 1, 9))
        #expect(h.ward == "3 病区" && h.bedNo == "12" && h.medicalRecordNo == "ZY0001" && h.inpatientTimes == 2 && h.actualDays == 7)
        #expect(h.admitRouteText == "急诊" && h.paymentTypeText == "城镇职工医保" && h.dischargeWayText == "医嘱离院" && h.attendingPhysician == "张主任")
        #expect(h.admitDiagnosisText == "胸痛待查" && h.dischargeDiagnosisText == "不稳定型心绞痛")
        #expect(h.admitCondition == "胸痛 3 小时" && h.treatmentCourse == "予抗血小板…" && h.dischargeCondition == "好转")
        #expect(h.dischargeOrders == "低盐饮食，两周后复诊" && h.takeHomeDrugsText == "阿司匹林 100mg qd ×14", "带药只存原文（BR-006）")
        #expect(h.totalCost == 12345.6 && h.summaryDoctor == "李")
        #expect(h.patientId == FactPlaceholder.unassignedId && h.encounterId == FactPlaceholder.unassignedId && h.confirmed == false && h.source == .ocr)
        let dischargeOnly = card("hospitalization", shared: [.init(key: "hospital", value: "A"), .init(key: "kind", value: "daySurgery"), .init(key: "discharge_at", value: "2026-03-01")])
        let d = try #require(EntityCardProjection.hospitalizationIntent(from: dischargeOnly, calendar: utc))
        #expect(d.episodeDate == day(2026, 3, 1) && d.encounterKind == "daySurgery" && d.hospitalization.admitAt == nil)
    }

    @Test func 住院意图缺日期或医院或非住院kind返回nil() {
        let noDate = card("hospitalization", shared: [.init(key: "hospital", value: "A"), .init(key: "kind", value: "inpatient"), .init(key: "ward", value: "1")])
        #expect(EntityCardProjection.invalidFields(in: noDate, row: noDate.rows[0], calendar: utc) == ["admit_at"], "admit_at ?? discharge_at 二择一缺席 → 留待办，不猜日期")
        #expect(EntityCardProjection.hospitalizationIntent(from: noDate, calendar: utc) == nil)
        let noHospital = card("hospitalization", shared: [.init(key: "kind", value: "inpatient"), .init(key: "admit_at", value: "2026-01-02")])
        #expect(EntityCardProjection.hospitalizationIntent(from: noHospital, calendar: utc) == nil)
        let outpatient = card("hospitalization", shared: [.init(key: "hospital", value: "A"), .init(key: "kind", value: "outpatient"), .init(key: "admit_at", value: "2026-01-02")])
        #expect(EntityCardProjection.invalidFields(in: outpatient, row: outpatient.rows[0], calendar: utc) == ["kind"])
        #expect(EntityCardProjection.hospitalizationIntent(from: outpatient, calendar: utc) == nil)
        let badNumbers = card("hospitalization", shared: [.init(key: "hospital", value: "A"), .init(key: "kind", value: "inpatient"), .init(key: "admit_at", value: "2026-01-02"),
                                                          .init(key: "actual_days", value: "七天"), .init(key: "total_cost", value: "壹万")])
        #expect(EntityCardProjection.invalidFields(in: badNumbers, row: badNumbers.rows[0], calendar: utc) == ["actual_days", "total_cost"])
        #expect(EntityCardProjection.hospitalizationIntent(from: card("encounter", shared: [.init(key: "date", value: "2026-01-02"), .init(key: "kind", value: "inpatient")]), calendar: utc) == nil, "卡类不符")
    }

    @Test func 诊断类型按文档键派生默认unspecified() {
        #expect(EntityCardProjection.diagnosisType(forDocumentType: "diagnosis_certificate") == "certificate")
        #expect(EntityCardProjection.diagnosisType(forDocumentType: "discharge_summary") == "discharge")
        #expect(EntityCardProjection.diagnosisType(forDocumentType: "pathology_report") == "pathology")
        #expect(EntityCardProjection.diagnosisType(forDocumentType: "outpatient_record") == "unspecified")
        #expect(EntityCardProjection.diagnosisType(forDocumentType: "inpatient_record") == "unspecified")
        #expect(EntityCardProjection.diagnosisType(forDocumentType: nil) == "unspecified")
    }

    @Test func 诊断意图逐行_行级类型覆盖共享默认_编码只存打印文本() throws {
        let dx = card("diagnosis", pageIndex: 3,
                      shared: [.init(key: "diagnosed_at", value: "2026-01-09"), .init(key: "hospital", value: "市一医院"), .init(key: "diagnosis_type", value: "discharge")],
                      rows: [[.init(key: "name", value: "高血压 2 级"), .init(key: "code_text", value: "I10.x02"), .init(key: "code_system", value: "ICD-10"), .init(key: "diagnosis_type", value: "primary")],
                             [.init(key: "name", value: "2 型糖尿病"), .init(key: "note", value: "口服药控制")]])
        #expect(dx.rows.allSatisfy { EntityCardProjection.invalidFields(in: dx, row: $0, calendar: utc).isEmpty })
        let intents = try #require(EntityCardProjection.diagnosisIntents(from: dx, calendar: utc))
        #expect(intents.count == 2 && intents.map(\.rowId) == dx.rows.map(\.id))
        let first = intents[0].diagnosis
        #expect(first.name == "高血压 2 级" && first.codeText == "I10.x02" && first.codeSystemText == "ICD-10" && first.diagnosisType == "primary")
        #expect(first.id == dx.rows[0].id && first.sourceRowId == dx.rows[0].id && first.sourcePage == 3 && first.ordinal == 0)
        #expect(first.diagnosedAt == day(2026, 1, 9) && first.encounterId == nil && first.healthProblemId == nil && first.confirmed == false)
        #expect(first.patientId == FactPlaceholder.unassignedId)
        let second = intents[1].diagnosis
        #expect(second.diagnosisType == "discharge" && second.note == "口服药控制" && second.codeText == nil && second.ordinal == 1, "行无类型 → 共享派生默认；无码不猜码")
        // 健康问题候选直接由意图行派生（D 级，用户勾选后才落 health_problem）
        #expect(HealthProblemCandidate.from(diagnoses: intents.map(\.diagnosis)).map(\.name) == ["高血压 2 级", "2 型糖尿病"])
        let badType = card("diagnosis", shared: [.init(key: "diagnosis_type", value: "主要诊断")], rows: [[.init(key: "name", value: "A")]])
        #expect(EntityCardProjection.invalidFields(in: badType, row: badType.rows[0], calendar: utc) == ["diagnosis_type"], "枚举须 canonical raw")
        #expect(EntityCardProjection.diagnosisIntents(from: badType, calendar: utc) == nil)
        let noName = card("diagnosis", shared: [], rows: [[.init(key: "code_text", value: "I10")]])
        #expect(EntityCardProjection.invalidFields(in: noName, row: noName.rows[0], calendar: utc) == ["name"])
        let undated = card("diagnosis", shared: [], rows: [[.init(key: "name", value: "A")]])
        #expect(EntityCardProjection.diagnosisIntents(from: undated, calendar: utc)?.first?.diagnosis.diagnosedAt == nil, "日期可继承同页就诊卡：无日期不阻断")
    }

    @Test func 检查报告意图_类型canonical_日期与结论二择一() throws {
        let exam = card("exam_report", shared: [
            .init(key: "report_type", value: "ct"), .init(key: "hospital", value: "市一医院"), .init(key: "department", value: "放射科"), .init(key: "report_no", value: "R001"),
            .init(key: "exam_part", value: "胸部"), .init(key: "exam_method", value: "平扫"), .init(key: "exam_at", value: "2026-01-03"), .init(key: "reported_at", value: "2026-01-04"),
            .init(key: "findings", value: "双肺纹理清晰，未见实变。"), .init(key: "impression", value: "胸部 CT 平扫未见明显异常。"),
            .init(key: "apply_doctor", value: "张"), .init(key: "report_doctor", value: "李"), .init(key: "review_doctor", value: "王"),
        ])
        #expect(EntityCardProjection.invalidFields(in: exam, row: exam.rows[0], calendar: utc).isEmpty)
        let intent = try #require(EntityCardProjection.examReportIntent(from: exam, calendar: utc))
        let r = intent.report
        #expect(intent.rowId == exam.rows[0].id && r.reportType == "ct" && r.hospital == "市一医院" && r.department == "放射科" && r.reportNo == "R001")
        #expect(r.examPart == "胸部" && r.examMethod == "平扫" && r.examAt == day(2026, 1, 3) && r.reportedAt == day(2026, 1, 4))
        #expect(r.findings == "双肺纹理清晰，未见实变。" && r.impression == "胸部 CT 平扫未见明显异常。", "原文叙事不摘要不改写")
        #expect(r.applyDoctor == "张" && r.reportDoctor == "李" && r.reviewDoctor == "王")
        #expect(r.patientId == FactPlaceholder.unassignedId && r.encounterId == nil && r.confirmed == false && r.source == .ocr)
        let reportedOnly = card("exam_report", shared: [.init(key: "report_type", value: "pathology"), .init(key: "reported_at", value: "2026-01-04"), .init(key: "findings", value: "镜下…")])
        #expect(EntityCardProjection.examReportIntent(from: reportedOnly, calendar: utc)?.report.examAt == nil)
        #expect(EntityCardProjection.examReportIntent(from: reportedOnly, calendar: utc)?.report.impression == nil)
        let noNarrative = card("exam_report", shared: [.init(key: "report_type", value: "ct"), .init(key: "exam_at", value: "2026-01-03")])
        #expect(EntityCardProjection.invalidFields(in: noNarrative, row: noNarrative.rows[0], calendar: utc) == ["impression"])
        #expect(EntityCardProjection.examReportIntent(from: noNarrative, calendar: utc) == nil)
        let noDate = card("exam_report", shared: [.init(key: "report_type", value: "ct"), .init(key: "impression", value: "正常")])
        #expect(EntityCardProjection.invalidFields(in: noDate, row: noDate.rows[0], calendar: utc) == ["exam_at"])
        let rawType = card("exam_report", shared: [.init(key: "report_type", value: "CT"), .init(key: "exam_at", value: "2026-01-03"), .init(key: "impression", value: "正常")])
        #expect(EntityCardProjection.invalidFields(in: rawType, row: rawType.rows[0], calendar: utc) == ["report_type"], "须 canonical raw（归一在理解层 normalized）")
    }

    // MARK: - 4. 模板匹配（住院/诊断/检查/检验表头）

    private func f(_ key: String, _ value: String, unit: String? = nil, raw: String? = nil, line: Int? = nil) -> FieldDraft {
        FieldDraft(key: key, value: value, unit: unit, confidence: 0.9, rawText: raw, source: .heuristic, sourceLineIndex: line)
    }

    @Test func 住院文书页出住院卡_kind按文档键派生_叙事多段并入_不出就诊卡() throws {
        let fields = [f("hospital", "市一医院"), f("admit_at", "2026-01-02"), f("discharge_at", "2026-01-09"), f("admit_dept", "心内科"),
                      f("attending_physician", "张主任"), f("discharge_orders", "1. 低盐饮食"), f("discharge_orders", "2. 两周后复诊"),
                      f("take_home_drugs", "阿司匹林 100mg qd"), f("report_date", "2026-01-09")]
        let cards = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "inpatient_record")
        let hosp = try #require(cards.first { $0.kind == "hospitalization" })
        #expect(hosp.rows.count == 1 && hosp.rows[0].fields.isEmpty, "单行卡：表头即实体")
        #expect(hosp.shared.contains { $0.key == "kind" && $0.value == "inpatient" && $0.source == .heuristic })
        #expect(hosp.shared.first { $0.key == "discharge_orders" }?.value == "1. 低盐饮食\n2. 两周后复诊", "出院医嘱多段并入同键，不静默丢行")
        #expect(hosp.shared.contains { $0.key == "take_home_drugs" && $0.value == "阿司匹林 100mg qd" })
        #expect(!hosp.shared.contains { $0.key == "measured_at" || $0.key == "date" }, "泛日期不冒充入/出院日期")
        #expect(hosp.requiredCoverage == 1 && hosp.allFieldCoverage == 1, "六条规则（hospital/kind 必填 + 四推荐）全覆盖")
        let sparse = [f("hospital", "市一医院"), f("ward", "3 病区")]
        #expect(CardTemplateMatcher.match(fields: sparse, pageIndex: 0, documentTypeKey: "inpatient_record").isEmpty, "hospital+kind = 2/6 < 0.5 不出卡")
        let minimal = sparse + [f("discharge_at", "2026-01-09")]
        #expect(CardTemplateMatcher.match(fields: minimal, pageIndex: 0, documentTypeKey: "inpatient_record").first?.allFieldCoverage == 0.5)
        #expect(!cards.contains { $0.kind == "encounter" }, "住院族文档不出就诊卡（住院卡建就诊）")
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "day_surgery_record").first { $0.kind == "hospitalization" }?
            .shared.contains { $0.key == "kind" && $0.value == "daySurgery" } == true)
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "outpatient_record").contains { $0.kind == "hospitalization" })
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "admission_certificate").contains { $0.kind == "hospitalization" }, "入院证不预建")
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: nil).isEmpty)
    }

    @Test func 急诊病历出就诊卡且kind为emergency() {
        let fields = [f("report_date", "2026-09-01"), f("dept", "急诊科"), f("diagnosis", "急性胃肠炎")]
        let card = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "emergency_record").first { $0.kind == "encounter" }
        #expect(card?.shared.contains { $0.key == "kind" && $0.value == EncounterKind.emergency.rawValue } == true)
    }

    @Test func 诊断页每条一行_同行编码与类型归行_共享类型按文档键派生() throws {
        let fields = [f("hospital", "市一医院"), f("report_date", "2026-01-09"),
                      f("diagnosis_item", "高血压 2 级", raw: "1. 高血压 2 级 I10.x02 主要诊断", line: 3),
                      f("diagnosis_code", "I10.x02", raw: "1. 高血压 2 级 I10.x02 主要诊断", line: 3),
                      f("diagnosis_type", "primary", raw: "1. 高血压 2 级 I10.x02 主要诊断", line: 3),
                      f("diagnosis_item", "2 型糖尿病", raw: "2. 2 型糖尿病", line: 4)]
        let card = try #require(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "discharge_summary").first { $0.kind == "diagnosis" })
        #expect(card.rows.count == 2)
        #expect(card.rows[0].fields.contains { $0.key == "name" && $0.value == "高血压 2 级" })
        #expect(card.rows[0].fields.contains { $0.key == "code_text" && $0.value == "I10.x02" }, "同行编码归行（只存打印码）")
        #expect(card.rows[0].fields.contains { $0.key == "diagnosis_type" && $0.value == "primary" })
        #expect(card.rows[1].fields.map(\.key) == ["name"], "第二行无码不借用他行")
        #expect(card.shared.contains { $0.key == "diagnosis_type" && $0.value == "discharge" }, "共享默认按文档键派生（D 级，Picker 可改）")
        #expect(card.shared.contains { $0.key == "diagnosed_at" && $0.value == "2026-01-09" } && card.shared.contains { $0.key == "hospital" })
        #expect(card.requiredCoverage == 1 && card.allFieldCoverage == 1)
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "diagnosis_certificate").first { $0.kind == "diagnosis" }?
            .shared.contains { $0.key == "diagnosis_type" && $0.value == "certificate" } == true)
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").contains { $0.kind == "diagnosis" }, "仅病历类文档出诊断卡")
        let intents = try #require(EntityCardProjection.diagnosisIntents(from: card.fullyConfirmed(), calendar: utc))
        #expect(intents.map(\.diagnosis.diagnosisType) == ["primary", "discharge"] && intents[0].diagnosis.codeText == "I10.x02")
    }

    @Test func 检查报告页出检查卡_病理文档键派生类型_无类型不出卡() throws {
        let fields = [f("report_type", "ct"), f("report_date", "2026-01-03"), f("exam_part", "胸部"), f("hospital", "市一医院"),
                      f("findings", "双肺纹理清晰"), f("impression", "未见明显异常"), f("report_doctor", "李"), f("reported_at", "2026-01-04")]
        let ct = try #require(CardTemplateMatcher.match(fields: fields, pageIndex: 1, documentTypeKey: "exam_report").first { $0.kind == "exam_report" })
        #expect(ct.shared.contains { $0.key == "report_type" && $0.value == "ct" } && ct.shared.contains { $0.key == "exam_at" && $0.value == "2026-01-03" })
        #expect(ct.shared.contains { $0.key == "reported_at" && $0.value == "2026-01-04" } && ct.shared.contains { $0.key == "impression" })
        #expect(ct.rows.count == 1 && ct.requiredCoverage == 1)
        #expect(EntityCardProjection.examReportIntent(from: ct.fullyConfirmed(), calendar: utc)?.report.reportType == "ct")
        let pathologyFields = [f("report_date", "2026-01-03"), f("findings", "镜下见…"), f("impression", "（胃窦）慢性浅表性胃炎")]
        let pathology = CardTemplateMatcher.match(fields: pathologyFields, pageIndex: 0, documentTypeKey: "pathology_report").first { $0.kind == "exam_report" }
        #expect(pathology?.shared.contains { $0.key == "report_type" && $0.value == "pathology" } == true, "病理文档键派生 report_type")
        #expect(CardTemplateMatcher.match(fields: pathologyFields, pageIndex: 0, documentTypeKey: "exam_report").isEmpty, "无类型证据不出卡（必填 1/2）")
        #expect(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").allSatisfy { $0.kind != "exam_report" })
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "outpatient_record").contains { $0.kind == "exam_report" })
    }

    @Test func 检验表头共享键与同原文打印标记归行() throws {
        let raw = "血红蛋白 150 g/L ↑ 115-150"
        let fields = [f("report_date", "2026-09-03"), f("specimen_type", "静脉血"), f("collect_time", "2026-09-02"), f("review_doctor", "王"),
                      f("dept", "检验科"), f("report_no", "L001"), f("hospital", "市一医院"),
                      f("lab_item", "血红蛋白 150", unit: "g/L", raw: raw), f("abnormal_flag", "↑", raw: raw), f("reference_range", "115-150", raw: raw),
                      f("abnormal_flag", "↓", raw: "孤儿标记 ↓")]
        let card = try #require(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").first { $0.kind == "metric_sample" })
        for (key, value) in [("measured_at", "2026-09-03"), ("specimen_type", "静脉血"), ("collected_at", "2026-09-02"), ("review_doctor", "王"),
                             ("department", "检验科"), ("report_no", "L001"), ("hospital", "市一医院")] {
            #expect(card.shared.contains { $0.key == key && $0.value == value }, "\(key)")
        }
        #expect(!card.shared.contains { $0.key == "abnormal_flag" }, "行级键不上浮为共享（孤儿标记丢弃，不误归他行）")
        let row = try #require(card.rows.first)
        #expect(row.fields.contains { $0.key == "abnormal_flag" && $0.value == "↑" } && row.fields.contains { $0.key == "ref_low" && $0.value == "115" })
        let projection = EntityCardProjection.labProjection(from: card.fullyConfirmed(), calendar: utc)
        #expect(projection.samples.first?.abnormalFlag == "↑" && projection.samples.first?.measuredAt == day(2026, 9, 2))
        #expect(projection.header.specimenType == "静脉血" && projection.header.reportedAt == day(2026, 9, 3))
    }

    @Test func 定性检验行拆为项目与结果原文() throws {
        let fields = [f("report_date", "2026-09-03"),
                      f("lab_item", "血红蛋白 150", unit: "g/L"), f("lab_item", "HBsAg 阴性"), f("lab_item", "AFP <0.5", unit: "ng/mL"),
                      f("lab_item", "尿蛋白 +"), f("lab_item", "HBsAg 阴性(-)"), f("lab_item", "ANA ≥1:160"), f("lab_item", "血小板")]
        let card = try #require(CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").first { $0.kind == "metric_sample" })
        func row(_ label: String) -> [String: String] {
            let r = card.rows.first { $0.fields.contains { $0.key == "raw_label" && $0.value == label } }
            return Dictionary((r?.fields ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        #expect(card.rows.count == 7)
        #expect(row("血红蛋白")["value"] == "150" && row("血红蛋白")["unit"] == "g/L")
        #expect(row("HBsAg")["value"] == "阴性" && row("HBsAg")["unit"] == nil)
        #expect(row("AFP")["value"] == "<0.5" && row("AFP")["unit"] == "ng/mL")
        #expect(row("尿蛋白")["value"] == "+")
        #expect(row("ANA")["value"] == "≥1:160")
        #expect(card.rows.contains { $0.fields.contains { $0.key == "raw_label" && $0.value == "HBsAg" } && $0.fields.contains { $0.key == "value" && $0.value == "阴性(-)" } })
        #expect(row("血小板")["value"] == nil, "单词条无结果：不猜")
        let projection = EntityCardProjection.labProjection(from: card.fullyConfirmed(), calendar: utc)
        #expect(projection.samples.count == 1 && projection.qualitative.count == 5 && projection.remainingRows.count == 1)
        #expect(projection.qualitative.map(\.result.resultText) == ["阴性", "<0.5", "+", "阴性(-)", "≥1:160"])
    }

    // MARK: - 6. 理解层：新键、叙事标签、枚举归一、分类器证据词、标签直配

    @Test func 理解层新键允许_叙事键剥已知标签_数值键子串防线() {
        let lines = ["入院日期：2026-01-02", "出院医嘱：低盐饮食", "检查所见：双肺纹理清晰", "Impression: No abnormality", "出院带药：阿司匹林 100mg",
                     "住院总费用：12345.60", "诊疗经过：入院后予抗血小板治疗", "標本類型：靜脈血", "病理诊断：（胃窦）慢性浅表性胃炎"]
        let fields = OCRGrounding.fields([
            .init(key: "admit_at", value: "2026-01-02", lineIndex: 0),
            .init(key: "discharge_orders", value: "低盐饮食", lineIndex: 1),
            .init(key: "discharge_orders", value: "低盐", lineIndex: 1),               // 叙事截断：拒绝
            .init(key: "findings", value: "双肺纹理清晰", lineIndex: 2),
            .init(key: "impression", value: "No abnormality", lineIndex: 3),
            .init(key: "take_home_drugs", value: "阿司匹林 100mg", lineIndex: 4),
            .init(key: "total_cost", value: "2345.60", lineIndex: 5),                  // 数字子串：拒绝
            .init(key: "total_cost", value: "12345.60", lineIndex: 5),
            .init(key: "treatment_course", value: "入院后予抗血小板治疗", lineIndex: 6),
            .init(key: "specimen_type", value: "靜脈血", lineIndex: 7),
            .init(key: "impression", value: "（胃窦）慢性浅表性胃炎", lineIndex: 8),
            .init(key: "critical_value_flag", value: "1", lineIndex: 8),               // 未登记键：拒绝（BR-004/012 越线面）
        ], lines: lines)
        #expect(fields.map(\.key) == ["admit_at", "discharge_orders", "findings", "impression", "take_home_drugs", "total_cost", "treatment_course", "specimen_type", "impression"])
        #expect(fields.first { $0.key == "total_cost" }?.value == "12345.60")
        #expect(fields.allSatisfy { $0.grade == .ocrUnconfirmed })
        for key in ["diagnosis_item", "diagnosis_code", "code_system", "diagnosis_type", "report_type", "exam_part", "exam_method", "exam_at", "reported_at",
                    "apply_doctor", "report_doctor", "review_doctor", "collected_at", "collect_time", "report_time", "test_doctor", "abnormal_flag", "reference_text", "method",
                    "admit_condition", "discharge_condition", "admit_diagnosis", "discharge_diagnosis", "ward", "bed_no", "medical_record_no", "payment_type", "discharge_way"] {
            #expect(OCRGrounding.allowedKeys.contains(key), "\(key)")
        }
        #expect(OCRGrounding.documentTypes.isSuperset(of: ["inpatient_record", "discharge_summary", "day_surgery_record", "emergency_record", "exam_report", "pathology_report", "checkup_report"]))
    }

    @Test func 报告类型与诊断类型词表归一为canonical_raw() {
        for (printed, raw) in [("CT", "ct"), ("胸部CT平扫", "ct"), ("MRI", "mri"), ("磁共振", "mri"), ("X线", "xray"), ("胸片", "xray"), ("彩超", "ultrasound"), ("超聲", "ultrasound"),
                               ("心电图", "ecg"), ("ECG", "ecg"), ("胃镜", "endoscopy"), ("內鏡", "endoscopy"), ("病理", "pathology"), ("PET/CT", "nuclear"), ("核医学", "nuclear"),
                               ("其他", "other"), ("ct", "ct")] {
            #expect(OCRGrounding.normalized(printed, key: "report_type") == raw, "\(printed)")
        }
        #expect(OCRGrounding.normalized("不明", key: "report_type") == "不明", "未知原样透传（invalidFields 交用户复核）")
        for (printed, raw) in [("主要诊断", "primary"), ("主診斷", "primary"), ("Principal Diagnosis", "primary"), ("次要诊断", "secondary"), ("其他诊断", "secondary"),
                               ("入院诊断", "admission"), ("出院诊断", "discharge"), ("术前诊断", "preop"), ("术后诊断", "postop"), ("病理诊断", "pathology"),
                               ("诊断证明", "certificate"), ("discharge", "discharge")] {
            #expect(OCRGrounding.normalized(printed, key: "diagnosis_type") == raw, "\(printed)")
        }
        #expect(OCRGrounding.normalized("临床诊断", key: "diagnosis_type") == "临床诊断")
    }

    @Test func 分类器证据词_住院族与检查族_既有检验判定不漂移() {
        #expect(DocumentTypeClassifierFallback.classify(lines: ["出院小结", "出院诊断：不稳定型心绞痛", "出院医嘱：低盐饮食"]).target == "discharge_summary")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["住院病案首页", "住院号：ZY0001", "入院日期：2026-01-02"]).target == "inpatient_record")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["日间手术入出院记录", "手术日期：2026-03-01"]).target == "day_surgery_record",
                "亚型覆盖：日间手术记录含出院记录证据词，更具体的类型胜出")
        let emergency = DocumentTypeClassifierFallback.classify(lines: ["急诊病历", "主诉：腹痛 2 小时", "诊断：急性胃肠炎"])
        #expect(emergency.target == "emergency_record", "急诊病历共享门诊全部证据词（主诉/诊断），按命中数永输——有「急诊」证据即判急诊")
        #expect(emergency.secondary.contains { $0.key == "outpatient_record" } && emergency.confidence == 0.9, "门诊降为次级候选；置信度沿用共享证据行数")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["门诊病历", "主诉：腹痛 2 小时", "诊断：急性胃肠炎"]).target == "outpatient_record", "无急诊证据不覆盖")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["CT检查报告单", "检查所见：双肺纹理清晰", "印象：未见明显异常"]).target == "exam_report")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["病理检查报告", "镜下所见：…", "病理诊断：慢性浅表性胃炎"]).target == "pathology_report")
        let lab = DocumentTypeClassifierFallback.classify(lines: ["血常规检验报告", "血红蛋白 150 g/L", "参考范围 130-175", "标本：静脉血", "诊断：缺铁性贫血"])
        #expect(lab.target == "lab_report" && lab.confidence == 0.9)
        #expect(DocumentTypeClassifierFallback.classify(lines: ["阿莫西林胶囊 0.25g", "每日三次 每次两粒", "××市第一医院"]).target == "prescription")
    }

    @Test func 标签直配三语_住院检查检验诊断键() {
        let lines = ["入院日期：2026-01-02", "Discharge Date: 2026-01-09", "主治醫師：張三", "檢查部位：胸部", "标本类型：静脉血", "Impression: No abnormality",
                     "出院医嘱：低盐饮食", "主要诊断：高血压 2 级", "CT检查报告单", "报告医师：李四", "采集时间：2026-09-02 08:00", "出院诊断：不稳定型心绞痛",
                     "Findings: Clear lungs", "病区：3 病区", "住院号：ZY0001", "出院带药：阿司匹林 100mg qd", "检验者：王五", "报告时间：2026-09-03"]
        let fields = DocumentTypeClassifierFallback.pageFields(lines: lines, understood: [], confidence: 0.9)
        func value(_ key: String, line: Int) -> String? { fields.first { $0.key == key && $0.sourceLineIndex == line }?.value }
        #expect(value("admit_at", line: 0) == "2026-01-02" && value("discharge_at", line: 1) == "2026-01-09")
        #expect(value("attending_physician", line: 2) == "張三" && value("exam_part", line: 3) == "胸部" && value("specimen_type", line: 4) == "静脉血")
        #expect(value("impression", line: 5) == "No abnormality" && value("discharge_orders", line: 6) == "低盐饮食")
        #expect(value("diagnosis_item", line: 7) == "高血压 2 级" && value("diagnosis_type", line: 7) == "primary", "主/次诊断标签 → 行 + 类型")
        #expect(value("report_type", line: 8) == "ct", "报告标题词表 → canonical raw")
        #expect(value("report_doctor", line: 9) == "李四" && value("collected_at", line: 10) == "2026-09-02 08:00")
        #expect(value("discharge_diagnosis", line: 11) == "不稳定型心绞痛" && value("diagnosis_item", line: 11) == "不稳定型心绞痛" && value("diagnosis_type", line: 11) == "discharge")
        #expect(value("findings", line: 12) == "Clear lungs" && value("ward", line: 13) == "3 病区" && value("medical_record_no", line: 14) == "ZY0001")
        #expect(value("take_home_drugs", line: 15) == "阿司匹林 100mg qd" && value("test_doctor", line: 16) == "王五" && value("reported_at", line: 17) == "2026-09-03")
        #expect(value("report_date", line: 17) != nil, "泛日期仍产出（检验卡 measured_at 来源不变）")
        #expect(!fields.contains { $0.key.hasPrefix("line_") && [0, 1, 3, 4, 5, 6, 7, 8].contains($0.sourceLineIndex ?? -1) })
        #expect(!fields.contains { $0.key == "diagnosis_item" && $0.sourceLineIndex == 8 })
    }

    // MARK: - 7. 诊断行 → 健康问题候选

    @Test func 诊断行派生D级健康问题候选_每行一候选_同名去重_不自动写() {
        let t0 = Date(timeIntervalSince1970: 0)
        let rows = [
            Diagnosis(id: UUID(), patientId: UUID(), ordinal: 0, diagnosisType: "primary", name: "高血压 2 级", codeText: "I10.x02", codeSystemText: "ICD-10",
                      diagnosedAt: day(2026, 1, 9), createdAt: t0, updatedAt: t0),
            Diagnosis(id: UUID(), patientId: UUID(), ordinal: 1, diagnosisType: "secondary", name: "2 型糖尿病", createdAt: t0, updatedAt: t0),
            Diagnosis(id: UUID(), patientId: UUID(), ordinal: 2, diagnosisType: "discharge", name: " 高血压 2 级 ", codeText: "I10", createdAt: t0, updatedAt: t0),
            Diagnosis(id: UUID(), patientId: UUID(), ordinal: 3, diagnosisType: "unspecified", name: "   ", createdAt: t0, updatedAt: t0),
        ]
        let candidates = HealthProblemCandidate.from(diagnoses: rows)
        #expect(candidates.map(\.name) == ["高血压 2 级", "2 型糖尿病"], "每行一候选；同名（去空白）去重保留首见；空名跳过")
        #expect(candidates[0].codeText == "I10.x02" && candidates[0].codeSystemText == "ICD-10" && candidates[0].diagnosedAt == day(2026, 1, 9))
        #expect(candidates[0].diagnosisId == rows[0].id && candidates[1].diagnosisId == rows[1].id, "候选回指来源诊断行（用户采用后由 store 回填 health_problem_id）")
        #expect(candidates[1].codeText == nil && candidates[1].diagnosedAt == nil, "无码不猜码、无日期不猜日期")
        #expect(HealthProblemCandidate.from(diagnoses: []).isEmpty)
    }
}
