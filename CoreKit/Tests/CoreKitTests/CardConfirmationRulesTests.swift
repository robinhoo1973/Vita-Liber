import Foundation
import Testing
@testable import Domain

/// BR-003 卡级确认与编辑策略（结构轮 2026-09-15）：FR6.9 D→C 谓词的单一事实源——
/// 此前模型两处 + 视图一处各写一份，本套件钉住谓词边界与编辑失效纪律。
/// 2026-09-17 判据改判：四条件（非拒绝/有值/≥0.6/无歧义/非必填）+ 用户手填即确认。
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

    @Test("confirmable：非拒绝 + 有值 + 置信 ≥0.6 + 无歧义 + **非必填**（2026-09-17 四条件）")
    func 确认谓词边界() {
        #expect(CardConfirmationRules.confirmable(field("hospital", "市一院"), isRequired: false))
        #expect(!CardConfirmationRules.confirmable(field("hospital", "市一院", grade: .rejected), isRequired: false),
                "拒绝字段不升 C")
        #expect(!CardConfirmationRules.confirmable(field("hospital", "   "), isRequired: false), "空白值不算有值")

        // 置信门槛 0.6（业主 2026-09-17 定；原实现排除 `ConfidenceTier.low`，即 ≥0.5）
        #expect(!CardConfirmationRules.confirmable(field("hospital", "市一院", confidence: 0.59), isRequired: false),
                "低于 0.6 不参与批量")
        #expect(CardConfirmationRules.confirmable(field("hospital", "市一院", confidence: 0.6), isRequired: false),
                "0.6 达标（下界闭）")

        // 必填字段必须逐一确认——**即使高置信也不得被批量盖过**（业主同日定）
        #expect(!CardConfirmationRules.confirmable(field("date", "2026-09-16", confidence: 0.99), isRequired: true),
                "必填高置信也不参与批量")
    }

    @Test("confirmingAllFields：必填与低置信均不参与批量；拒绝/空原样")
    func 卡级确认() {
        // encounter 的 sharedRequired = {date, kind}（CardKindRegistry 单一事实源）
        let card = card([field("hospital", "市一院"),
                         field("doctor", "张三", confidence: 0.4),
                         field("department", ""),
                         field("date", "2024-03-01", grade: .rejected),
                         field("kind", "outpatient")])
        let confirmed = CardConfirmationRules.confirmingAllFields(card)
        #expect(confirmed.shared[0].isConfirmed, "可选 + 置信达标 → 参与批量")
        #expect(!confirmed.shared[1].isConfirmed, "置信 0.4 < 0.6 → 不参与批量")
        #expect(!confirmed.shared[2].isConfirmed, "空字段保持缺失")
        #expect(confirmed.shared[3].grade == .rejected, "拒绝保持拒绝")
        #expect(confirmed.shared[4].grade != .userConfirmed, "必填 kind 不参与批量——必须逐一确认")
    }

    @Test("requiredFieldsAwaitingConfirmation：如实报出还有哪些必填待逐一确认（UI 计数用）")
    func 必填待确认计数() {
        let card = card([field("hospital", "市一院"), field("date", "2026-09-16"), field("kind", "outpatient")])
        let awaiting = CardConfirmationRules.requiredFieldsAwaitingConfirmation(card)
        #expect(Set(awaiting) == ["date", "kind"], "hospital 可选，不在列；实得 \(awaiting)")

        var done = card
        for index in done.shared.indices where done.shared[index].key == "date" { _ = done.shared[index].confirm() }
        #expect(CardConfirmationRules.requiredFieldsAwaitingConfirmation(done) == ["kind"], "已确认的必填出列")
    }

    @Test("requiredFieldsAwaitingConfirmation（全卡）：共享 + 各行必填，跨行去重保序")
    func 全卡必填待确认计数() {
        let rows = [MatchedCardRow(fields: [field("raw_label", "血红蛋白"), field("value", "150")]),
                    MatchedCardRow(fields: [field("raw_label", "白细胞")])]
        let lab = MatchedCard(kind: "metric_sample", pageIndex: 0,
                              shared: [field("measured_at", "2026-09-16")], rows: rows,
                              allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
                              encounterAssociation: .unselected)
        #expect(CardConfirmationRules.requiredFieldsAwaitingConfirmation(lab) == ["measured_at", "raw_label", "value"],
                "共享在前、行内按序、跨行同键只报一次")
    }

    // MARK: - 复核队列（2026-09-17 借鉴批：按风险排序，不按文档顺序）

    @Test("reviewQueue：缺(0) → 必填未确认(1) → 低置信未确认(3)；可选达标与已确认不入列")
    func 复核队列排序() {
        let base = card([field("kind", "outpatient"),
                         field("doctor", "张三", confidence: 0.4),
                         field("department", "呼吸内科")])
        let queue = CardConfirmationRules.reviewQueue(base)
        #expect(queue.map { "\($0.severity):\($0.key)" } == ["0:date", "1:kind", "3:doctor"],
                "缺 → 必填未确认 → 低置信（department 可选达标、不入列）；实得 \(queue.map { "\($0.severity):\($0.key)" })")
    }

    @Test("reviewQueue：行级字段与行内缺键同样入列；歧义(2) 排在低置信(3) 之前")
    func 复核队列行级与歧义() {
        var ambiguous = field("hospital", "市一院")
        ambiguous.candidates = [FieldDraft.Candidate(value: "市一院", confidence: 0.9),
                                FieldDraft.Candidate(value: "市二院", confidence: 0.8)]
        let rows = [MatchedCardRow(fields: [field("raw_label", "血红蛋白"), field("value", "", confidence: 1)])]
        let lab = MatchedCard(kind: "metric_sample", pageIndex: 0,
                              shared: [field("measured_at", "2026-09-16"), ambiguous], rows: rows,
                              allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
                              encounterAssociation: .unselected)
        let queue = CardConfirmationRules.reviewQueue(lab)
        #expect(queue.map(\.severity) == [0, 1, 1, 2], "行内空必填(0) 最前、必填未确认(1)×2、歧义(2)；实得 \(queue.map { "\($0.severity):\($0.key)" })")
        #expect(queue.first?.key == "value" && queue.first?.rowId != nil, "缺的那项定位到具体行（UI 据此跳转）")
        #expect(queue.first?.isMissing == true, "I 类 = 需补填（与低置信分属两条路）")
    }

    @Test("reviewQueue：已确认/已拒绝的字段不出列（拒绝不是待复核，是已裁决）")
    func 复核队列排除已裁决() {
        var rejected = field("doctor", "张三")
        rejected.reject()
        var done = field("kind", "outpatient")
        _ = done.confirm()
        var date = field("date", "2026-09-16")
        _ = date.confirm()
        let base = card([date, done, rejected, field("department", "呼吸内科", confidence: 0.3)])
        let queue = CardConfirmationRules.reviewQueue(base)
        #expect(queue.map(\.key) == ["department"], "只剩低置信未确认——已确认与已拒绝都不在复核清单；实得 \(queue.map(\.key))")
    }

    // MARK: - 用户手填即确认（业主 2026-09-17 裁定：仅限**原值为空**的字段）

    /// 缺失必填「点此填写」追加的就是这个形态（`EntityCardConfirmView.appendField`）。
    private func emptyField(_ key: String) -> FieldDraft { FieldDraft(key: key, value: "", confidence: 1) }

    @Test("fillByUser：原值为空的字段，用户填入即确认（不必再点一次）")
    func 手填即确认() {
        var draft = emptyField("date")
        _ = draft.fillByUser("2026-09-16")
        #expect(draft.isConfirmed, "无机器值可核对 → 用户填入即 C")
        #expect(draft.grade == .userConfirmed)
        #expect(draft.revisionHistory.count == 1, "修订留痕照记（可回溯）")
    }

    @Test("fillByUser：机器已有值的字段，改动仍「改动即失效、需重新确认」")
    func 改机器值不升C() {
        var draft = field("date", "2026-09-16")
        _ = draft.confirm()
        _ = draft.fillByUser("2026-09-17")
        #expect(!draft.isConfirmed, "改了两字符 ≠ 整个字段核对过（不对称是有意的）")
        #expect(draft.grade == .ocrUnconfirmed)
    }

    @Test("fillByUser：清空不升 C；拒绝字段不因手填升 C")
    func 手填守卫() {
        var draft = emptyField("date")
        _ = draft.fillByUser("2026-09-16")
        _ = draft.fillByUser("")
        #expect(!draft.isConfirmed, "空值没有可确认的内容（confirm 的守卫在）")

        var rejected = emptyField("date")
        rejected.reject()
        _ = rejected.fillByUser("2026-09-16")
        #expect(!rejected.isConfirmed, "手填不绕过拒绝守卫——升 C 必须另经 reenable + confirm（UI 上拒绝字段只读）")
    }

    @Test("卡确认面写值走 fillByUser：缺失必填补填后即有效（闸门不再说它无效）")
    func 卡确认面手填即确认() {
        // encounter 卡：kind 已确认、date 缺失（「缺少 日期，点此填写」），用户补填
        var kind = field("kind", "outpatient")
        _ = kind.confirm()
        var base = self.card([kind])
        base.shared.append(emptyField("date"))
        var target = base
        CardConfirmationRules.revise(&target, at: target.shared.count - 1, to: "2026-09-16")
        #expect(target.shared.last?.isConfirmed == true, "用户手填的必填不再卡在未确认")
        let invalid = EntityCardProjection.invalidFields(in: target, row: target.rows[0],
                                                         calendar: Calendar(identifier: .gregorian))
        #expect(invalid.isEmpty, "补填后该行有效——这正是新规则下保存闸门放行的机制；实得 \(invalid)")
    }

    // MARK: - 多候选：待定歧义必须显式选择（2026-09-17 业主裁定「挡」）

    private func multiCandidate(_ key: String) -> FieldDraft {
        var draft = field(key, "2026-09-16")
        draft.candidates = [
            FieldDraft.Candidate(value: "2026-09-16", confidence: 0.9, rawText: "就诊时间 2026-09-16", sourceLineIndex: 1),
            FieldDraft.Candidate(value: "2026-09-01", confidence: 0.7, rawText: "出生日期 2026-09-01", sourceLineIndex: 2),
        ]
        return draft
    }

    @Test("多候选未选择 → 不参与批量确认；选定任一候选 → 可确认")
    func 待定歧义挡住批量确认() {
        var draft = multiCandidate("date")
        #expect(draft.hasUnresolvedCandidates, "两候选且未选择 = 待定歧义")
        #expect(!CardConfirmationRules.confirmable(draft, isRequired: false), "有歧义就必须做选择，不得让默认值溜过去")

        draft.chooseCandidate(draft.candidates[1])
        #expect(!draft.hasUnresolvedCandidates, "选择后歧义消解")
        #expect(draft.value == "2026-09-01", "选定值写入")
        #expect(CardConfirmationRules.confirmable(draft, isRequired: false), "消歧后可参与批量确认")
    }

    @Test("选定候选写值 → 字段退回未确认（BR-003：换了值必须重新确认）")
    func 选候选使字段退回未确认() {
        var draft = multiCandidate("date")
        _ = draft.confirm()
        #expect(draft.isConfirmed)
        draft.chooseCandidate(draft.candidates[1])
        #expect(!draft.isConfirmed, "换值即退回未确认——消歧与确认是两步")
        #expect(draft.grade == .ocrUnconfirmed)
    }

    @Test("单候选字段零影响（绝大多数字段的既有行为不变）")
    func 单候选零影响() {
        var single = field("hospital", "市一院")
        #expect(!single.hasUnresolvedCandidates)
        #expect(CardConfirmationRules.confirmable(single, isRequired: false))
        single.candidates = [FieldDraft.Candidate(value: "市一院", confidence: 0.9)]
        #expect(!single.hasUnresolvedCandidates, "仅一个候选不算歧义")
        #expect(CardConfirmationRules.confirmable(single, isRequired: false))
    }

    @Test("多候选编解码：往返保真；旧草稿无此键 → 空候选集（向后兼容）")
    func 多候选编解码() throws {
        let encoder = JSONEncoder(); let decoder = JSONDecoder()
        let draft = multiCandidate("date")
        let restored = try decoder.decode(FieldDraft.self, from: try encoder.encode(draft))
        #expect(restored.candidates == draft.candidates, "候选集往返保真")
        #expect(restored.candidates[0].rawText == "就诊时间 2026-09-16", "候选带原文行（用户据此判断语义）")

        // 单候选字段编码后**不含** candidates 键 → 既有信封与金样不受影响
        let plain = try encoder.encode(field("hospital", "市一院"))
        let json = String(decoding: plain, as: UTF8.self)
        #expect(!json.contains("candidates"), "空候选集不写出，编码形态逐字不变")

        // 旧草稿（无该键）解码 → 空集 + 未消歧
        let legacy = #"{"key":"hospital","value":"市一院","confidence":0.9,"grade":"ocrUnconfirmed","originalValue":"市一院","revisionHistory":[]}"#
        let legacyDraft = try decoder.decode(FieldDraft.self, from: Data(legacy.utf8))
        #expect(legacyDraft.candidates.isEmpty)
        #expect(!legacyDraft.candidateChosen)
        #expect(CardConfirmationRules.confirmable(legacyDraft, isRequired: false), "旧数据行为不变")
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
