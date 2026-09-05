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
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notifyId, content: content, trigger: trigger))
    }

    func cancel(_ notifyIds: [String]) async throws {
        center.removePendingNotificationRequests(withIdentifiers: notifyIds)
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
