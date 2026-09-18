import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD (BR-003 · recognition-remediation-design §0.3 需求 1)
/// 子项目 D · D4-1「资料建议」Domain 层：已确认卡字段原文 → 个人资料 D 级建议（既往史 / 过敏 / 血型 / 慢性病）。
/// 零推断纪律：整段原文一条建议（不切词）、诊断行逐条、血型只做字形归一（不可辨保留原文）、
/// 否认/无 不产建议、已有资料不重复建议；接受前不落任何表（本层无 IO）。
/// 纯 Domain，Linux 可跑（`refactor/scripts/run-domain-tests.sh`）。
@Suite("D4-1 · ProfileSuggestion 抽取器（零推断）")
struct ProfileSuggestionTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

    private let document = UUID()
    private let patient = UUID()

    /// 测试用留痕闭包：卡类 metric_sample/encounter 等由调用方决定，页号固定 2。
    private func provenance(_ table: String, _ id: UUID, _ key: String) -> ProfileSuggestion.Provenance {
        .init(cardKind: table == "lab_result" ? "metric_sample" : table, entityTable: table, entityId: id, fieldKey: key,
              documentId: document, pageIndex: 2, rowId: id)
    }

    private func lab(_ item: String, _ result: String, id: UUID = UUID()) -> LabResult {
        LabResult(id: id, patientId: patient, labReportId: UUID(), ordinal: 0, itemName: item, resultText: result, createdAt: Date())
    }

    private func narrative(_ key: String, _ text: String, table: String = "encounter", id: UUID = UUID(), at: Date? = nil) -> ProfileSuggestionExtractor.NarrativeField {
        .init(entityTable: table, entityId: id, key: key, text: text, occurredAt: at)
    }

    private func diagnosis(_ name: String, code: String? = nil, at: Date? = nil, id: UUID = UUID()) -> Diagnosis {
        Diagnosis(id: id, patientId: patient, ordinal: 0, name: name, codeText: code, codeSystemText: code == nil ? nil : "ICD-10",
                  diagnosedAt: at, createdAt: Date(), updatedAt: Date())
    }

    private func extract(narratives: [ProfileSuggestionExtractor.NarrativeField] = [], diagnoses: [Diagnosis] = [],
                         labs: [LabResult] = [], existing: ProfileSuggestionExtractor.ProfileSnapshot = .empty) -> [ProfileSuggestion] {
        ProfileSuggestionExtractor.suggestions(narratives: narratives, diagnoses: diagnoses, labResults: labs,
                                               existing: existing, provenance: provenance)
    }

    // MARK: - 1. 血型

    /// 原名：血型行产bloodType建议且其余检验行不产
    @Test func bloodTypeRowYieldsSuggestionOthersDoNot() {
        let abo = UUID()
        let out = extract(labs: [lab("ABO血型", "A", id: abo), lab("血红蛋白", "阴性"), lab("Rh(D)血型", "阳性"),
                                 lab("血型", "A型 RH(D)阳性"), lab("血型抗体筛查", "阴性"), lab("尿蛋白", "±")])
        #expect(out.map(\.kind) == [.bloodType, .bloodType, .bloodType])
        #expect(out.map(\.value) == ["A", "Rh+", "A Rh+"])
        #expect(out[0].provenance.entityTable == "lab_result" && out[0].provenance.entityId == abo && out[0].provenance.fieldKey == "result_text")
        #expect(out[0].provenance.cardKind == "metric_sample" && out[0].provenance.documentId == document && out[0].provenance.pageIndex == 2)
    }

    /// 原名：血型字形归一只做字符映射
    @Test func bloodTypeGlyphNormalizationIsCharacterMappingOnly() {
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "ABO血型", resultText: "AB型") == "AB")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "abo 血型鉴定", resultText: " o ") == "O")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "血型", resultText: "0型") == "O", "OCR 常把 O 读作 0——O 型无「0」歧义")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "Rh因子", resultText: "阴性") == "Rh-")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "RH血型", resultText: "RH(+)") == "Rh+")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "Blood type", resultText: "B Rh negative") == "B Rh-")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "血型", resultText: "A+") == "A Rh+")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "血型", resultText: "AB Rh(D)陰性") == "AB Rh-")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "血红蛋白", resultText: "A") == nil, "非血型行不解释")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "Rheumatoid factor", resultText: "阴性") == nil, "rheum 排除")
        #expect(ProfileSuggestionExtractor.bloodTypeValue(itemName: "血型", resultText: "  ") == nil, "空值零建议")
    }

    /// 原名：血型字形不可辨保留原文
    @Test func ambiguousBloodTypeGlyphKeepsOriginalText() {
        let out = extract(labs: [lab("血型", "详见备注"), lab("血型", "阳性")])
        #expect(out.map(\.value) == ["详见备注", "阳性"], "无 Rh 标签的孤立阳性 = 歧义，不猜 Rh；原文保留由用户裁定")
        #expect(out.allSatisfy { $0.kind == .bloodType })
    }

    // MARK: - 2. 既往史 / 过敏史（整段一条，不切词）

    /// 原名：既往史整段一条建议不切词
    @Test func pastHistoryWholeParagraphSingleSuggestionNoTokenizing() {
        let encounter = UUID()
        let out = extract(narratives: [narrative("past_history", " 高血压病史10年、糖尿病5年，规律服药。", id: encounter, at: day(2026, 3, 1))])
        #expect(out.count == 1)
        #expect(out[0].kind == .pastHistory)
        #expect(out[0].value == "高血压病史10年、糖尿病5年，规律服药。", "只去首尾空白，不切分、不改写")
        #expect(out[0].occurredAt == day(2026, 3, 1))
        #expect(out[0].provenance == provenance("encounter", encounter, "past_history"))
    }

    /// 原名：过敏史整段一条建议
    @Test func allergyHistoryWholeParagraphSingleSuggestion() {
        let out = extract(narratives: [narrative("allergy_history", "青霉素、头孢类过敏（皮疹）")])
        #expect(out.count == 1 && out[0].kind == .allergy)
        #expect(out[0].value == "青霉素、头孢类过敏（皮疹）")
        #expect(out[0].provenance.fieldKey == "allergy_history")
    }

    /// 原名：否认或无不产建议
    @Test func denialOrNoneYieldsNoSuggestion() {
        let negatives = ["无", "無", "无。", "否认药物过敏史", "否認食物過敏", "无特殊", "None", "N/A", "NKDA", "-", "不详", "无药物及食物过敏史", "Denies drug allergy"]
        for text in negatives {
            #expect(extract(narratives: [narrative("allergy_history", text)]).isEmpty, "「\(text)」")
            #expect(extract(narratives: [narrative("past_history", text)]).isEmpty, "「\(text)」")
        }
        // 混合陈述含正向内容：不切词、不判断——整段交给用户裁定
        let mixed = extract(narratives: [narrative("allergy_history", "否认食物过敏，青霉素过敏")])
        #expect(mixed.map(\.value) == ["否认食物过敏，青霉素过敏"])
        // 「无」只做整词匹配：无花果过敏是正向陈述
        #expect(extract(narratives: [narrative("allergy_history", "无花果过敏")]).count == 1)
    }

    /// 原名：未登记叙事键不产建议
    @Test func unregisteredNarrativeKeyYieldsNoSuggestion() {
        #expect(extract(narratives: [narrative("chief_complaint", "咳嗽三天"), narrative("visit_summary", "复诊")]).isEmpty)
    }

    // MARK: - 3. 慢性病候选（诊断行逐条 / 住院诊断原文块整段）

    /// 原名：诊断行逐条chronicCondition
    @Test func eachDiagnosisRowYieldsChronicCondition() {
        let a = UUID(), b = UUID()
        let out = extract(diagnoses: [diagnosis(" 高血压 ", code: "I10", at: day(2026, 1, 2), id: a), diagnosis("2型糖尿病", id: b),
                                      diagnosis("高血压", id: UUID()), diagnosis("   ")])
        #expect(out.map(\.kind) == [.chronicCondition, .chronicCondition])
        #expect(out.map(\.value) == ["高血压", "2型糖尿病"], "同名只保留首见、空名跳过（与 HealthProblemCandidate 同纪律）")
        #expect(out[0].codeText == "I10" && out[0].codeSystemText == "ICD-10" && out[0].occurredAt == day(2026, 1, 2))
        #expect(out[0].provenance.entityTable == "diagnosis" && out[0].provenance.entityId == a && out[0].provenance.fieldKey == "name")
        #expect(out[1].provenance.entityId == b && out[1].codeText == nil)
    }

    /// 原名：住院诊断原文块整段为chronicCondition
    @Test func hospitalizationDiagnosisBlockYieldsChronicCondition() {
        let hosp = UUID()
        let out = extract(narratives: [narrative("discharge_diagnosis_text", "1.高血压 2.2型糖尿病", table: "hospitalization", id: hosp, at: day(2026, 2, 3)),
                                       narrative("admit_diagnosis_text", "无", table: "hospitalization", id: hosp)])
        #expect(out.count == 1 && out[0].kind == .chronicCondition)
        #expect(out[0].value == "1.高血压 2.2型糖尿病", "原文块不拆行——切分是推断")
        #expect(out[0].provenance == provenance("hospitalization", hosp, "discharge_diagnosis_text"))
    }

    // MARK: - 4. 空 / 等级 / Codable

    /// 原名：空字段零建议
    @Test func emptyFieldsYieldNoSuggestion() {
        #expect(extract().isEmpty)
        #expect(extract(narratives: [narrative("past_history", "   \n")], labs: [lab("血型", "")]).isEmpty)
    }

    /// 原名：建议grade恒为ocrUnconfirmed且Codable往返
    @Test func suggestionGradeAlwaysOcrUnconfirmedAndCodableRoundTrip() throws {
        let out = extract(narratives: [narrative("past_history", "哮喘病史")], diagnoses: [diagnosis("过敏性鼻炎", code: "J30")], labs: [lab("血型", "B")])
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.grade == .ocrUnconfirmed })
        let data = try JSONEncoder().encode(out)
        let back = try JSONDecoder().decode([ProfileSuggestion].self, from: data)
        #expect(back == out)
        #expect(back.allSatisfy { $0.grade == .ocrUnconfirmed }, "等级不可被 JSON 改写为 C")
    }

    // MARK: - 5. 去重（已有资料 / 批内）

    /// 原名：已有资料不重复建议
    @Test func existingProfileDataNeverReSuggested() {
        let existing = ProfileSuggestionExtractor.ProfileSnapshot(bloodType: " a型 ", problemNames: ["高血压", "哮喘病史"], allergySubstances: ["青霉素"])
        let out = extract(narratives: [narrative("past_history", "哮喘 病史"), narrative("allergy_history", "青霉素 ")],
                          diagnoses: [diagnosis("高血压 "), diagnosis("2型糖尿病")],
                          labs: [lab("ABO血型", "A"), lab("Rh(D)", "阳性")],
                          existing: existing)
        #expect(out.map(\.value) == ["2型糖尿病", "Rh+"], "大小写/空白/「型」不敏感；Rh 与已记录 ABO 不同值仍建议")
    }

    /// 原名：批内同值只保留首见
    @Test func withinBatchDuplicateKeepsFirstSeenOnly() {
        let first = UUID()
        let out = extract(narratives: [narrative("past_history", "冠心病"), narrative("past_history", "冠心病", id: UUID())],
                          diagnoses: [diagnosis("冠心病")],
                          labs: [lab("ABO血型", "A", id: first), lab("血型", "A型")])
        #expect(out.map(\.value) == ["冠心病", "A"])
        #expect(out[1].provenance.entityId == first)
    }

    /// 原名：去重键稳定且随值变化
    @Test func dedupeKeyStableAndValueDependent() {
        let id = UUID()
        let a = extract(labs: [lab("ABO血型", "A", id: id)])[0]
        let b = extract(labs: [lab("ABO血型", "A", id: id)])[0]
        let c = extract(labs: [lab("ABO血型", "B", id: id)])[0]
        #expect(a.id != b.id, "展示 id 随机（会话内唯一）")
        #expect(a.dedupeKey == b.dedupeKey, "去重键只依赖 kind/来源实体/字段/归一值——跨会话可持久登记「已忽略」")
        #expect(a.dedupeKey != c.dedupeKey)
        #expect(!a.dedupeKey.contains(a.id.uuidString))
    }
}
