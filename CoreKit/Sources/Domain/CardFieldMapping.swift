import Foundation

/// 信息卡片字段映射（2026-11-06 业主：改值的同时可改「文本对应的字段」）。
///
/// 单一事实源 = `CardKindRegistry`：候选键只来自该卡类的必填/可选目录，
/// 已占用键不重复出现；改名经 `FieldDraft.key` 的 didSet 统一失效旧确认
/// （BR-003：字段语义变了必须重新确认），并清掉旧的 F25 编码建议，避免
/// 「药名」改成「剂量」后仍挂着药名编码。
public struct CardFieldKeyOption: Sendable, Equatable, Identifiable {
    public let key: String
    public var id: String { key }

    public init(key: String) { self.key = key }
}

public enum CardFieldMapping {
    /// 可改的目标键：当前卡类的必填 + 可选目录，剔除内部键与已占用键；
    /// 当前键始终保留（菜单需要显示“当前”勾选，不能因为已存在而消失）。
    public static func options(kind: String, present: Set<String>, rowLevel: Bool,
                               currentKey: String) -> [CardFieldKeyOption] {
        guard let entry = CardKindRegistry.entry(for: kind) else { return [] }
        let allowed = allowedKeys(entry, rowLevel: rowLevel)
        let occupied = present.subtracting([currentKey])
        let available = allowed.subtracting(occupied).subtracting(["metric_key"])
        return available.sorted().map(CardFieldKeyOption.init(key:))
    }

    /// 是否允许把 `from` 改成 `to`：目标必须在目录内、未被同组其他字段占用、
    /// 不是内部键，且确实发生变化。
    public static func canRename(kind: String, present: Set<String>, rowLevel: Bool,
                                 from: String, to: String) -> Bool {
        guard from != to, to != "metric_key" else { return false }
        guard let entry = CardKindRegistry.entry(for: kind) else { return false }
        guard allowedKeys(entry, rowLevel: rowLevel).contains(to) else { return false }
        return !present.subtracting([from]).contains(to)
    }

    /// 共享面只列真正的表头键：`CardKindRegistry.sharedOptional` 为了放行
    /// “无法唯一归行时保留为共享”的行级键而包含 row 键，但字段映射菜单不能
    /// 让用户把表头字段改成 `drug_name` 这类行级键（会生成语义错误的卡）。
    private static func allowedKeys(_ entry: CardKindEntry, rowLevel: Bool) -> Set<String> {
        if rowLevel { return entry.rowAllowed }
        return entry.sharedRequired.union(entry.sharedOptional.subtracting(entry.rowAllowed))
    }

    /// 就地改字段键（共享面 `rowID == nil`，行面传稳定行 UUID）。
    /// 只改键，不改值/单位/原文锚点；`key` 的 didSet 会失效旧确认。
    /// 已拒绝字段不允许改键：拒绝是用户的显式否定，改键经 didSet 会把
    /// grade 复位为 `ocrUnconfirmed`，等于静默复活（与 `FieldDraft.fillByUser`
    /// 的 rejected 纵深防御同口径；UI 已隐藏入口，Domain 再拒一次）。
    @discardableResult
    public static func rename(in card: inout MatchedCard, rowID: UUID?, index: Int,
                              to newKey: String) -> Bool {
        if let rowID {
            guard let row = card.rows.firstIndex(where: { $0.id == rowID }),
                  card.rows[row].fields.indices.contains(index),
                  card.rows[row].fields[index].grade != .rejected else { return false }
            let present = Set(card.rows[row].fields.map(\.key))
            guard canRename(kind: card.kind, present: present, rowLevel: true,
                            from: card.rows[row].fields[index].key, to: newKey) else { return false }
            card.rows[row].fields[index].key = newKey
        } else {
            guard card.shared.indices.contains(index),
                  card.shared[index].grade != .rejected else { return false }
            let present = Set(card.shared.map(\.key))
            guard canRename(kind: card.kind, present: present, rowLevel: false,
                            from: card.shared[index].key, to: newKey) else { return false }
            card.shared[index].key = newKey
        }
        return true
    }
}
