import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// 子项目 J · J2（round1 §E.7 V10 / BR-006/007 / BR-004/012）：v27 四卡类（health_exam / clinical_conclusion / surgery / treatment_record）
/// 的 DDL 镜像值类型、注册表条目、模板与最小集规则、理解层键与枚举归一、持久化意图；体检一般检查只投影
/// weight/systolic/diastolic/pulse 四键（严格数值 + 白名单单位）；`severity_text` 只存打印原文。纯 Domain，Linux 可跑。
@Suite("FR6.9 体检卡意图 + v27 四卡注册")
struct HealthExamProjectionTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }
    private func card(_ kind: String, pageIndex: Int = 0, shared: [FieldDraft], rows: [[FieldDraft]] = [[]]) -> MatchedCard {
        MatchedCard(kind: kind, pageIndex: pageIndex, shared: shared, rows: rows.map { MatchedCardRow(fields: $0) },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
    }
    private func f(_ key: String, _ value: String, unit: String? = nil, raw: String? = nil, line: Int? = nil) -> FieldDraft {
        FieldDraft(key: key, value: value, unit: unit, confidence: 0.9, rawText: raw, source: .heuristic, sourceLineIndex: line)
    }

    // MARK: - 1. 体检首页意图（plan 逐字）

    @Test func 一般检查只投影有键且可严格解析的项() throws {
        let card = MatchedCard(kind: "health_exam", pageIndex: 0, shared: [
            .init(key: "org_name", value: "美年体检", grade: .userConfirmed), .init(key: "exam_date", value: "2024-05-06", grade: .userConfirmed),
            .init(key: "height", value: "170", unit: "cm", grade: .userConfirmed), .init(key: "weight", value: "65.5", unit: "kg", grade: .userConfirmed),
            .init(key: "systolic", value: "128", unit: "mmHg", grade: .userConfirmed), .init(key: "diastolic", value: "82", unit: "mmHg", grade: .userConfirmed),
            .init(key: "pulse", value: "约72", unit: "次/分", grade: .userConfirmed), .init(key: "vision_left", value: "1.0", grade: .userConfirmed)],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let intent = try #require(EntityCardProjection.healthExamIntent(from: card, calendar: .init(identifier: .gregorian)))
        #expect(intent.exam.heightText == "170" && intent.exam.pulseText == "约72" && intent.exam.visionLeftText == "1.0", "原文列全部保留")
        #expect(intent.generalSamples.map(\.metricKey).sorted() == ["bloodPressureDia", "bloodPressureSys", "weight"], "身高无键不投；脉搏「约72」非严格数值不投")
        #expect(intent.generalSamples.first { $0.metricKey == "weight" }?.value == 65.5)
        #expect(intent.generalSamples.allSatisfy { $0.healthExamId == intent.exam.id && $0.measuredAt == intent.exam.examDate && $0.refSourceLabel == "美年体检" }, "投影点回指体检枢纽")
        #expect(intent.rowId == card.rows[0].id && intent.exam.id == card.rows[0].id && intent.exam.confirmed == false && intent.exam.source == .ocr)
        #expect(intent.exam.patientId == FactPlaceholder.unassignedId && intent.exam.weightText == "65.5" && intent.exam.systolicText == "128")
    }

    @Test func 一般检查单位越出白名单或非严格十进制不投影_首页字段齐全() throws {
        let full = card("health_exam", pageIndex: 2, shared: [
            f("org_name", "美年体检"), f("exam_no", "TJ001"), f("package_name", "尊享套餐"), f("exam_date", "2024-05-06"), f("total_doctor", "王总检"),
            f("report_date", "2024-05-10"), f("height", "170", unit: "cm"), f("weight", "65.5", unit: "斤"), f("bmi", "22.7"),
            f("systolic", "0x80", unit: "mmHg"), f("diastolic", "82", unit: "毫米汞柱"), f("pulse", "72", unit: "bpm"), f("waist", "80", unit: "cm"),
            f("vision_left", "1.0"), f("vision_right", "0.8"), f("overall_conclusion", "血脂偏高，肝囊肿。"), f("health_guidance", "低脂饮食，定期复查。"),
        ])
        #expect(EntityCardProjection.invalidFields(in: full, row: full.rows[0], calendar: utc).isEmpty)
        let intent = try #require(EntityCardProjection.healthExamIntent(from: full, calendar: utc))
        let exam = intent.exam
        #expect(exam.orgName == "美年体检" && exam.examNo == "TJ001" && exam.packageName == "尊享套餐" && exam.totalDoctor == "王总检")
        #expect(exam.examDate == day(2024, 5, 6) && exam.reportDate == day(2024, 5, 10))
        #expect(exam.bmiText == "22.7" && exam.waistText == "80" && exam.visionRightText == "0.8" && exam.systolicText == "0x80" && exam.weightText == "65.5", "原文列一律保留（BR-006）")
        #expect(exam.overallConclusion == "血脂偏高，肝囊肿。" && exam.healthGuidance == "低脂饮食，定期复查。", "叙事原文不摘要")
        #expect(intent.generalSamples.map(\.metricKey).sorted() == ["bloodPressureDia", "heartRate"], "体重单位「斤」越出白名单不投（不换算，BR-007）；收缩压十六进制不投；腰围/BMI/视力无键不投")
        #expect(intent.generalSamples.first { $0.metricKey == "heartRate" }?.unit == "bpm")
        let badReport = card("health_exam", shared: [f("org_name", "A"), f("exam_date", "2024-05-06"), f("report_date", "五月")])
        #expect(EntityCardProjection.invalidFields(in: badReport, row: badReport.rows[0], calendar: utc) == ["report_date"], "可选日期键出现即须可解析")
        let noDate = card("health_exam", shared: [f("org_name", "A"), f("height", "170", unit: "cm")])
        #expect(EntityCardProjection.invalidFields(in: noDate, row: noDate.rows[0], calendar: utc) == ["exam_date"])
        #expect(EntityCardProjection.healthExamIntent(from: noDate, calendar: utc) == nil, "无日期不落库，不猜")
        #expect(EntityCardProjection.healthExamIntent(from: card("encounter", shared: [f("date", "2024-05-06"), f("kind", "outpatient")]), calendar: utc) == nil, "卡类不符")
    }

    // MARK: - 2. 结论行意图（plan 逐字）

    @Test func 结论行类型由关键词派生默认且可逐行覆盖() throws {
        let card = MatchedCard(kind: "clinical_conclusion", pageIndex: 1, shared: [],
            rows: [MatchedCardRow(fields: [.init(key: "content", value: "建议 3 个月后复查血脂", grade: .userConfirmed)]),
                   MatchedCardRow(fields: [.init(key: "content", value: "肝囊肿", grade: .userConfirmed), .init(key: "conclusion_type", value: "abnormal_finding", grade: .userConfirmed), .init(key: "severity", value: "关注", grade: .userConfirmed)])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let intents = try #require(EntityCardProjection.clinicalConclusionIntents(from: card, calendar: .init(identifier: .gregorian)))
        #expect(intents.map(\.conclusion.conclusionType) == ["recheck_advice", "abnormal_finding"])
        #expect(intents[1].conclusion.severityText == "关注" && intents.map(\.conclusion.ordinal) == [0, 1])
        #expect(intents.map(\.rowId) == card.rows.map(\.id) && intents[0].conclusion.id == card.rows[0].id && intents[0].conclusion.sourceRowId == card.rows[0].id)
        #expect(intents[0].conclusion.sourcePage == 1 && intents[0].conclusion.severityText == nil && intents[0].conclusion.healthExamId == nil, "父键由 store 填")
        #expect(intents[0].conclusion.content == "建议 3 个月后复查血脂" && intents[0].conclusion.patientId == FactPlaceholder.unassignedId)
    }

    @Test func 结论类型关键词派生表_与枚举同拼写_严重度不编码() {
        for (content, type) in [("建议 3 个月后复查血脂", "recheck_advice"), ("建议心内科就诊", "visit_advice"), ("请至专科门诊随诊", "visit_advice"),
                                ("建议低脂饮食", "health_advice"), ("健康指导：规律运动", "health_advice"), ("血脂偏高", "abnormal_finding"),
                                ("HBsAg 阳性", "abnormal_finding"), ("血红蛋白偏低", "abnormal_finding"),
                                ("本次体检总体情况良好", "health_exam_summary")] {
            #expect(ClinicalConclusion.conclusionType(forContent: content) == type, "\(content)")
        }
        #expect(ClinicalConclusion.conclusionTypes == ["lab", "exam", "health_exam_summary", "abnormal_finding", "health_advice", "recheck_advice", "visit_advice"],
                "与 CHECK(conclusion_type IN (…)) 同拼写")
        var c = ClinicalConclusion(patientId: UUID(), healthExamId: UUID(), conclusionType: "abnormal_finding", content: "肝囊肿", severityText: "需复查", ordinal: 0, createdAt: Date(timeIntervalSince1970: 1))
        #expect(c.hasExactlyOneParent)
        c.labReportId = UUID()
        #expect(!c.hasExactlyOneParent, "三外键恰一非空（CHECK）")
        #expect(OCRGrounding.normalized("需复查", key: "severity") == "需复查" && OCRGrounding.normalized("异常", key: "severity") == "异常", "severity 只存打印文本，不归一不编码（BR-004/012）")
        let badType = card("clinical_conclusion", shared: [], rows: [[f("content", "A"), f("conclusion_type", "总检")]])
        #expect(EntityCardProjection.invalidFields(in: badType, row: badType.rows[0], calendar: utc) == ["conclusion_type"], "枚举须 canonical raw（归一在理解层）")
        #expect(EntityCardProjection.clinicalConclusionIntents(from: badType, calendar: utc) == nil)
        let noContent = card("clinical_conclusion", shared: [], rows: [[f("severity", "关注")]])
        #expect(EntityCardProjection.invalidFields(in: noContent, row: noContent.rows[0], calendar: utc) == ["content"])
        let empty = card("clinical_conclusion", shared: [f("org_name", "美年体检")], rows: [])
        #expect(EntityCardProjection.clinicalConclusionIntents(from: empty, calendar: utc) == nil, "空卡不落库")
    }

    // MARK: - 3. 手术 / 治疗意图

    @Test func 手术意图最小集与全列原文() throws {
        let full = card("surgery", pageIndex: 1, shared: [
            f("hospital", "市一医院"), f("department", "普外科"), f("surgery_at", "2024-03-01"), f("ended_at", "2024-03-01"),
            f("surgery_name", "腹腔镜胆囊切除术"), f("surgery_code", "51.2300"), f("surgery_level", "三级"),
            f("surgeon", "张主刀"), f("assistants", "李一助、王二助"), f("anesthesiologist", "赵麻醉"), f("anesthesia_method", "全麻"),
            f("preop_diagnosis", "胆囊结石伴慢性胆囊炎"), f("postop_diagnosis", "胆囊结石伴慢性胆囊炎"),
            f("procedure_course", "常规消毒铺巾…"), f("intraop_findings", "胆囊壁增厚"), f("implants", "无"), f("specimen", "胆囊送病理"),
            f("blood_loss", "约 20ml"), f("transfusion", "无"), f("drainage", "未放置"), f("postop_orders", "禁食 6 小时"), f("complications", "无"),
        ])
        #expect(EntityCardProjection.invalidFields(in: full, row: full.rows[0], calendar: utc).isEmpty)
        let intent = try #require(EntityCardProjection.surgeryIntent(from: full, calendar: utc))
        let s = intent.surgery
        #expect(intent.rowId == full.rows[0].id && s.id == full.rows[0].id && s.surgeryName == "腹腔镜胆囊切除术" && s.surgeryAt == day(2024, 3, 1) && s.endedAt == day(2024, 3, 1))
        #expect(s.hospital == "市一医院" && s.department == "普外科" && s.surgeryCodeText == "51.2300" && s.surgeryLevelText == "三级", "编码/级别只存打印文本")
        #expect(s.surgeon == "张主刀" && s.assistants == "李一助、王二助" && s.anesthesiologist == "赵麻醉" && s.anesthesiaMethod == "全麻")
        #expect(s.preopDiagnosisText == "胆囊结石伴慢性胆囊炎" && s.postopDiagnosisText == "胆囊结石伴慢性胆囊炎")
        #expect(s.procedureCourse == "常规消毒铺巾…" && s.intraopFindings == "胆囊壁增厚" && s.implantsText == "无" && s.specimenText == "胆囊送病理")
        #expect(s.bloodLossText == "约 20ml" && s.transfusionText == "无" && s.drainageText == "未放置" && s.postopOrders == "禁食 6 小时" && s.complicationsText == "无")
        #expect(s.patientId == FactPlaceholder.unassignedId && s.encounterId == nil && s.confirmed == false && s.source == .ocr)
        let noName = card("surgery", shared: [f("surgery_at", "2024-03-01"), f("surgeon", "张")])
        #expect(EntityCardProjection.invalidFields(in: noName, row: noName.rows[0], calendar: utc) == ["surgery_name"])
        #expect(EntityCardProjection.surgeryIntent(from: noName, calendar: utc) == nil)
        let noDate = card("surgery", shared: [f("surgery_name", "阑尾切除术")])
        #expect(EntityCardProjection.invalidFields(in: noDate, row: noDate.rows[0], calendar: utc) == ["surgery_at"], "不猜日期")
        let badEnd = card("surgery", shared: [f("surgery_at", "2024-03-01"), f("surgery_name", "A"), f("ended_at", "上午")])
        #expect(EntityCardProjection.invalidFields(in: badEnd, row: badEnd.rows[0], calendar: utc) == ["ended_at"])
    }

    @Test func 治疗记录意图_类型canonical_内容与药物二择一_药物原文不拆行() throws {
        let infusion = card("treatment_record", shared: [
            f("treatment_type", "infusion"), f("treated_at", "2024-03-02"), f("hospital", "社区医院"), f("department", "输液室"), f("doctor", "王"), f("executor", "李护士"),
            f("diagnosis_text", "急性支气管炎"), f("drugs_text", "0.9% 氯化钠 250ml + 头孢呋辛 1.5g ivgtt 40 滴/分"), f("session", "第 2 次/共 3 次"),
            f("adverse_reaction", "无"), f("result", "顺利完成"), f("note", "观察 30 分钟"),
        ])
        #expect(EntityCardProjection.invalidFields(in: infusion, row: infusion.rows[0], calendar: utc).isEmpty)
        let intent = try #require(EntityCardProjection.treatmentRecordIntent(from: infusion, calendar: utc))
        let t = intent.record
        #expect(intent.rowId == infusion.rows[0].id && t.id == infusion.rows[0].id && t.treatmentType == "infusion" && t.treatedAt == day(2024, 3, 2))
        #expect(t.hospital == "社区医院" && t.department == "输液室" && t.doctor == "王" && t.executor == "李护士" && t.diagnosisText == "急性支气管炎")
        #expect(t.content == nil && t.drugsText == "0.9% 氯化钠 250ml + 头孢呋辛 1.5g ivgtt 40 滴/分", "药名/剂量/滴速原文，不拆行不换算（BR-006/007）")
        #expect(t.sessionText == "第 2 次/共 3 次" && t.adverseReactionText == "无" && t.resultText == "顺利完成" && t.note == "观察 30 分钟")
        #expect(t.allergyEventId == nil && t.encounterId == nil && t.patientId == FactPlaceholder.unassignedId && t.confirmed == false, "过敏事件只由用户显式关联")
        #expect(TreatmentRecord.treatmentTypes == ["infusion", "injection", "physiotherapy", "dressing", "other"])
        let neither = card("treatment_record", shared: [f("treatment_type", "physiotherapy"), f("treated_at", "2024-03-02")])
        #expect(EntityCardProjection.invalidFields(in: neither, row: neither.rows[0], calendar: utc) == ["content"], "content | drugs_text 之一（形态同 exam_report impression ?? findings）")
        #expect(EntityCardProjection.treatmentRecordIntent(from: neither, calendar: utc) == nil)
        let contentOnly = card("treatment_record", shared: [f("treatment_type", "physiotherapy"), f("treated_at", "2024-03-02"), f("content", "腰椎牵引 20 分钟")])
        #expect(EntityCardProjection.treatmentRecordIntent(from: contentOnly, calendar: utc)?.record.content == "腰椎牵引 20 分钟")
        let badType = card("treatment_record", shared: [f("treatment_type", "输液"), f("treated_at", "2024-03-02"), f("content", "A")])
        #expect(EntityCardProjection.invalidFields(in: badType, row: badType.rows[0], calendar: utc) == ["treatment_type"])
        let noDate = card("treatment_record", shared: [f("treatment_type", "injection"), f("content", "A")])
        #expect(EntityCardProjection.invalidFields(in: noDate, row: noDate.rows[0], calendar: utc) == ["treated_at"])
    }

    // MARK: - 4. DDL 镜像值类型 / 读模型 / 预约用途 / 提醒来源

    @Test func 四值类型与读模型Codable往返_枚举与CHECK同拼写() throws {
        let t0 = Date(timeIntervalSince1970: 1), t1 = Date(timeIntervalSince1970: 2)
        let exam = HealthExam(patientId: UUID(), documentFileId: UUID(), orgName: "美年体检", examNo: "TJ001", packageName: "套餐", examDate: day(2024, 5, 6),
                              totalDoctor: "王", reportDate: day(2024, 5, 10), heightText: "170", weightText: "65.5", bmiText: "22.7", systolicText: "128",
                              diastolicText: "82", pulseText: "72", waistText: "80", visionLeftText: "1.0", visionRightText: "0.8",
                              overallConclusion: "良好", healthGuidance: "运动", source: .ocr, confirmed: true, createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(HealthExam.self, from: JSONEncoder().encode(exam)) == exam)
        let minimal = HealthExam(patientId: UUID(), source: .manual, createdAt: t0, updatedAt: t1)
        #expect(minimal.orgName == nil && minimal.confirmed == false && minimal.examDate == nil, "init 全 Optional 带默认 nil（风格同 Hospitalization）")
        let conclusion = ClinicalConclusion(patientId: UUID(), examReportId: UUID(), conclusionType: "exam", content: "未见明显异常", ordinal: 2, sourcePage: 1, sourceRowId: UUID(), createdAt: t0)
        #expect(try JSONDecoder().decode(ClinicalConclusion.self, from: JSONEncoder().encode(conclusion)) == conclusion)
        let surgery = Surgery(patientId: UUID(), encounterId: UUID(), surgeryAt: day(2024, 3, 1), surgeryName: "阑尾切除术", implantsText: "钛夹 ×2", source: .ocr, createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(Surgery.self, from: JSONEncoder().encode(surgery)) == surgery)
        let treatment = TreatmentRecord(patientId: UUID(), treatmentType: "injection", treatedAt: day(2024, 3, 2), drugsText: "破伤风抗毒素 1500IU im", allergyEventId: UUID(), source: .manual, createdAt: t0, updatedAt: t1)
        #expect(try JSONDecoder().decode(TreatmentRecord.self, from: JSONEncoder().encode(treatment)) == treatment)
        let summary = ClinicalReportSummary(reportId: UUID(), patientId: UUID(), reportType: .lab, reportSource: .healthExam, reportDate: day(2024, 5, 6),
                                            orgName: "美年体检", reportNo: "L1", encounterId: nil, healthExamId: UUID(), documentFileId: nil, confirmed: true)
        #expect(try JSONDecoder().decode(ClinicalReportSummary.self, from: JSONEncoder().encode(summary)) == summary)
        #expect(ReportType.allCases.map(\.rawValue) == ["lab", "exam", "health_exam"], "v_clinical_report.report_type 字面量")
        #expect(ReportSource.allCases.map(\.rawValue) == ["outpatient", "emergency", "inpatient", "health_exam"], "report_source CHECK 枚举")
        #expect(AppointmentPurpose.allCases.map(\.rawValue) == ["visit", "followUp", "exam", "healthExam"], "appointment.purpose CHECK 枚举")
        #expect(try JSONDecoder().decode(AppointmentPurpose.self, from: Data(#""followUp""#.utf8)) == .followUp)
    }

    @Test func 提醒来源白名单三表() {
        #expect(ReminderSource.allowedTables == ["encounter", "appointment", "health_exam"])
        #expect(ReminderSource(table: "appointment", id: UUID()).isAllowed && ReminderSource(table: "health_exam", id: UUID()).isAllowed)
        #expect(!ReminderSource(table: "medication_plan", id: UUID()).isAllowed && !ReminderSource(table: "Appointment", id: UUID()).isAllowed, "白名单精确匹配，store 据此拒绝")
        #expect(ReminderSource(validating: "encounter", id: UUID()) != nil && ReminderSource(validating: "reminder", id: UUID()) == nil)
        let source = ReminderSource(table: "encounter", id: UUID())
        #expect(source.hub == .encounter && ReminderSource(table: "health_exam", id: UUID()).hub == .healthExam && ReminderSource(table: "appointment", id: UUID()).hub == nil)
    }

    // MARK: - 5. 注册表 / 模板 / 最小集规则

    @Test func 注册表四条目_模板四条_最小集规则() throws {
        let exam = try #require(CardKindRegistry.entry(for: "health_exam"))
        #expect(exam.entityTables.first == "health_exam" && exam.headerTable == "health_exam" && exam.sharedRequired == ["org_name", "exam_date"] && exam.dateKey == "exam_date")
        #expect(exam.sharedOptional.isSuperset(of: ["exam_no", "package_name", "total_doctor", "report_date", "height", "weight", "bmi", "systolic", "diastolic", "pulse", "waist",
                                                     "vision_left", "vision_right", "overall_conclusion", "health_guidance"]))
        #expect(exam.rowRequired.isEmpty && exam.rowOptional.isEmpty && exam.requiresDocumentType == ["checkup_report"])
        let conclusion = try #require(CardKindRegistry.entry(for: "clinical_conclusion"))
        #expect(conclusion.entityTables == ["clinical_conclusion"] && conclusion.rowRequired == ["content"] && conclusion.rowOptional == ["conclusion_type", "severity"])
        #expect(conclusion.sharedRequired.isEmpty && conclusion.sharedOptional == ["org_name", "exam_date", "exam_no"] && conclusion.dateKey == nil,
                "共享面只带主卡草稿派生所需的机构/日期/编号；结论类型逐行")
        #expect(conclusion.requiresDocumentType == ["checkup_report"])
        let surgery = try #require(CardKindRegistry.entry(for: "surgery"))
        #expect(surgery.entityTables == ["surgery"] && surgery.sharedRequired == ["surgery_at", "surgery_name"] && surgery.dateKey == "surgery_at")
        #expect(surgery.sharedOptional.isSuperset(of: ["hospital", "department", "ended_at", "surgery_code", "surgery_level", "surgeon", "assistants", "anesthesiologist", "anesthesia_method",
                                                        "preop_diagnosis", "postop_diagnosis", "procedure_course", "intraop_findings", "implants", "specimen", "blood_loss", "transfusion",
                                                        "drainage", "postop_orders", "complications"]))
        #expect(surgery.requiresDocumentType == ["surgery_record", "day_surgery_record", "discharge_summary"])
        let treatment = try #require(CardKindRegistry.entry(for: "treatment_record"))
        #expect(treatment.entityTables == ["treatment_record"] && treatment.sharedRequired == ["treated_at", "treatment_type"] && treatment.dateKey == "treated_at")
        #expect(treatment.sharedOptional.isSuperset(of: ["hospital", "department", "doctor", "executor", "diagnosis_text", "content", "drugs_text", "session", "adverse_reaction", "result", "note"]))
        #expect(treatment.requiresDocumentType == ["treatment_record"])
        #expect(CardKindRegistry.entries.map(\.kind).count == Set(CardKindRegistry.entries.map(\.kind)).count, "kind 唯一")
        for kind in ["health_exam", "clinical_conclusion", "surgery", "treatment_record"] {
            let template = try #require(CardTemplateMatcher.ocrTemplates.first { $0.kind == kind }, "\(kind)")
            let entry = try #require(CardKindRegistry.entry(for: kind))
            #expect(template.requiresDocumentType == entry.requiresDocumentType && template.rowLevelKeys.isSubset(of: entry.rowAllowed), "\(kind)")
            #expect(Set(template.mapping.values).isSubset(of: entry.sharedAllowed.union(entry.rowAllowed)), "\(kind): \(Set(template.mapping.values).subtracting(entry.sharedAllowed.union(entry.rowAllowed)))")
            let rules = CompletenessEvaluator.rules(for: kind)
            #expect(!rules.isEmpty && Set(rules.filter(\.isRequired).map(\.key)) == entry.sharedRequired.union(entry.rowRequired), "\(kind) 规则表 required = 注册表最小集")
        }
        #expect(CardTemplateMatcher.ocrTemplates.first { $0.kind == "clinical_conclusion" }?.rowKey == "conclusion_item", "结论页为行模板")
        #expect(CardTemplateMatcher.ocrTemplates.first { $0.kind == "health_exam" }?.rowKey == nil && CardTemplateMatcher.ocrTemplates.first { $0.kind == "surgery" }?.rowKey == nil)
        // 目录与门槛分离：既有金样分母不动
        #expect(CompletenessEvaluator.rules(for: "metric_sample").count == 8 && CompletenessEvaluator.rules(for: "encounter").count == 6 && CompletenessEvaluator.rules(for: "exam_report").count == 6)
        #expect(CardKindRegistry.optionalCatalog(kind: "health_exam", present: ["org_name", "height"], rowLevel: false).contains("waist"))
        #expect(!CardKindRegistry.optionalCatalog(kind: "health_exam", present: ["org_name", "height"], rowLevel: false).contains("height"))
    }

    // MARK: - 6. 模板匹配（体检首页 / 结论页 / 手术 / 治疗）

    @Test func 体检首页出体检卡_血压拆收缩舒张_仅体检文档() throws {
        let raw = "血压：128/82 mmHg"
        let fields = [f("org_name", "美年体检"), f("exam_no", "TJ001"), f("exam_date", "2024-05-06"), f("package_name", "尊享套餐"),
                      f("height", "170", unit: "cm"), f("weight", "65.5", unit: "kg"), f("blood_pressure", "128/82", unit: "mmHg", raw: raw),
                      f("pulse", "72", unit: "次/分"), f("overall_conclusion", "血脂偏高"), f("overall_conclusion", "肝囊肿"), f("health_guidance", "低脂饮食")]
        let cards = CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "checkup_report")
        let exam = try #require(cards.first { $0.kind == "health_exam" })
        #expect(exam.rows.count == 1 && exam.rows[0].fields.isEmpty, "单行卡：表头即实体")
        #expect(exam.shared.contains { $0.key == "systolic" && $0.value == "128" && $0.unit == "mmHg" } && exam.shared.contains { $0.key == "diastolic" && $0.value == "82" && $0.unit == "mmHg" },
                "「128/82」按打印分隔拆两列（同 reference_range 拆分纪律），不猜不换算")
        #expect(!exam.shared.contains { $0.key == "blood_pressure" })
        #expect(exam.shared.first { $0.key == "overall_conclusion" }?.value == "血脂偏高\n肝囊肿", "总检结论多段并入同键")
        #expect(exam.shared.contains { $0.key == "weight" && $0.unit == "kg" } && exam.requiredCoverage == 1)
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: "lab_report").contains { $0.kind == "health_exam" }, "仅体检报告文档出体检卡")
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 0, documentTypeKey: nil).contains { $0.kind == "health_exam" })
        #expect(!cards.contains { $0.kind == "encounter" || $0.kind == "hospitalization" }, "体检文档不出就诊/住院卡")
        let intent = try #require(EntityCardProjection.healthExamIntent(from: exam.confirmingAllFields(), calendar: utc))
        #expect(intent.generalSamples.map(\.metricKey).sorted() == ["bloodPressureDia", "bloodPressureSys", "heartRate", "weight"])
        let plain = ClinicalFieldLabels.splitBloodPressure("128/82"), wide = ClinicalFieldLabels.splitBloodPressure("128／82 mmHg")
        #expect(plain?.0 == "128" && plain?.1 == "82" && wide?.0 == "128" && wide?.1 == "82")
        #expect(ClinicalFieldLabels.splitBloodPressure("128") == nil && ClinicalFieldLabels.splitBloodPressure("正常") == nil)
    }

    @Test func 结论页每条一行_同行严重度归行_共享机构日期随卡() throws {
        let fields = [f("org_name", "美年体检"), f("exam_date", "2024-05-06"),
                      f("conclusion_item", "血脂偏高", raw: "1. 血脂偏高  关注", line: 3), f("severity", "关注", raw: "1. 血脂偏高  关注", line: 3),
                      f("conclusion_item", "建议 3 个月后复查血脂", raw: "2. 建议 3 个月后复查血脂", line: 4),
                      f("conclusion_item", "肝囊肿", raw: "3. 肝囊肿 需复查", line: 5), f("conclusion_type", "abnormal_finding", raw: "3. 肝囊肿 需复查", line: 5)]
        let card = try #require(CardTemplateMatcher.match(fields: fields, pageIndex: 1, documentTypeKey: "checkup_report").first { $0.kind == "clinical_conclusion" })
        #expect(card.rows.count == 3)
        #expect(card.rows[0].fields.contains { $0.key == "content" && $0.value == "血脂偏高" } && card.rows[0].fields.contains { $0.key == "severity" && $0.value == "关注" })
        #expect(card.rows[1].fields.map(\.key) == ["content"], "第二行不借用他行严重度")
        #expect(card.rows[2].fields.contains { $0.key == "conclusion_type" && $0.value == "abnormal_finding" })
        #expect(card.shared.contains { $0.key == "org_name" && $0.value == "美年体检" } && card.shared.contains { $0.key == "exam_date" && $0.value == "2024-05-06" }, "主卡草稿派生所需共享字段随卡携带")
        #expect(card.requiredCoverage == 1)
        let intents = try #require(EntityCardProjection.clinicalConclusionIntents(from: card.confirmingAllFields(), calendar: utc))
        #expect(intents.map(\.conclusion.conclusionType) == ["abnormal_finding", "recheck_advice", "abnormal_finding"] && intents[0].conclusion.severityText == "关注")
        #expect(!CardTemplateMatcher.match(fields: fields, pageIndex: 1, documentTypeKey: "exam_report").contains { $0.kind == "clinical_conclusion" }, "本轮结论卡只从体检文档产出")
    }

    @Test func 手术与治疗文书出卡_仅对应文档类型() throws {
        let surgeryFields = [f("hospital", "市一医院"), f("surgery_at", "2024-03-01"), f("surgery_name", "腹腔镜胆囊切除术"), f("surgeon", "张"), f("anesthesia_method", "全麻"),
                             f("postop_diagnosis", "胆囊结石"), f("report_date", "2024-03-05")]
        let surgery = try #require(CardTemplateMatcher.match(fields: surgeryFields, pageIndex: 0, documentTypeKey: "surgery_record").first { $0.kind == "surgery" })
        #expect(surgery.rows.count == 1 && surgery.shared.contains { $0.key == "surgery_name" } && surgery.requiredCoverage == 1)
        #expect(!surgery.shared.contains { $0.key == "surgery_at" && $0.value == "2024-03-05" }, "泛日期不冒充手术日期")
        #expect(CardTemplateMatcher.match(fields: surgeryFields, pageIndex: 0, documentTypeKey: "discharge_summary").contains { $0.kind == "surgery" }, "出院小结手术段")
        #expect(!CardTemplateMatcher.match(fields: surgeryFields, pageIndex: 0, documentTypeKey: "outpatient_record").contains { $0.kind == "surgery" })
        #expect(EntityCardProjection.surgeryIntent(from: surgery.confirmingAllFields(), calendar: utc)?.surgery.anesthesiaMethod == "全麻")
        let treatmentFields = [f("treatment_type", "infusion"), f("report_date", "2024-03-02"), f("hospital", "社区医院"), f("drugs_text", "0.9% NS 250ml + 头孢呋辛 1.5g")]
        let treatment = try #require(CardTemplateMatcher.match(fields: treatmentFields, pageIndex: 0, documentTypeKey: "treatment_record").first { $0.kind == "treatment_record" })
        #expect(treatment.shared.contains { $0.key == "treated_at" && $0.value == "2024-03-02" }, "单日期文书：泛日期即治疗日期（同处方/票据纪律）")
        #expect(EntityCardProjection.treatmentRecordIntent(from: treatment.confirmingAllFields(), calendar: utc)?.record.drugsText == "0.9% NS 250ml + 头孢呋辛 1.5g")
        #expect(!CardTemplateMatcher.match(fields: treatmentFields, pageIndex: 0, documentTypeKey: "prescription").contains { $0.kind == "treatment_record" })
        #expect(!CardTemplateMatcher.match(fields: treatmentFields, pageIndex: 0, documentTypeKey: "treatment_record").contains { $0.kind == "prescription" }, "输液药物不成处方卡")
    }

    // MARK: - 7. 理解层：新键、叙事、枚举归一、标签直配、分类器证据

    @Test func 理解层新键允许_叙事键不截断_枚举归一() {
        let lines = ["总检结论：血脂偏高，肝囊肿。", "健康指导：低脂饮食，定期复查。", "手术经过：常规消毒铺巾", "输液药物：0.9% 氯化钠 250ml + 头孢呋辛 1.5g", "体重：65.5 kg", "并发症：无"]
        let fields = OCRGrounding.fields([
            .init(key: "overall_conclusion", value: "血脂偏高，肝囊肿。", lineIndex: 0),
            .init(key: "overall_conclusion", value: "血脂偏高", lineIndex: 0),                        // 叙事截断：拒绝
            .init(key: "health_guidance", value: "低脂饮食，定期复查。", lineIndex: 1),
            .init(key: "procedure_course", value: "常规消毒铺巾", lineIndex: 2),
            .init(key: "drugs_text", value: "0.9% 氯化钠 250ml + 头孢呋辛 1.5g", lineIndex: 3),
            .init(key: "drugs_text", value: "头孢呋辛 1.5g", lineIndex: 3),                            // 药物原文截断：拒绝（BR-006）
            .init(key: "weight", value: "65.5", unit: "kg", lineIndex: 4),
            .init(key: "complications", value: "无", lineIndex: 5),
            .init(key: "severity_level", value: "2", lineIndex: 5),                                   // 未登记键：拒绝（BR-004/012 越线面）
        ], lines: lines)
        #expect(fields.map(\.key) == ["overall_conclusion", "health_guidance", "procedure_course", "drugs_text", "weight", "complications"])
        for key in ["org_name", "exam_no", "package_name", "exam_date", "total_doctor", "height", "weight", "bmi", "blood_pressure", "systolic", "diastolic", "pulse", "waist",
                    "vision_left", "vision_right", "overall_conclusion", "health_guidance", "conclusion_item", "conclusion_type", "severity",
                    "surgery_at", "ended_at", "surgery_name", "surgery_code", "surgery_level", "surgeon", "assistants", "anesthesiologist", "anesthesia_method",
                    "preop_diagnosis", "postop_diagnosis", "procedure_course", "intraop_findings", "implants", "specimen", "blood_loss", "transfusion", "drainage",
                    "postop_orders", "complications", "treatment_type", "treated_at", "executor", "content", "drugs_text", "session", "adverse_reaction", "result"] {
            #expect(OCRGrounding.allowedKeys.contains(key), "\(key)")
        }
        for (printed, raw) in [("检验结论", "lab"), ("檢查結論", "exam"), ("总检", "health_exam_summary"), ("异常发现", "abnormal_finding"), ("健康建议", "health_advice"),
                               ("复查建议", "recheck_advice"), ("就医建议", "visit_advice"), ("Recheck", "recheck_advice"), ("recheck_advice", "recheck_advice")] {
            #expect(OCRGrounding.normalized(printed, key: "conclusion_type") == raw, "\(printed)")
        }
        for (printed, raw) in [("输液", "infusion"), ("靜脈輸液", "infusion"), ("注射", "injection"), ("肌注", "injection"), ("理疗", "physiotherapy"), ("物理治療", "physiotherapy"),
                               ("换药", "dressing"), ("Dressing", "dressing"), ("其他", "other"), ("infusion", "infusion")] {
            #expect(OCRGrounding.normalized(printed, key: "treatment_type") == raw, "\(printed)")
        }
        #expect(OCRGrounding.normalized("雾化", key: "treatment_type") == "雾化", "未知原样透传（invalidFields 交用户复核）")
    }

    @Test func 标签直配三语_体检结论手术治疗键_结论标签成行() {
        let lines = ["体检编号：TJ001", "體檢日期：2024-05-06", "总检医师：王", "身高：170 cm", "體重：65.5 kg", "血压：128/82 mmHg", "脉搏：72 次/分", "腰围：80 cm",
                     "总检结论：血脂偏高", "健康指导：低脂饮食", "检验结论：白细胞偏高", "复查建议：3 个月后复查血脂", "Surgeon: Dr. Zhang", "手术名称：腹腔镜胆囊切除术",
                     "麻醉方式：全麻", "植入物：钛夹 ×2", "治疗类型：输液", "執行者：李護士", "不良反应：无"]
        let fields = DocumentTypeClassifierFallback.pageFields(lines: lines, understood: [], confidence: 0.9)
        func value(_ key: String, line: Int) -> String? { fields.first { $0.key == key && $0.sourceLineIndex == line }?.value }
        func unit(_ key: String, line: Int) -> String? { fields.first { $0.key == key && $0.sourceLineIndex == line }?.unit }
        #expect(value("exam_no", line: 0) == "TJ001" && value("exam_date", line: 1) == "2024-05-06" && value("total_doctor", line: 2) == "王")
        #expect(value("height", line: 3) == "170" && unit("height", line: 3) == "cm" && value("weight", line: 4) == "65.5" && unit("weight", line: 4) == "kg",
                "一般检查「数值 单位」按打印拆值/单位槽位（同 lab_item 纪律），不换算")
        #expect(value("blood_pressure", line: 5) == "128/82" && unit("blood_pressure", line: 5) == "mmHg")
        #expect(value("pulse", line: 6) == "72" && unit("pulse", line: 6) == "次/分" && value("waist", line: 7) == "80" && unit("waist", line: 7) == "cm")
        #expect(ClinicalFieldLabels.splitNumberUnit("约72") == nil && ClinicalFieldLabels.splitNumberUnit("22.7")?.unit == nil && ClinicalFieldLabels.splitNumberUnit("22.7")?.value == "22.7",
                "非数值开头原文整段保留；无单位仅取数值")
        #expect(value("overall_conclusion", line: 8) == "血脂偏高" && value("health_guidance", line: 9) == "低脂饮食")
        #expect(value("conclusion_item", line: 8) == nil && value("conclusion_item", line: 9) == nil, "首页叙事块不重复成结论行")
        #expect(value("conclusion_item", line: 10) == "白细胞偏高" && value("conclusion_type", line: 10) == "lab", "结论标签 → 行 + 标签自带类型")
        #expect(value("conclusion_item", line: 11) == "3 个月后复查血脂" && value("conclusion_type", line: 11) == "recheck_advice")
        #expect(value("surgeon", line: 12) == "Dr. Zhang" && value("surgery_name", line: 13) == "腹腔镜胆囊切除术" && value("anesthesia_method", line: 14) == "全麻" && value("implants", line: 15) == "钛夹 ×2")
        #expect(value("treatment_type", line: 16) == "infusion", "枚举值经 normalized 单出口归一")
        #expect(value("executor", line: 17) == "李護士" && value("adverse_reaction", line: 18) == "无")
        #expect(ClinicalFieldLabels.narrativeLabels.isSuperset(of: ["总检结论", "健康指导", "手术经过", "术中所见", "输液药物", "不良反应", "檢驗結論"]), "叙事剥标签用的已知标签同源")
    }

    @Test func 分类器证据词_手术与治疗文书_既有判定不漂移() {
        #expect(DocumentTypeClassifierFallback.classify(lines: ["手术记录", "手术名称：腹腔镜胆囊切除术", "术者：张"]).target == "surgery_record")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["门诊输液记录单", "输液药物：0.9% NS 250ml", "执行者：李"]).target == "treatment_record")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["出院小结", "出院诊断：胆囊结石", "出院医嘱：低脂饮食", "手术名称：腹腔镜胆囊切除术"]).target == "discharge_summary", "出院小结内的手术段不夺主类")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["体检报告", "总检结论：血脂偏高", "健康指导：低脂饮食"]).target == "checkup_report")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["阿莫西林胶囊 0.25g", "每日三次 每次两粒", "××市第一医院"]).target == "prescription")
        #expect(DocumentTypeClassifierFallback.classify(lines: ["血常规检验报告", "血红蛋白 150 g/L", "参考范围 130-175", "标本：静脉血"]).target == "lab_report")
    }
}
