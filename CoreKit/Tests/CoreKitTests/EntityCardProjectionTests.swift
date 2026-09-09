import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// FR6.9 V3.61：已确认的实体卡 → 持久化意图（纯 Domain）。日期解析、行级必填跳过、
/// 参考范围随行、编码只在有确认建议时回填（BR-003/FR25.11）。
@Suite("SU-M2-PENDINGCARD · 实体卡持久化投影")
struct EntityCardProjectionTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private func reviewed(_ card: MatchedCard) -> MatchedCard {
        var result = card
        for i in result.shared.indices { _ = result.shared[i].confirm() }
        for r in result.rows.indices {
            for f in result.rows[r].fields.indices { _ = result.rows[r].fields[f].confirm() }
        }
        return result
    }

    private func laboratoryCard() -> MatchedCard {
        MatchedCard(kind: "metric_sample", pageIndex: 0,
                    shared: [FieldDraft(key: "measured_at", value: "2026-09-01")],
                    rows: [MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "A"),
                        FieldDraft(key: "value", value: "12"), FieldDraft(key: "unit", value: "g/L")])],
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
    }

    @Test func unreviewedFieldsNeverProjectAsFacts() {
        #expect(EntityCardProjection.hospitalSamples(from: laboratoryCard(), calendar: utc).samples.isEmpty)
    }

    @Test func currentValuesOverrideStaleMissingFlags() {
        var card = reviewed(laboratoryCard())
        card.rows[0].missingRequired = ["unit"]
        #expect(EntityCardProjection.hospitalSamples(from: card, calendar: utc).samples.count == 1)
    }

    @Test func codingRequiresExplicitCurrentApproval() {
        var card = reviewed(laboratoryCard())
        let code = CodeResolution(conceptId: "c-a", canonicalCode: "123-4", codingSystem: .loinc,
                                  displayZhHans: "A", displayEn: "A", kind: .metric,
                                  canonicalUnit: "g/L", matchedVia: .curated, confidence: 1)
        card.rows[0].fields[0].codeResolution = code
        card.rows[0].fields.append(FieldDraft(key: "metric_key", value: "code.stale"))
        #expect(EntityCardProjection.hospitalSamples(from: card, calendar: utc).samples.first?.metricKey == "lab.A")
        let approved = card.rows[0].fields[0].approveCode(unit: "g/L")
        #expect(approved)
        #expect(EntityCardProjection.hospitalSamples(from: card, calendar: utc).samples.first?.codeConceptId == "c-a")
        card.rows[0].fields[2].value = "mg/L"
        _ = card.rows[0].fields[2].confirm()
        #expect(EntityCardProjection.hospitalSamples(from: card, calendar: utc).samples.first?.metricKey == "lab.A")
        card.rows[0].fields[0].value = "B"
        _ = card.rows[0].fields[0].confirm()
        #expect(card.rows[0].fields[0].codeResolution == nil)
        #expect(EntityCardProjection.hospitalSamples(from: card, calendar: utc).samples.first?.metricKey == "lab.B")
    }

    @Test(arguments: [("inf", "20"), ("20", "10"), ("abc", "20")])
    func invalidReferenceBoundsRemainDrafts(low: String, high: String) {
        var card = laboratoryCard()
        card.rows[0].fields += [FieldDraft(key: "ref_low", value: low), FieldDraft(key: "ref_high", value: high)]
        #expect(EntityCardProjection.hospitalSamples(from: reviewed(card), calendar: utc).samples.isEmpty)
    }

    @Test func prescriptionDateAndAdviceArePreservedAndInvalidDateRejected() {
        var card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [FieldDraft(key: "prescribed_at", value: "2020-01-02"),
                     FieldDraft(key: "advice_text", value: "Original reviewed advice")],
            rows: [MatchedCardRow(fields: [FieldDraft(key: "drug_name", value: "Drug A")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let intent = EntityCardProjection.prescriptionIntent(from: reviewed(card))
        #expect(intent?.adviceText.contains("Original reviewed advice") == true)
        #expect(intent?.adviceText.contains("Drug A") == true)
        #expect(intent?.prescribedAt != nil)
        card.shared[0].value = "not a date"
        #expect(EntityCardProjection.prescriptionIntent(from: reviewed(card)) == nil)
    }

    @Test func OCR日期三种写法解析到当日零点() {
        let expected = utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        for text in ["2026-09-01", "2026/9/1", "2026年9月1日", "日期：2026-09-01"] {
            #expect(EntityCardProjection.parseDate(text, calendar: utc) == expected, "\(text)")
        }
        #expect(EntityCardProjection.parseDate("昨天", calendar: utc) == nil)
        #expect(EntityCardProjection.parseDate("2026-13-40", calendar: utc) == nil)
    }

    @Test func 检验卡投影为医院样本_缺必填行跳过_参考范围随行() {
        let card = MatchedCard(kind: "metric_sample", pageIndex: 1,
            shared: [FieldDraft(key: "measured_at", value: "2026-09-01"), FieldDraft(key: "hospital", value: "市一医院")],
            rows: [MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "血红蛋白"), FieldDraft(key: "metric_key", value: "lab.血红蛋白"),
                                           FieldDraft(key: "value", value: "150"), FieldDraft(key: "unit", value: "g/L"),
                                           FieldDraft(key: "ref_low", value: "130"), FieldDraft(key: "ref_high", value: "175")]),
                   MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "红细胞"), FieldDraft(key: "metric_key", value: "lab.红细胞"),
                                           FieldDraft(key: "value", value: "4.5")], missingRequired: ["unit"]),
                   MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "坏值"), FieldDraft(key: "metric_key", value: "lab.坏值"),
                                           FieldDraft(key: "value", value: "abc"), FieldDraft(key: "unit", value: "x")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let projection = EntityCardProjection.hospitalSamples(from: reviewed(card), calendar: utc)
        #expect(projection.samples.count == 1)
        #expect(projection.skippedRows == 2, "缺单位行与非数值行都跳过，不阻断其他行")
        let sample = projection.samples[0]
        #expect(sample.rawLabel == "血红蛋白")
        #expect(sample.value == 150)
        #expect(sample.unit == "g/L")
        #expect(sample.refLow == 130 && sample.refHigh == 175)
        #expect(sample.refSourceLabel == "市一医院")
        #expect(sample.codeConceptId == nil, "无用户确认的编码建议不回填")
        #expect(sample.measuredAt == utc.date(from: DateComponents(year: 2026, month: 9, day: 1)))
    }

    @Test func 检验卡无有效日期时全部跳过() {
        let card = MatchedCard(kind: "metric_sample", pageIndex: 0, shared: [],
            rows: [MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "血糖"), FieldDraft(key: "metric_key", value: "lab.血糖"),
                                           FieldDraft(key: "value", value: "5.6"), FieldDraft(key: "unit", value: "mmol/L")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let projection = EntityCardProjection.hospitalSamples(from: card, calendar: utc)
        #expect(projection.samples.isEmpty && projection.skippedRows == 1)
    }

    @Test func 就诊卡投影为就诊草稿() {
        let patient = UUID()
        let card = MatchedCard(kind: "encounter", pageIndex: 0,
            shared: [FieldDraft(key: "date", value: "2026年9月1日"), FieldDraft(key: "kind", value: "outpatient"),
                     FieldDraft(key: "department", value: "心内科"), FieldDraft(key: "diagnosis_text", value: "高血压 2 级"),
                     FieldDraft(key: "advice_text", value: "低盐饮食")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let draft = EntityCardProjection.encounterDraft(from: reviewed(card), patientId: patient, calendar: utc)
        #expect(draft?.patientId == patient)
        #expect(draft?.kind == EncounterKind.outpatient.rawValue)
        #expect(draft?.department == "心内科")
        #expect(draft?.diagnosisText == "高血压 2 级")
        #expect(draft?.adviceText == "低盐饮食")
        #expect(draft?.date == utc.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let noDate = MatchedCard(kind: "encounter", pageIndex: 0, shared: [FieldDraft(key: "department", value: "内科")],
                                 rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        #expect(EntityCardProjection.encounterDraft(from: noDate, patientId: patient, calendar: utc) == nil)
    }

    @Test func 处方卡投影为医嘱文本与医院医生() {
        let card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [FieldDraft(key: "hospital", value: "市一医院"), FieldDraft(key: "doctor", value: "张医生"),
                     FieldDraft(key: "prescribed_at", value: "2026-09-01")],
            rows: [MatchedCardRow(fields: [FieldDraft(key: "drug_name", value: "阿莫西林胶囊")]),
                   MatchedCardRow(fields: [FieldDraft(key: "drug_name", value: "布洛芬")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let intent = EntityCardProjection.prescriptionIntent(from: reviewed(card))
        #expect(intent?.hospital == "市一医院")
        #expect(intent?.doctor == "张医生")
        #expect(intent?.adviceText == "阿莫西林胶囊\n布洛芬")
    }

    @Test func 卡转确认字段保留行序与页号无关() {
        let card = MatchedCard(kind: "metric_sample", pageIndex: 2,
            shared: [FieldDraft(key: "measured_at", value: "2026-09-01", confidence: 0.6, rawText: "日期：2026-09-01")],
            rows: [MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "A", confidence: 0.6, rawText: "A 1 g/L")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let fields = EntityCardProjection.candidateFields(from: card, labelFor: { "L:" + $0 })
        #expect(fields.map(\.key) == ["measured_at", "raw_label"])
        #expect(fields[0].displayLabel == "L:measured_at")
        #expect(fields[1].rawText == "A 1 g/L")
    }
}
