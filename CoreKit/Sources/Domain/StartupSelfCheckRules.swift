import Foundation

/// 启动自检交接规则（U-批 B2，2026-10-28；纯 Domain，Linux 可测）。
///
/// 语义（三席收敛 + 业主 Q14=B）：
/// - **首次呈现门**：主 UI 在自检页之后交接——`isShowingBootScreen` 默认 true，
///   只有 `shouldHandOffUI` 为真且用户手动放行/无待办时才切换到主界面；
/// - **终态可见 ≥ 最短展示**：从 `max(presentedAt, terminalAt)` 起算，防止
///   「ready 很早 → 终态一闪而过」（架构席第三轮修正式，取代旧式
///   `max(readyAt, presentedAt+minDisplay)`）；
/// - **预算口径（S5/Q13）**：被动启动=0.8s hold + 全验探针实际耗时；autoEnter
///   1.5s/3s 只属于显式目录卡流程，不计入被动预算；
/// - **headless**（BGTask，无首帧）：不参与 UI 放行——`presentedAt == nil` 时
///   `shouldHandOffUI` 恒 false，但无 UI 可挡；`headlessTimeout` 只做观测/日志，
///   **不得**置 `hasSelfCheckPresented`。
public enum StartupSelfCheckRules {
    /// 被动最短展示（业主 O12：floor 500ms / cap 800ms，取 cap）。
    public static let minDisplaySeconds: TimeInterval = 0.8
    /// VoiceOver 下最短展示（沿用首启卡既有节奏）。
    public static let voiceOverMinDisplaySeconds: TimeInterval = 3.0
    /// 显式目录流程的自动进入（卡片），不进被动预算。
    public static let catalogAutoEnterSeconds: TimeInterval = 1.5
    public static let voiceOverCatalogAutoEnterSeconds: TimeInterval = 3.0

    /// UI 交接判据：终态自 `max(presentedAt, terminalAt)` 起至少可见 `minDisplay`。
    /// - `presentedAt`: 自检页首帧 onAppear 上报时刻（headless=nil）。
    /// - `terminalAt`: 被动=readyAt；卡片流程=cardTerminalAt。
    public static func shouldHandOffUI(presentedAt: Date?, terminalAt: Date,
                                       now: Date, minDisplay: TimeInterval) -> Bool {
        guard let presentedAt else { return false }   // headless：无 UI 可放行
        let visibleSince = max(presentedAt, terminalAt)
        return now >= visibleSince.addingTimeInterval(minDisplay)
    }

    /// 摘要展开暂停交接后的恢复锚点（启动时序批 ②，2026-10-29；测试席裁定）。
    ///
    /// 旧复排用 `max(presentedAt, terminalAt) + minDisplay`——floor 已过期时收起
    /// 摘要会**立即交接**，收起后的 500ms 可见窗口拿不到。故展开/收起单独建模：
    /// 展开期间交接计时冻结；收起后从 `max(收起时刻 + resumeDelay, floorEnd)` 恢复。
    public static let expandedResumeDelay: TimeInterval = 0.5

    public static func resumeAnchor(collapsedAt: Date, floorEnd: Date,
                                    delay: TimeInterval = expandedResumeDelay) -> Date {
        max(collapsedAt.addingTimeInterval(delay), floorEnd)
    }

    /// 交接 floor 终点（与 `shouldHandOffUI` 同口径），供恢复锚点计算。
    public static func floorEnd(presentedAt: Date?, terminalAt: Date,
                                minDisplay: TimeInterval) -> Date? {
        guard let presentedAt else { return nil }
        return max(presentedAt, terminalAt).addingTimeInterval(minDisplay)
    }
}
