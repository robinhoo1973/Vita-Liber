import SwiftUI
import Infrastructure

/// `AuditLogWriter` 的环境出口（2026-10-18）：语音/任务助手在确认时写
/// `voice.confirm` 事件。审计写入失败不得阻断用户保存（best-effort），
/// 但动作本身（question/note 直存）仍走同事务 `voice.execute`。
private struct AuditLogEnvironmentKey: EnvironmentKey {
    static let defaultValue: AuditLogWriter? = nil
}

extension EnvironmentValues {
    var auditLog: AuditLogWriter? {
        get { self[AuditLogEnvironmentKey.self] }
        set { self[AuditLogEnvironmentKey.self] = newValue }
    }
}
