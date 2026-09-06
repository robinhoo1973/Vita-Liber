import Foundation
import UserNotifications
import Domain
import Protocols

/// 生产通知适配器（§5.4）：UNUserNotificationCenter + 滚动预排窗口。
/// 锁屏隐私：标题固定「您有一条健康提醒」，药名不落通知正文（FR9 通知矩阵）。
/// 深链（§5.45）：AppRoute 经 Codable 编码写入 userInfo["route"]，
/// 点击后由 UNUserNotificationCenterDelegate.didReceive 解码导航；缺路由降级不 crash。
/// 通知文案经 NSLocalizedString 走三文件本地化（FR14.5：通知内容随语言切换）。
actor UNReminderScheduler: ReminderScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?) async throws {
        let content = Self.content(route: route)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notifyId, content: content, trigger: trigger))
    }

    /// 通知内容组装（锁屏隐私：固定通用文案；route 经 Codable 入 userInfo）
    private static func content(route: AppRoute?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.reminderNotificationTitle
        content.body = L10n.reminderNotificationBody
        // §5.45 通知点击→路由映射契约：route 以 Codable 数据写入 userInfo
        if let route {
            // try?-ok: AppRoute 为 Foundation 标量枚举编码，无抛错路径；编码失败
            // 等价于「无路由」降级语义（§5.45：缺路由降级不 crash），必须静默降级
            if let data = try? JSONEncoder().encode(route) {   // try?-ok: 标量枚举编码无抛错路径，失败即无路由降级
                content.userInfo["route"] = data
            }
        }
        return content
    }

    /// FR17.10 重复提醒（审查修复：原实现无论 repeatRule 一律排一次性触发，
    /// 语音文法抽出的重复短语被静默丢弃）。短语→组件映射在 Domain
    /// VoiceRepeatRules（与文法表同一事实源）；未知规则回落一次性（绝不猜语义）。
    func scheduleRepeating(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                           repeatRule: String?) async throws {
        guard let repeatRule, !repeatRule.isEmpty,
              let weekdays = VoiceRepeatRules.weekdays(
                for: repeatRule,
                fireWeekday: Calendar.current.component(.weekday, from: fireAt)) else {
            try await schedule(dose: notifyId, at: fireAt, route: route)
            return
        }
        let content = Self.content(route: route)
        var comps = Calendar.current.dateComponents([.hour, .minute], from: fireAt)
        if weekdays.isEmpty {
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            try await center.add(UNNotificationRequest(identifier: notifyId, content: content,
                                                       trigger: trigger))
            return
        }
        for weekday in weekdays {
            var c = comps
            c.weekday = weekday
            let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
            try await center.add(UNNotificationRequest(identifier: "\(notifyId)-wd\(weekday)",
                                                       content: content, trigger: trigger))
        }
    }

    func cancel(_ notifyIds: [String]) async throws {
        center.removePendingNotificationRequests(withIdentifiers: notifyIds)
    }

    /// 移除已送达通知（确认/跳过后清锁屏残留）
    func removeDelivered(_ notifyIds: [String]) async throws {
        center.removeDeliveredNotifications(withIdentifiers: notifyIds)
    }

    /// FR14.5 语言切换：待投递通知的标题/正文在排程时以当前语言固化，
    /// 切换后须重写——同 identifier 的 add 即替换，fireAt 保持原样。
    /// 只重建本仓调度的提醒（前缀白名单）；路由从 userInfo 还原。
    func reloadLocalizedContent() async throws {
        for request in await center.pendingNotificationRequests() {
            guard Self.isAppOwned(request.identifier) else { continue }
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { continue }
            // 历史 userInfo 的 route 数据若损坏，等价「无路由」降级语义（§5.45）
            let route = (request.content.userInfo["route"] as? Data)
                .flatMap { try? JSONDecoder().decode(AppRoute.self, from: $0) }   // try?-ok: 解码失败等价无路由降级（§5.45），不得 crash
            let content = Self.content(route: route)
            // 原组件与 repeats 原样保留（含重复语音提醒的 weekday 形态），只换文案
            let newTrigger = UNCalendarNotificationTrigger(
                dateMatching: trigger.dateComponents, repeats: trigger.repeats)
            try await center.add(UNNotificationRequest(
                identifier: request.identifier, content: content, trigger: newTrigger))
        }
    }

    /// 本仓通知 id 前缀（对账 dose-/slot-、到期 exp-、续药 refill-、
    /// 备份 backup-、随访 followup-、语音 voice-rem-）
    private static func isAppOwned(_ id: String) -> Bool {
        id.hasPrefix("dose-") || id.hasPrefix("slot-") || id.hasPrefix("refill-")
            || id.hasPrefix("exp-") || id.hasPrefix("followup-")
            || id.hasPrefix("backup-") || id.hasPrefix("voice-rem-")
    }

    func pending() async throws -> [String: Date] {
        var out: [String: Date] = [:]
        for r in await center.pendingNotificationRequests() {
            if let t = r.trigger as? UNCalendarNotificationTrigger,
               let fire = t.nextTriggerDate() {
                out[r.identifier] = fire
            }
        }
        return out
    }

    func delivered() async throws -> Set<String> {
        Set(await center.deliveredNotifications().map(\.request.identifier))
    }
}
