import Foundation
import Testing
@testable import Domain

/// BR-003 卡级确认与编辑策略（结构轮 2026-09-15）：FR6.9 V3.66 D→C 谓词的单一事实源——
/// 此前模型两处 + 视图一处各写一份，本套件钉住谓词边界与编辑失效纪律。
@Suite("SU-FR6.9 · 卡级确认规则与编辑策略")
struct CardConfirmationRulesTests {

    private func field(_ key: String, _ value: String, confidence: Double = 0.9,
                       grade: SourceGrade = .ocrUnconfirmed, unit: String? = nil) -> FieldDraft {
        FieldDraft(key: key, value: value, unit: unit, confidence: confidence, grade: grade)
    }

    private func card(_ shared: [FieldDraft], rows: [MatchedCardRow] = [MatchedCardRow(fields: [])],
                      association: EncounterAssociation = .unselected) -> MatchedCard {
        MatchedCard(kind: "encounter", pageIndex: 0, shared: shared, rows: rows,
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
                    encounterAssociation: association)
    }

    @Test("confirmable：非拒绝 + 有值 + 非低置信才合格")
    func 确认谓词边界() {
        #expect(CardConfirmationRules.confirmable(field("hospital", "市一院")))
        #expect(!CardConfirmationRules.confirmable(field("hospital", "市一院", grade: .rejected)), "拒绝字段不升 C")
        #expect(!CardConfirmationRules.confirmable(field("hospital", "   ")), "空白值不算有值")
        #expect(!CardConfirmationRules.confirmable(field("hospital", "市一院", confidence: 0.4)), "低置信仍须逐项复核（FR17.4）")
        #expect(CardConfirmationRules.confirmable(field("hospital", "市一院", confidence: 0.5)), "中置信合格")
    }

    @Test("confirmingAllFields：只升合格字段，拒绝/空/低置信原样")
    func 卡级确认() {
        let card = card([field("hospital", "市一院"), field("doctor", "张三", confidence: 0.4),
                         field("department", ""), field("date", "2024-03-01", grade: .rejected)])
        let confirmed = CardConfirmationRules.confirmingAllFields(card)
        #expect(confirmed.shared[0].isConfirmed)
        #expect(!confirmed.shared[1].isConfirmed, "低置信不升")
        #expect(!confirmed.shared[2].isConfirmed, "空字段保持缺失")
        #expect(confirmed.shared[3].grade == .rejected, "拒绝保持拒绝")
    }

    @Test("confirmingDraft：拒绝字段移除、合格升 C；非 newHub 原样")
    func 主卡草稿确认() {
        let draft = HubDraft(hub: .encounter,
                             fields: [field("hospital", "市一院"), field("doctor", "张三", grade: .rejected)],
                             evidence: "hospital")
        let confirmed = CardConfirmationRules.confirmingDraft(card([], association: .newHub(draft)))
        guard case .newHub(let out) = confirmed.encounterAssociation else {
            Issue.record("关联类型不应改变"); return
        }
        #expect(out.fields.map { $0.key } == ["hospital"], "拒绝字段不随草稿进主卡")
        #expect(out.fields[0].isConfirmed)

        let untouched = card([field("hospital", "市一院")])
        #expect(CardConfirmationRules.confirmingDraft(untouched) == untouched, "非 newHub 零变换")
    }

    @Test("编辑纪律：.suggested 被编辑即回未选择")
    func 编辑使建议失效() {
        var c = card([field("hospital", "市一院")], association: .suggested(UUID(), evidence: "hospital"))
        CardConfirmationRules.revise(&c, at: 0, to: "市二院")
        #expect(c.encounterAssociation == .unselected)
        #expect(c.shared[0].value == "市二院")
    }

    @Test("编辑纪律：metric_sample 行 raw_label 被改为整行编码失效 + metric_key 重算")
    func 编辑使编码失效() {
        let row = MatchedCardRow(fields: [field("raw_label", "血红蛋白"), field("value", "150"),
                                          field("metric_key", "lab.旧名")])
        var c = MatchedCard(kind: "metric_sample", pageIndex: 0, shared: [], rows: [row],
                            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        CardConfirmationRules.revise(&c, at: 0, rowId: row.id, to: "白细胞")
        #expect(c.rows[0].fields[0].value == "白细胞")
        #expect(c.rows[0].fields[2].value == "lab.白细胞", "metric_key 按新名重算")
        #expect(c.rows[0].fields[0].codeResolution == nil, "编码建议已清")
    }
}
