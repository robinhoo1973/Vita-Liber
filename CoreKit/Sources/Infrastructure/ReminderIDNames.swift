import Foundation

/// 通知 ID 命名空间（Infrastructure 内共享）：「apt-<appointmentId>」前缀是
/// AppointmentStore（预约删除/取消联动）与 MemberDeletionService（成员删除
/// 全量撤销）的共同约定——两者都必须清除对应 pending 通知，否则已删预约
/// 继续按时弹出提醒。命名方案集中一处，改前缀只动这里。
enum ReminderIDNames {
    static func appointmentPrefix(_ id: UUID) -> String { "apt-\(id.uuidString)" }

    /// pending 里以任意给定预约 id 开头的全部取回（一次 pending 拉取、一次遍历）。
    /// ids 为 uuidString 形态（MemberDeletionService 的待删清单即 String 形态）。
    /// 第七轮全仓审查修复：必须覆盖该预约的**全部**通知形态——分级提醒
    /// `apt-{id}-<tier>`、错过跟进 `apt-followup-{id}` 与复诊提醒
    /// `followup-apt-{id}`（后两者此前漏网：已删成员/已取消预约的复诊
    /// 提醒按时弹出并深链到不存在的数据）
    static func staleAppointments(in pending: [String: Date], ids: [String]) -> [String] {
        pending.keys.filter { key in ids.contains {
            key.hasPrefix("apt-\($0)") || key.hasPrefix("followup-apt-\($0)")
        } }
    }
}
