import Foundation
import Perception

/// SP-19 主卡展开记忆（子项目 J · round1 §E.3 / §C1）：按 `TimelineHubEntry.id` 记 UserDefaults，
/// `nil` = 无记忆（交给 Domain `TimelineHierarchyRules.expanded` 默认：最新一张主卡展开、其余折叠）。
///
/// - 键：`timeline.hub.expanded.<id>`（Bool）；另维护 LRU 顺序表 `timeline.hub.expanded.order`，超过 `capacity` 淘汰最久未触碰的键
///   （成员多年记录的主卡数无上界，UserDefaults 不能无限增长）。
/// - 筛选态的展开是瞬态（Domain 规则给出），视图层不得经本仓写入（`TimelineViewState.setExpanded` 守卫）。
/// - `version`：写后 +1；视图经 `WithPerceptionTracking` 读它即可在写入后重算展开集（UserDefaults 自身不发布感知变化）。
@MainActor
@Perceptible
final class TimelineExpansionStore {
    static let keyPrefix = "timeline.hub.expanded."
    static let orderKey = "timeline.hub.expanded.order"

    private(set) var version = 0
    private let defaults: UserDefaults
    private let capacity: Int

    init(defaults: UserDefaults = .standard, capacity: Int = 200) {
        self.defaults = defaults
        self.capacity = max(capacity, 1)
    }

    /// 上次记忆的展开状态；从未记过 → nil。
    func remembered(_ id: String) -> Bool? {
        defaults.object(forKey: Self.keyPrefix + id) as? Bool
    }

    /// 写记忆并把该键移到 LRU 尾部；超容量时淘汰头部（连同其 Bool 键）。
    func set(_ id: String, expanded: Bool) {
        defaults.set(expanded, forKey: Self.keyPrefix + id)
        var order = (defaults.array(forKey: Self.orderKey) as? [String]) ?? []
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity {
            let evicted = order.removeFirst()
            defaults.removeObject(forKey: Self.keyPrefix + evicted)
        }
        defaults.set(order, forKey: Self.orderKey)
        version += 1
    }

    /// 清除单条记忆（回到默认规则）。
    func forget(_ id: String) {
        defaults.removeObject(forKey: Self.keyPrefix + id)
        var order = (defaults.array(forKey: Self.orderKey) as? [String]) ?? []
        order.removeAll { $0 == id }
        defaults.set(order, forKey: Self.orderKey)
        version += 1
    }

    /// 已记忆的键数（测试 / 诊断）。
    var rememberedCount: Int {
        ((defaults.array(forKey: Self.orderKey) as? [String]) ?? []).count
    }
}
