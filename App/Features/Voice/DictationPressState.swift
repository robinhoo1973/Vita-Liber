import Foundation
import Domain

/// 触摸按压状态机（结构轮 2026-09-15 自 PressToTalkMicButton.swift 移出）：
/// 纯值状态机、可单测（DictationPressStateTests）——识别计时器与触摸终止共享同一身份，
/// 松开不会二次触发按钮（视图文件不再持有可测逻辑，A4-F11.3）。
/// Recognition timers and touch termination share one identity, so release cannot also toggle a Button.
struct DictationPressState {
    enum EndAction: Equatable { case none, toggle, stop }

    /// 识别（长按）阈值：**点击开关**与**按住说话**的分界，单位秒。
    ///
    /// 为什么是 0.6s（业主 2026-09-16 第 5 项「点击录音图形按钮开始」的实际症状）：
    /// 阈值此前硬编码 0.2s，而一次正常点击轻易超过它（老人/关怀模式更慢）——
    /// 于是「点击」被判成「按住」：识别在阈值处启动、抬手即停，得到一段几十毫秒的
    /// 空录音并以「未识别到语音」收场，用户看到的是「点了开始，自己就停了」。
    /// 0.6s 与全仓长按口径一致（SOS/危险动作确认 = `CareModeMetrics.holdConfirmSeconds`），
    /// 且落在「故意按住说话」的自然时长内：短按 = 开关（tap-to-toggle，
    /// ui-ux §3 原则 4「避免长按依赖」），长按 ≥0.6s = 按住说话（松手结束）。
    /// 阈值是交互契约，放状态机而非视图——`DictationPressStateTests` 覆盖。
    /// 审查修复：直接引用 Domain 单一事实源（此前注释声称与
    /// CareModeMetrics.holdConfirmSeconds 同口径却硬编码第二份 0.6——
    /// 全仓长按口径重调时两处漂移）。
    static let holdThreshold: TimeInterval = CareModeMetrics.standard.holdConfirmSeconds

    /// 阈值对应的纳秒数（`Task.sleep` 出口，避免视图里再写一遍字面量）
    static var holdThresholdNanoseconds: UInt64 { UInt64(holdThreshold * 1_000_000_000) }

    private(set) var id: UUID?
    private var holding = false

    init() {}

    mutating func begin() -> UUID {
        if let id { return id }
        let id = UUID()
        self.id = id
        return id
    }

    mutating func recognize(_ id: UUID) -> Bool {
        guard self.id == id, !holding else { return false }
        holding = true
        return true
    }

    mutating func end(cancelled: Bool) -> EndAction {
        guard id != nil else { return .none }
        let action: EndAction = holding ? .stop : (cancelled ? .none : .toggle)
        id = nil
        holding = false
        return action
    }
}
