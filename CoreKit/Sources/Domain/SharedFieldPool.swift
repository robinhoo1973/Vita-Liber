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
        struct Slot {
            let key: String
            let value: String
            let unit: String?
            let field: FieldDraft
            let carrier: Carrier
            let required: Bool
        }

        var slots: [Slot] = []
        for card in cards {
            let entry = CardKindRegistry.entry(for: card.kind)
            let sharedRequired = Set(entry?.sharedRequired ?? [])

            for field in card.shared where field.grade != .rejected && field.key != "card_kind" {
                slots.append(Slot(key: field.key, value: field.value, unit: field.unit, field: field,
                                  carrier: Carrier(cardId: card.id, face: .shared),
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
                                      carrier: Carrier(cardId: card.id, face: .shared), required: true))
                }
            }

            for row in card.rows {
                let rowRequired = Set((entry?.allowsEmptyRows == true && row.fields.isEmpty) ? [] : (entry?.rowRequired ?? []))
                for field in row.fields where field.grade != .rejected && field.key != "metric_key" {
                    slots.append(Slot(key: field.key, value: field.value, unit: field.unit, field: field,
                                      carrier: Carrier(cardId: card.id, face: .row(row.id)),
                                      required: rowRequired.contains(field.key)))
                }
            }

            if case .newHub(let draft) = card.encounterAssociation {
                let hubRequired = Set(CardKindRegistry.entry(for: draft.hub.rawValue)?.sharedRequired ?? [])
                for field in draft.fields where field.grade != .rejected {
                    slots.append(Slot(key: field.key, value: field.value, unit: field.unit, field: field,
                                      carrier: Carrier(cardId: card.id, face: .hubDraft),
                                      required: hubRequired.contains(field.key)))
                }
            }
        }

        // 归并：键 → 值+单位 → 承载方集合
        var order: [String] = []
        var byKey: [String: [String: [Slot]]] = [:]
        for slot in slots {
            let valueKey = "\(slot.value)\u{1}\(slot.unit ?? "")"
            if byKey[slot.key] == nil { byKey[slot.key] = [:]; order.append(slot.key) }
            byKey[slot.key]?[valueKey, default: []].append(slot)
        }

        var out: [Row] = []
        let multiCard = cards.count >= 2
        for key in order {
            guard let groups = byKey[key] else { continue }
            let cardCount = Set(slots.filter { $0.key == key }.map(\.carrier.cardId)).count
            let repeated = cardCount >= 2
            for (_, group) in groups.sorted(by: { $0.value.first?.value ?? "" < $1.value.first?.value ?? "" }) {
                guard let head = group.first else { continue }
                let required = group.contains(where: \.required)
                let lowConfidence = group.contains { $0.field.confidence < floor }
                let missing = head.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // 三条析取（规格 2026-09-17 定稿）：① 跨卡重复 ② 必填 ∧ 低置信（单卡也入）
                // ③ 必填 ∧ 缺失 ∧ **多卡**——单卡的缺失/空值留在卡内（业主：「单卡的卡内操作」）
                let critical = required && (lowConfidence || (missing && multiCard))
                guard repeated || critical else { continue }
                out.append(Row(key: key, value: head.value, unit: head.unit, field: head.field,
                               carriers: group.map(\.carrier).sorted { "\($0.face)" < "\($1.face)" },
                               repeatedAcrossCards: repeated, criticalLowConfidence: critical, required: required))
            }
        }
        return out
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
                    switch carrier.face {
                    case .shared:
                        apply(row, to: &updated.shared, key: row.key)
                    case .row(let rowId):
                        guard let index = updated.rows.firstIndex(where: { $0.id == rowId }) else { continue }
                        apply(row, to: &updated.rows[index].fields, key: row.key)
                    case .hubDraft:
                        guard case .newHub(var draft) = updated.encounterAssociation else { continue }
                        apply(row, to: &draft.fields, key: row.key)
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
