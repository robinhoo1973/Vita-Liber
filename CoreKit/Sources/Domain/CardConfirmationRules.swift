import Foundation

/// FR6.9 V3.66 卡级确认与字段编辑的业务规则（结构轮 2026-09-15）：
/// 自 `MatchedCard`（值模型）与 `EntityCardConfirmView`（视图）收敛为 Domain 纯函数——
/// BR-003 的 D→C 升级谓词此前在三处各写一份（模型两处 + 视图一处），
/// 任一处漂移即「低置信字段被静默升 C」的红线风险（tech-spec §1.1 规则 4）。
public enum CardConfirmationRules {

    /// 卡级批量确认的**置信下限**（业主 2026-09-17 定：0.6）。
    ///
    /// 与 `ConfidenceTier` 的三档（≥0.8 高 / ≥0.5 中 / 其余低）**刻意不同源**：
    /// 那是**展示**分档（随设计调整），这是**资格**门槛（安全边界）。合并会
    /// 让一次设计调整顺手改动安全门槛。
    public static let confirmAllConfidenceFloor = 0.6

    /// 卡级一键确认的字段资格（业主 **2026-09-17** 定案四条件）：
    ///
    /// **非拒绝 ∧ 有值 ∧ 置信 ≥ 0.6 ∧ 无待定歧义 ∧ 非必填**
    ///
    /// 1. **置信门槛 0.6**（原为排除 `ConfidenceTier.low`，即 ≥0.5）——业主定：
    ///    置信度是**模型自评**，不是安全代理；卡级动作虽是一次显式用户确认，
    ///    但**不得盖过模型自评偏低的字段**，0.6 是「可托付给一次轻点」的下限。
    /// 2. **必填字段必须逐一确认**（业主同日定）：必填集 = 建卡最小集
    ///    （与 FR6.9 的 0.8 必填门槛同源），是卡片成立的前提，**不参与批量**——
    ///    逐个确认才成立。
    /// 3. **待定歧义必须选择**：有 ≥2 候选且用户未显式选择时不得批量
    ///    （业主同日裁定「挡」——有歧义就得做选择，不能让默认胜出值溜过去）。
    ///
    /// ⚠️ 必填的判定需要卡片上下文（`CardKindRegistry` 的必填集），故本谓词
    /// 显式接收 `isRequired`——由 `confirmingAllFields` 按面（共享/行）注入。
    ///
    /// ⚠️ **UI 前置（必须项）**：现行确认页只在「非卡级模式或低置信」时渲染逐项
    /// `[确认]`（`DocumentImportConfirmView.swift` 的 `FieldConfirmRow`）。必填字段若
    /// 置信 ≥0.6 且处于卡级模式，**逐项确认入口不存在**——那么「必填必须逐一确认」
    /// 会变成「卡片永远无法保存」。故本改版**必须**同时补上必填字段的逐项确认入口
    /// 与「还有 N 项必填待确认」的可读计数，否则不得上线。
    public static func confirmable(_ field: FieldDraft, isRequired: Bool) -> Bool {
        guard field.grade != .rejected else { return false }
        guard !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard field.confidence >= confirmAllConfidenceFloor else { return false }
        guard !field.hasUnresolvedCandidates else { return false }
        return !isRequired
    }

    /// 字段组卡级确认（纯值变换，零 IO）：逐字段按 `confirmable(_:isRequired:)` 升 C。
    /// `requiredKeys` 为该面（共享或行）的**必填集**——由调用方按卡类注入。
    public static func confirmedFields(_ fields: [FieldDraft], requiredKeys: Set<String>) -> [FieldDraft] {
        fields.map { field in
            guard confirmable(field, isRequired: requiredKeys.contains(field.key)) else { return field }
            var copy = field
            _ = copy.confirm()
            return copy
        }
    }

    /// 全卡卡级确认：共享字段 + 逐行字段（`MatchedCard.confirmingAllFields` 的实现主体）。
    /// 必填集自 `CardKindRegistry` 单一事实源取（与 `EntityCardProjection.invalidFields` 同源）。
    public static func confirmingAllFields(_ card: MatchedCard) -> MatchedCard {
        let entry = CardKindRegistry.entry(for: card.kind)
        var result = card
        result.shared = confirmedFields(card.shared, requiredKeys: entry?.sharedRequired ?? [])
        result.rows = card.rows.map { row in
            var updated = row
            // 空行 = 「表头即实体」：不受行级必填约束（与 `invalidFields` 同口径）
            let required = (entry?.allowsEmptyRows == true && row.fields.isEmpty)
                ? [] : (entry?.rowRequired ?? [])
            updated.fields = confirmedFields(row.fields, requiredKeys: required)
            return updated
        }
        return result
    }

    /// 卡级确认延伸到主卡草稿（FR6.9 一键确认同纪律）：拒绝字段先移除
    /// （不把用户拒绝的值带进主卡；拒绝日期字段后草稿区重新要求补填），
    /// 其余合格字段升 C。非 `.newHub` 关联原样返回。
    /// 草稿的必填集按**其枢纽**取：`RecordHub` 的 raw 值即 `CardKindRegistry` 的 kind。
    public static func confirmingDraft(_ card: MatchedCard) -> MatchedCard {
        guard case .newHub(var draft) = card.encounterAssociation else { return card }
        draft.fields.removeAll { $0.grade == .rejected }
        let required = CardKindRegistry.entry(for: draft.hub.rawValue)?.sharedRequired ?? []
        draft.fields = confirmedFields(draft.fields, requiredKeys: required)
        var result = card
        result.encounterAssociation = .newHub(draft)
        return result
    }

    /// 卡级确认**之前**，指定面（共享；或给定行）还有哪些必填字段待用户逐一确认。
    /// 与 `confirmable` 同一判据：必填 **且** 尚未确认的字段键。
    public static func requiredFieldsAwaitingConfirmation(_ card: MatchedCard, row: MatchedCardRow?) -> [String] {
        let entry = CardKindRegistry.entry(for: card.kind)
        var out: [String] = []
        for field in card.shared where (entry?.sharedRequired ?? []).contains(field.key) && !field.isConfirmed {
            out.append(field.key)
        }
        if let row {
            let required = (entry?.allowsEmptyRows == true && row.fields.isEmpty) ? [] : (entry?.rowRequired ?? [])
            for field in row.fields where required.contains(field.key) && !field.isConfirmed {
                out.append(field.key)
            }
        }
        return out
    }

    /// 全卡（共享 + 全部行）仍未确认的必填键，去重保序——保存闸门的「还有 N 项必填待确认」
    /// 与注意力路由用（单面查询走上面的 `row:` 重载）。
    public static func requiredFieldsAwaitingConfirmation(_ card: MatchedCard) -> [String] {
        var out = requiredFieldsAwaitingConfirmation(card, row: nil)
        for row in card.rows {
            for key in requiredFieldsAwaitingConfirmation(card, row: row) where !out.contains(key) {
                out.append(key)
            }
        }
        return out
    }

    // MARK: - 字段编辑策略（自 MatchedCard.reviseField 迁入）

    /// 编辑一个字段（共享或行级）后的关联/编码失效纪律：
    /// - 共享字段：`.suggested` 关联被编辑即回未选择；`.newHub` 草稿的**证据字段**
    ///   （机构/医生/日期，`EncounterResolver.evidenceKeys`）被改即回未选择，
    ///   由关联区按新证据重派生。
    /// - 行级 `metric_sample` 的 `raw_label`/`unit` 被改：整行编码建议失效
    ///   （`clearCodeResolution`）并按新名重算 `metric_key` 草稿。
    /// Row identity survives editing（行 id 不变，修订可回溯）。
    ///
    /// 写值走 `FieldDraft.fillByUser`（业主 2026-09-17 裁定）：**原值为空的字段**（无机器值可核对，
    /// 用户清空重填或补填缺失必填）写入即记 C；机器已有值仍"改动即失效、需重新确认"。
    /// 本方法是卡确认面唯一的用户编辑入口（实体卡 + 主卡草稿同经此路）。
    public static func revise(_ card: inout MatchedCard, at index: Int, rowId: UUID? = nil, to value: String) {
        guard let rowId else {
            guard card.shared.indices.contains(index) else { return }
            if case .suggested = card.encounterAssociation { card.encounterAssociation = .unselected }
            if case .newHub = card.encounterAssociation, EncounterResolver.evidenceKeys.contains(card.shared[index].key),
               card.shared[index].value != value { card.encounterAssociation = .unselected }
            card.shared[index].fillByUser(value)
            return
        }
        guard let r = card.rows.firstIndex(where: { $0.id == rowId }), card.rows[r].fields.indices.contains(index),
              card.rows[r].fields[index].value != value else { return }
        let key = card.rows[r].fields[index].key
        card.rows[r].fields[index].fillByUser(value)
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
