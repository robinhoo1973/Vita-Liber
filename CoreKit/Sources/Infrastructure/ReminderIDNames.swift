import Foundation

/// 通知 ID 命名空间（Infrastructure 内共享）：「apt-<appointmentId>」前缀是
/// AppointmentStore（预约删除/取消联动）与 MemberDeletionService（成员删除
/// 全量撤销）的共同约定——两者都必须清除对应 pending 通知，否则已删预约
/// 继续按时弹出提醒。命名方案集中一处，改前缀只动这里。
enum ReminderIDNames {
    static func appointmentPrefix(_ id: UUID) -> String { "apt-\(id.uuidString)" }

    /// pending 里以任意给定预约 id 开头的全部取回（一次 pending 拉取、一次遍历）。
    /// ids 为 uuidString 形态（MemberDeletionService 的待删清单即 String 形态）
    static func staleAppointments(in pending: [String: Date], ids: [String]) -> [String] {
        pending.keys.filter { key in ids.contains { key.hasPrefix("apt-\($0)") } }
    }
}
