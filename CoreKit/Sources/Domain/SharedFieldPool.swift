import Foundation

/// 跨卡共用信息的汇集与回填（业主 2026-09-17 定：确认流程改两步——先共用信息，再逐卡行级）。
///
/// **为什么需要它**：同一页的多张卡各自持有共用字段的**副本**——`matchPages` 对每个模板各建一张卡，
/// 而 `FieldDraft` 是值类型。于是处方卡上确认过的日期，在收费卡上仍是 D：同一件事确认 N 遍。
///
/// **入池规则（业主原话拆解，A ∨ B）**：
///
/// - **A 跨卡重复**：该键被 **≥2 张不同的卡**携带——无论置信度。重复本身即重复劳动的来源。
/// - **B 重要且未达确认门**：键属该卡**必填集**（建卡最小集＝身份键 + 检验数值）
///   且（置信 < `CardConfirmationRules.confirmAllConfidenceFloor` **∨ 该键在共享面缺席**）。
///   哪怕只被一张卡携带也入池——缺席者按空值入池，供用户在**本页**补填，
///   而不是留到卡级（业主：不能进入卡级处理）。
///
/// **归并**：同键**同值**的多个承载方合并为一行（处方/检验/收费同一个日期＝一行）；
/// 同键不同值各成一行，各自标注承载卡——不强行合并，也不丢信息。
///
/// **出池即回填**（`project`）：确认后的值写回**每个承载方**（各卡共享面/行内 + 主卡草稿），
/// 卡级步骤因此只剩行级内容。回填走 `revise`（留修订痕）+ `confirm`，不改动承载方自己的
/// `originalValue`/`rawText`（来源与锚定是承载方的，不能被合并行覆盖）。
public enum SharedFieldPool {

    /// 2026-09-19 审查修复（业主诉求「日期未纳入公共字段」）：各卡日期键名不同
    /// （date/prescribed_at/measured_at/exam_at/exam_date/treated_at/diagnosed_at/
    /// surgery_at/administered_at），规则①「≥2 张卡携带**同键**」逐字比较恒不成立——
    /// 同页处方日期与收费日期永不合并入池。日期键归并为单一概念键参与
    /// 汇集/回填（行键仍取首个承载方的实际键，回填按承载方各自的键）。
    static func conceptKey(_ key: String) -> String {
        dateConceptKeys.contains(key) ? "shared_date" : key
    }
    private static let dateConceptKeys: Set<String> = [
        "date", "prescribed_at", "measured_at", "exam_at", "exam_date",
        "treated_at", "diagnosed_at", "surgery_at", "administered_at",
    ]

    /// 承载方：哪张卡的哪个面持有该键。
    public struct Carrier: Hashable, Sendable {
        public enum Face: Hashable, Sendable {
            case shared
            case row(UUID)
            /// 主卡草稿（`.newHub`）——它同样重复持有日期/医院/类型。
            case hubDraft
        }
        public let cardId: UUID
        public let face: Face
        public init(cardId: UUID, face: Face) { self.cardId = cardId; self.face = face }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let key: String
        public let value: String
        public let unit: String?
        /// 本行的待确认草稿（用户在本页的编辑落在它上面，出池时回填给全部承载方）。
        public var field: FieldDraft
        public let carriers: [Carrier]
        /// 承载方 → 该方自己的键（日期概念合并时各卡键名不同；回填用）。
        /// 2026-09-19 审查修复新增。
        public let keysByCarrier: [Carrier: String]
        /// 入池原因（UI 如实呈现，不自造理由）。
        public let repeatedAcrossCards: Bool
        public let criticalLowConfidence: Bool
        /// 该键在本行的承载方里是否为必填（决定能否「处理完」离场）。
        public let required: Bool
        /// 稳定 id：键 + 首个承载方（**不含值**——用户改值不能让行身份漂移）。
        public var id: String {
            let first = carriers.first
            return "\(key)@\(first?.cardId.uuidString ?? "-")@\(first.map { "\($0.face)" } ?? "-")"
        }
    }

    // MARK: - 汇集

    /// 汇集本会话的共用信息行。`floor` 为确认门（默认 0.6，单一事实源在 `CardConfirmationRules`）。
    public static func rows(cards: [MatchedCard],
                            floor: Double = CardConfirmationRules.confirmAllConfidenceFloor) -> [Row] {
        let slots = collectSlots(cards: cards)
        let multiCard = cards.count >= 2

        // 归并：概念键 → 值+单位 → 承载方集合（2026-09-19 日期键经 conceptKey 归一，
        // 跨卡同名不同键的日期合并）。同时按**原始键**累计携带卡数（规则①的
        // 「同键 ≥2 卡」原文语义——SharedFieldPoolTests 钉死：同键不同值各成一行）。
        var order: [String] = []
        var byKey: [String: [String: [Slot]]] = [:]
        var cardCountsByRawKey: [String: Set<UUID>] = [:]
        for slot in slots {
            let valueKey = "\(slot.value)\u{1}\(slot.unit ?? "")"
            if byKey[slot.poolKey] == nil { byKey[slot.poolKey] = [:]; order.append(slot.poolKey) }
            byKey[slot.poolKey]?[valueKey, default: []].append(slot)
            cardCountsByRawKey[slot.key, default: []].insert(slot.carrier.cardId)
        }

        var out: [Row] = []
        for key in order {
            guard let groups = byKey[key] else { continue }
            // 审查修复（非确定性输出）：原比较器只比 `value`，而 groups 的键是
            // 「value\u{1}unit」——两条 value 文本相同但单位不同的组（如同一分析物
            // 在一页化验单上分别以 mmol/L 与 mg/dL 打印）在两个方向上都判定为 false，
            // 即**非全序**；Swift 的 sorted 不保证稳定，于是这两行的相对次序退化为
            // Dictionary 每进程随机的遍历序 → 同一输入在每次启动下产出不同的
            // 共用信息确认页行序（快照/金样测试随之闪断）。
            // 补上唯一的键作为最终次序键，构成全序。
            for (_, group) in groups.sorted(by: {
                let av = $0.value.first?.value ?? ""
                let bv = $1.value.first?.value ?? ""
                return av == bv ? $0.key < $1.key : av < bv
            }) {
                guard let head = group.first else { continue }
                let required = group.contains(where: \.required)
                let lowConfidence = group.contains { $0.field.confidence < floor }
                let missing = head.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // 规则①跨卡重复的两半（2026-09-19 审查修复）：
                // ① 同**原始键** ≥2 卡——同键不同值各成一行（测试钉死）；
                // ② 概念归并（日期键）同**值** ≥2 卡——跨键同值合并行须确认。
                // 旧实现按**概念键**累计卡数：处方日期与收费日期**不同值**也互判
                // 重复、补位空槽把「仅一张卡有日期」抬成重复（虚假标记 + 无谓确认闸）。
                let sameRawKeyRepeated = group.contains { (cardCountsByRawKey[$0.key]?.count ?? 0) >= 2 }
                let sameValueRepeated = Set(group.map(\.carrier.cardId)).count >= 2
                let repeated = multiCard && (sameRawKeyRepeated || sameValueRepeated)
                // 三条析取（规格 2026-09-17 定稿）：① 跨卡重复 ② 必填 ∧ 低置信（单卡也入）
                // ③ 必填 ∧ 缺失 ∧ **多卡**——单卡的缺失/空值留在卡内（业主：「单卡的卡内操作」）
                let critical = required && (lowConfidence || (missing && multiCard))
                guard repeated || critical else { continue }
                // 行键 = 首个承载方的实际键（UI/L10n 沿用它）；回填按承载方各自的键（keysByCarrier）。
                // 同一承载方同面出现多个日期概念键时首个胜出（值已同值合并，实践无差）。
                var keysByCarrier: [Carrier: String] = [:]
                for slot in group where keysByCarrier[slot.carrier] == nil {
                    keysByCarrier[slot.carrier] = slot.key
                }
                out.append(Row(key: head.key, value: head.value, unit: head.unit, field: head.field,
                               carriers: group.map(\.carrier).sorted { "\($0.face)" < "\($1.face)" },
                               keysByCarrier: keysByCarrier,
                               repeatedAcrossCards: repeated, criticalLowConfidence: critical, required: required))
            }
        }
        return out
    }

    /// 汇集阶段：各卡共享面 / 行内 / 主卡草稿摊平成槽位（含共享面缺席的必填键空值补位）。
    private static func collectSlots(cards: [MatchedCard]) -> [Slot] {
        var slots: [Slot] = []
        for card in cards {
            let entry = CardKindRegistry.entry(for: card.kind)
            let sharedRequired = Set(entry?.sharedRequired ?? [])

            for field in card.shared where field.grade != .rejected && field.key != "card_kind" {
                slots.append(Slot(key: field.key, value: field.value, unit: field.unit, field: field,
                                  carrier: Carrier(cardId: card.id, face: .shared),
                                  poolKey: Self.conceptKey(field.key),
                                  required: sharedRequired.contains(field.key)))
            }
            // 共享面**缺席**的必填键：按空值入池，供本页补填（业主 2026-09-17：
            // 「如果多个信息卡，缺失的关键字段也要加在公用字段修正页面」——多卡才有重复代价，
            // 单卡保持原路（卡内「缺少 X，点此填写」），不为此多开一页）。
            let presentShared = Set(card.shared.map(\.key))
            if cards.count >= 2 {
                for key in sharedRequired where !presentShared.contains(key) {
                    let empty = FieldDraft(key: key, value: "", confidence: 1)
                    slots.append(Slot(key: key, value: "", unit: nil, field: empty,
                                      carrier: Carrier(cardId: card.id, face: .shared),
                                      poolKey: Self.conceptKey(key), required: true))
                }
            }

            for row in card.rows {
                let rowRequired = Set((entry?.allowsEmptyRows == true && row.fields.isEmpty) ? [] : (entry?.rowRequired ?? []))
                for field in row.fields where field.grade != .rejected && field.key != "metric_key" {
                    slots.append(Slot(key: field.key, value: field.value, unit: field.unit, field: field,
                                      carrier: Carrier(cardId: card.id, face: .row(row.id)),
                                      poolKey: Self.conceptKey(field.key),
                                      required: rowRequired.contains(field.key)))
                }
            }

            if case .newHub(let draft) = card.encounterAssociation {
                let hubRequired = Set(CardKindRegistry.entry(for: draft.hub.rawValue)?.sharedRequired ?? [])
                for field in draft.fields where field.grade != .rejected {
                    slots.append(Slot(key: field.key, value: field.value, unit: field.unit, field: field,
                                      carrier: Carrier(cardId: card.id, face: .hubDraft),
                                      poolKey: Self.conceptKey(field.key),
                                      required: hubRequired.contains(field.key)))
                }
            }
        }
        return slots
    }

    /// 汇集槽位：哪个卡面携带了哪个键值（含必填标注）。
    private struct Slot {
        let key: String
        let value: String
        let unit: String?
        let field: FieldDraft
        let carrier: Carrier
        /// 汇集用概念键（日期键归一；非日期键 = key 本身）。
        let poolKey: String
        let required: Bool
    }

    // MARK: - 闸门与回填

    /// 「处理完」= 每一行都已确认。未达则离场只能是「稍后处理」（业主：不能进入卡级处理）。
    public static func isSettled(_ rows: [Row]) -> Bool {
        rows.allSatisfy { $0.field.isConfirmed }
    }

    public static func awaitingCount(_ rows: [Row]) -> Int {
        rows.filter { !$0.field.isConfirmed }.count
    }

    /// 把本页确认后的值回填给**每个承载方**（各卡共享面/行内 + 主卡草稿）。
    /// 承载方**缺席**该键时按需补上（共享面缺席的必填键在第 5.1 条入池时即为此形态）。
    public static func project(_ rows: [Row], into cards: [MatchedCard]) -> [MatchedCard] {
        var byCard: [UUID: [Row]] = [:]
        for row in rows {
            for cardId in Set(row.carriers.map(\.cardId)) { byCard[cardId, default: []].append(row) }
        }
        return cards.map { card in
            guard let cardRows = byCard[card.id] else { return card }
            var updated = card
            for row in cardRows {
                for carrier in row.carriers where carrier.cardId == card.id {
                    // 2026-09-19 审查修复：回填键取承载方自己的键（日期概念合并后
                    // 处方卡 = prescribed_at、收费卡 = date——各行写回各自的键）。
                    let carrierKey = row.keysByCarrier[carrier] ?? row.key
                    switch carrier.face {
                    case .shared:
                        apply(row, to: &updated.shared, key: carrierKey)
                    case .row(let rowId):
                        guard let index = updated.rows.firstIndex(where: { $0.id == rowId }) else { continue }
                        apply(row, to: &updated.rows[index].fields, key: carrierKey)
                    case .hubDraft:
                        guard case .newHub(var draft) = updated.encounterAssociation else { continue }
                        apply(row, to: &draft.fields, key: carrierKey)
                        updated.encounterAssociation = .newHub(draft)
                    }
                }
            }
            return updated
        }
    }

    private static func apply(_ row: Row, to fields: inout [FieldDraft], key: String) {
        guard let index = fields.firstIndex(where: { $0.key == key }) else {
            // 承载方缺席该键：补一条（值与确认态随行）
            var field = row.field
            field.key = key
            fields.append(field)
            return
        }
        if fields[index].value != row.field.value {
            fields[index].revise(to: row.field.value)      // 留修订痕 + 失效重确认
        }
        fields[index].unit = row.field.unit
        if row.field.isConfirmed { _ = fields[index].confirm() }
    }
}
