import Foundation
import UserNotifications
import Protocols

/// 生产通知适配器（§5.4）：UNUserNotificationCenter + 滚动预排窗口。
/// 锁屏隐私：标题固定「您有一条健康提醒」，药名不落通知正文（FR9 通知矩阵）。
actor UNReminderScheduler: ReminderScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func schedule(dose notifyId: String, at fireAt: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = "您有一条健康提醒"
        content.body = "点击查看详情"          // 隐私：正文不含药名/剂量（默认隐藏预览）
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
