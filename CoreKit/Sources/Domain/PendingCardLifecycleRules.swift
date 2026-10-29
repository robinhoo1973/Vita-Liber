import Foundation

/// 待核对卡生命周期规则（业主裁决 A，2026-10-30）：
/// 30 天未处理自动归档的卡不得成为 D 级死胡同——**归档（含 expired 归档）
/// 可补办**：打开即解除归档回 pending，随后按既有 FR17.13 确认链升 C。
/// BR-003 不变：归档补办只恢复「可确认」路径，绝不把未确认内容当事实。
///
/// 单一出处纪律：状态集合与可恢复判定只在此处定义，存储层、投影层、
/// 恢复页三处消费同一规则（此前三处各自硬编码白名单，归档态一出现即成死路）。
public enum PendingCardLifecycleRules {
    /// 活跃可续办态（过期=提醒语义非终态）。
    public static let resumableStatuses: Set<String> = ["pending", "in_progress", "expired"]

    /// 详情/恢复页可见：活跃三态 + 归档（补办入口）。
    public static func isVisible(status: String) -> Bool {
        resumableStatuses.contains(status) || status == "archived"
    }

    /// 归档可补办：用户归档（user）与到期归档（expired）均可恢复；
    /// resolved_by 缺失（旧行）按可恢复处理（fail-open 仅限恢复路径，
    /// 确认闸门仍在存储层独立守 BR-003）。
    public static func canRestore(status: String, resolvedBy: String?) -> Bool {
        guard status == "archived" else { return false }
        switch resolvedBy {
        case "user", "expired", nil: return true
        default: return false
        }
    }

    /// 恢复页可装载：活跃态直接续办；归档态走补办（canRestore）后再续办。
    public static func canResume(status: String, resolvedBy: String?) -> Bool {
        resumableStatuses.contains(status) || canRestore(status: status, resolvedBy: resolvedBy)
    }
}
