import Foundation

/// 触摸按压状态机（结构轮 2026-09-15 自 PressToTalkMicButton.swift 移出）：
/// 纯值状态机、可单测（DictationPressStateTests）——识别计时器与触摸终止共享同一身份，
/// 松开不会二次触发按钮（视图文件不再持有可测逻辑，A4-F11.3）。
/// Recognition timers and touch termination share one identity, so release cannot also toggle a Button.
struct DictationPressState {
    enum EndAction: Equatable { case none, toggle, stop }
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
