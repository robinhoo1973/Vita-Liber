import Foundation

/// 导入类型间的时间预算公平分配（业主 2026-10-20 睡眠缺失修复）。
///
/// 背景：`HealthKitSyncService.run` 原按 `HealthDataKind.allCases` 固定顺序推进，
/// 每类可连续物化最多 32 个窗口；加入轮内 deadline 后，心率（一年 ≈8760 个
/// 小时窗）常把 30s 预算耗尽，排在最后的睡眠永远轮不到——表现为「睡眠数据
/// 严重缺失」。这里只放纯调度规则：轮转起点 + 剩余预算均分，保证每次受限
/// 轮次至少给每类一个份额；跨轮次轮转起点，让重活多的类型不能长期独占。
public enum HealthImportScheduling {
    /// 从 `startingAt` 起轮转类型顺序；负索引按模回绕，空数组返回空。
    public static func rotated(_ kinds: [HealthDataKind], startingAt index: Int) -> [HealthDataKind] {
        guard !kinds.isEmpty else { return [] }
        let start = ((index % kinds.count) + kinds.count) % kinds.count
        return Array(kinds[start...]) + Array(kinds[..<start])
    }

    /// 剩余预算均分给尚未处理的类型；负预算/无类型返回 `.zero`，避免负 deadline。
    public static func share(remaining: Duration, kindsLeft: Int) -> Duration {
        guard kindsLeft > 0, remaining > .zero else { return .zero }
        return remaining / kindsLeft
    }
}
