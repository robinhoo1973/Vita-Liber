import Foundation

/// 通知 ID 命名空间（Infrastructure 内共享）：「apt-<appointmentId>」前缀是
/// AppointmentStore（预约删除/取消联动）与 MemberDeletionService（成员删除
/// 全量撤销）的共同约定——两者都必须清除对应 pending 通知，否则已删预约
/// 继续按时弹出提醒。命名方案集中一处，改前缀只动这里。
public enum ReminderIDNames {
    static func appointmentPrefix(_ id: UUID) -> String { "apt-\(id.uuidString)" }

    /// dose-{planId}-{epochSlot} → planId（**完整 UUID 形态**）。
    /// 第九轮审查批C⑤（notify-id 字符串 ABI 收敛）：本解析只此一处——
    /// App 侧 ReminderHubLoader.planId(fromNotifyId:) 此前按 "-" split 取
    /// parts[1]，而 planId 是自带连字符的 UUID → 得到前 8 位片段（当时仅作
    /// 不透明压缩键才未暴露；任何真实消费该值的调用方都会静默失败）。
    /// epochSlot 为纯数字无连字符，取**最后一个** "-" 之前即 planId。
    public static func planId(fromDoseNotifyId notifyId: String) -> String? {
        guard notifyId.hasPrefix("dose-") else { return nil }
        let rest = notifyId.dropFirst("dose-".count)
        guard let lastDash = rest.lastIndex(of: "-") else { return nil }
        let planId = String(rest[..<lastDash])
        return planId.isEmpty ? nil : planId
    }

    /// pending 里以任意给定预约 id 开头的全部取回（一次 pending 拉取、一次遍历）。
    /// ids 为 uuidString 形态（MemberDeletionService 的待删清单即 String 形态）。
    /// 第七轮全仓审查修复：必须覆盖该预约的**全部**通知形态——分级提醒
    /// `apt-{id}-<tier>`、错过跟进 `apt-followup-{id}` 与复诊提醒
    /// `followup-apt-{id}`（后两者此前漏网：已删成员/已取消预约的复诊
    /// 提醒按时弹出并深链到不存在的数据）。
    /// 第八轮修复：注释声称覆盖而实现漏配——`apt-{id}` 前缀**不**匹配
    /// `apt-followup-{id}`（"apt-" 后是 "followup-" 而非 id），错过跟进
    /// 提醒在成员删除后仍按时弹出并深链到已删数据（FR3.4 隔离违例）。
    static func staleAppointments(in pending: [String: Date], ids: [String]) -> [String] {
        pending.keys.filter { key in ids.contains {
            key.hasPrefix("apt-followup-\($0)") || key.hasPrefix("apt-\($0)")
                || key.hasPrefix("followup-apt-\($0)")
        } }
    }
}
