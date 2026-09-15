import Foundation

/// FR6.9 V3.66 卡级确认与字段编辑的业务规则（结构轮 2026-09-15）：
/// 自 `MatchedCard`（值模型）与 `EntityCardConfirmView`（视图）收敛为 Domain 纯函数——
/// BR-003 的 D→C 升级谓词此前在三处各写一份（模型两处 + 视图一处），
/// 任一处漂移即「低置信字段被静默升 C」的红线风险（tech-spec §1.1 规则 4）。
public enum CardConfirmationRules {

    /// 卡级一键确认的字段资格：非拒绝、有值（trim 后非空）、非低置信。
    /// 低置信（`ConfidenceTier.low`）仍须逐项复核（FR17.4 强制复核不降级）；
    /// 空字段保持缺失（走补填/待办）；拒绝字段保持拒绝。
    public static func confirmable(_ field: FieldDraft) -> Bool {
        field.grade != .rejected
            && !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ConfidenceTier.tier(field.confidence) != .low
    }

    /// 字段组卡级确认（纯值变换，零 IO）：逐字段按 `confirmable` 升 C。
    public static func confirmedFields(_ fields: [FieldDraft]) -> [FieldDraft] {
        fields.map { field in
            guard confirmable(field) else { return field }
            var copy = field
            _ = copy.confirm()
            return copy
        }
    }

    /// 全卡卡级确认：共享字段 + 逐行字段（`MatchedCard.confirmingAllFields` 的实现主体）。
    public static func confirmingAllFields(_ card: MatchedCard) -> MatchedCard {
        var result = card
        result.shared = confirmedFields(card.shared)
        result.rows = card.rows.map { row in
            var updated = row
            updated.fields = confirmedFields(row.fields)
            return updated
        }
        return result
    }

    /// 卡级确认延伸到主卡草稿（FR6.9 一键确认同纪律）：拒绝字段先移除
    /// （不把用户拒绝的值带进主卡；拒绝日期字段后草稿区重新要求补填），
    /// 其余合格字段升 C。非 `.newHub` 关联原样返回。
    public static func confirmingDraft(_ card: MatchedCard) -> MatchedCard {
        guard case .newHub(var draft) = card.encounterAssociation else { return card }
        draft.fields.removeAll { $0.grade == .rejected }
        draft.fields = confirmedFields(draft.fields)
        var result = card
        result.encounterAssociation = .newHub(draft)
        return result
    }

    // MARK: - 字段编辑策略（自 MatchedCard.reviseField 迁入）

    /// 编辑一个字段（共享或行级）后的关联/编码失效纪律：
    /// - 共享字段：`.suggested` 关联被编辑即回未选择；`.newHub` 草稿的**证据字段**
    ///   （机构/医生/日期，`EncounterResolver.evidenceKeys`）被改即回未选择，
    ///   由关联区按新证据重派生。
    /// - 行级 `metric_sample` 的 `raw_label`/`unit` 被改：整行编码建议失效
    ///   （`clearCodeResolution`）并按新名重算 `metric_key` 草稿。
    /// Row identity survives editing（行 id 不变，修订可回溯）。
    public static func revise(_ card: inout MatchedCard, at index: Int, rowId: UUID? = nil, to value: String) {
        guard let rowId else {
            guard card.shared.indices.contains(index) else { return }
            if case .suggested = card.encounterAssociation { card.encounterAssociation = .unselected }
            if case .newHub = card.encounterAssociation, EncounterResolver.evidenceKeys.contains(card.shared[index].key),
               card.shared[index].value != value { card.encounterAssociation = .unselected }
            card.shared[index].revise(to: value)
            return
        }
        guard let r = card.rows.firstIndex(where: { $0.id == rowId }), card.rows[r].fields.indices.contains(index),
              card.rows[r].fields[index].value != value else { return }
        let key = card.rows[r].fields[index].key
        card.rows[r].fields[index].revise(to: value)
        if card.kind == "metric_sample", key == "raw_label" || key == "unit" {
            if let label = card.rows[r].fields.firstIndex(where: { $0.key == "raw_label" }) {
                card.rows[r].fields[label].clearCodeResolution()
                let name = card.rows[r].fields[label].value.trimmingCharacters(in: .whitespacesAndNewlines)
                for k in card.rows[r].fields.indices where card.rows[r].fields[k].key == "metric_key" {
                    card.rows[r].fields[k].value = name.isEmpty ? "" : "lab.\(name)"
                }
            }
        }
    }
}
