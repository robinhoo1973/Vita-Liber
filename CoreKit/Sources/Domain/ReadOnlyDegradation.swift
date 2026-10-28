import Foundation

/// 只读降级适格策略（2026-10-28 规划轮 round1；纯 Domain，Linux 可测）。
///
/// 定稿见 `refactor/discussions/2026-10-28-readonly-degradation-round1.md`（四席收敛）：
/// **首批仅 `.tooNew` 适格**——corrupt 五因或物理上不可读（emptyFile/badHeader/
/// unreadableVersion），或不可证非半恢复（missingRequiredTables/versionZeroWithTables）；
/// `missingWithOriginals` 无主库可读（原件文件浏览另立项）；`migrationIncomplete` /
/// `openFailed` / `unexpected` 一律 fail-closed。`.fresh/.ready/.migrate` 不属失败态，
/// 不需要降级。
///
/// 集合适格口径由单测锁死：新增任何适格决策必须来此改常量并重审红线口径
/// （安全席：放宽入口=一漏即红线，宁窄勿宽）。
public enum ReadOnlyDegradation {
    /// 适格决策标签集（字面量钉版；与 `isEligible` 双向一致由测试断言）。
    public static let eligibleDecisionLabels: Set<String> = ["tooNew"]

    /// 仅 `tooNew` 适格；其余一律 fail-closed。
    public static func isEligible(_ decision: DatabaseBootDecision) -> Bool {
        if case .tooNew = decision { return true }
        return false
    }

    /// 与 `isEligible` 镜像的标签判定（诊断/日志用；不参与 UI 决策）。
    public static func label(for decision: DatabaseBootDecision) -> String {
        switch decision {
        case .fresh: return "fresh"
        case .ready: return "ready"
        case .migrate: return "migrate"
        case .tooNew: return "tooNew"
        case .missingWithOriginals: return "missingWithOriginals"
        case .corrupt(let reason): return "corrupt-\(reason.rawValue)"
        }
    }
}
