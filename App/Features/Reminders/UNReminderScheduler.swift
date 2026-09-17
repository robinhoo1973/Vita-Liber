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
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notifyId, content: content, trigger: trigger))
    }

    /// 通知内容组装（锁屏隐私：固定通用文案；route 经 Codable 入 userInfo）
    private static func content(route: AppRoute?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.reminderNotificationTitle
        content.body = L10n.reminderNotificationBody
        if case .alertEvidence(_, _, let severity) = route {
            content.sound = .default
            if severity == .L2 || severity == .L3 { content.interruptionLevel = .timeSensitive }
        }
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
    ///
    /// 审查修复（首触发点错误）：`UNCalendarNotificationTrigger(repeats: true)`
    /// 只认墙钟组件、无法表达「起始日期」——首触发点恒为「武装时刻起的下一次
    /// 墙钟命中」：「明天每天20点」（今天 10:00 说）会提前到今天 20:00 触发，
    /// 「9月28日每周一9点」会提前到下一个周一。改为**逐次一次性触发**：
    /// 首针 = fireAt 精确时刻，其后按规则推进（每日 14 针 / 每周 12 针），
    /// 触发 id 由触发时刻派生（"\(id)-occ-<unix>"，稳定幂等——重武装同 id
    /// 即替换，窗随每次 refresh 滚动续期）。旧版遗留的 "-wd{1..7}" 重复
    /// 触发器（首触发点错误 + 与 occ 针重复触达）在本方法内先清后排。
    func scheduleRepeating(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                           repeatRule: String?) async throws {
        guard let repeatRule, !repeatRule.isEmpty,
              let weekdays = VoiceRepeatRules.weekdays(
                for: repeatRule,
                fireWeekday: Calendar.current.component(.weekday, from: fireAt)) else {
            try await schedule(dose: notifyId, at: fireAt, route: route)
            return
        }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: fireAt)
        let minute = cal.component(.minute, from: fireAt)
        let maxOccurrences = weekdays.isEmpty ? 14 : 12
        // 审查修复（滚动续期窗口锚点）：窗必须从 max(fireAt, now) 起算——
        // 登记已久的「每天 8:00」重武装时 fireAt 在数周前，若从 fireAt
        // 起逐日枚举，前 14 个候选全在过去，未来 14 天一针未武装
        // （每日提醒静默停摆）。首针仍恒 ≥ fireAt（绝不提前触达）。
        let now = Date()
        var occurrences: [Date] = []
        var day = cal.startOfDay(for: max(fireAt, now))
        while occurrences.count < maxOccurrences {
            guard let candidate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { break }
            if candidate >= fireAt, candidate >= now,
               weekdays.isEmpty || weekdays.contains(cal.component(.weekday, from: candidate)) {
                occurrences.append(candidate)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let content = Self.content(route: route)
        // 旧版遗留 repeating 触发器：与 occ 针同源触达（重复通知），先清
        let legacyWDs = (1...7).map { "\(notifyId)-wd\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: legacyWDs)
        for occurrence in occurrences {
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: occurrence)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try await center.add(UNNotificationRequest(
                identifier: "\(notifyId)-occ-\(Int(occurrence.timeIntervalSince1970))",
                content: content, trigger: trigger))
        }
    }

    /// 同族 id 判定（分隔符守卫）：基础 id、旧版 "-wd{1..7}" 重复针、
    /// 新版 "-occ-<unix>" 逐次针。带分隔符匹配，避免 "dose-X-5-1" 误伤
    /// "dose-X-5-10"（前缀不加分隔符会误判）。
    static func isSameFamily(_ candidate: String, as base: String) -> Bool {
        if candidate == base { return true }
        if candidate.hasPrefix(base + "-occ-") { return true }
        if candidate.hasPrefix(base + "-wd") {
            let suffix = candidate.dropFirst((base + "-wd").count)
            return (1...7).contains(Int(suffix) ?? 0)
        }
        return false
    }

    func cancel(_ notifyIds: [String]) async throws {
        // 第六轮全仓审查修复：scheduleRepeating 按「-wd{1..7}」后缀为每周
        // 重复排 7 条请求，按基础 id 取消会全部漏网（重复提醒不可取消）。
        // 第八轮形态（occ 逐次针）：改为按同族判定过滤实际 pending 集——
        // 旧实现只展开 weekday 后缀，occ 逐次针（数量不定）无法枚举。
        let pendingIds = await center.pendingNotificationRequests().map(\.identifier)
        let targets = pendingIds.filter { candidate in
            notifyIds.contains { Self.isSameFamily(candidate, as: $0) }
        }
        if !targets.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: targets)
        }
    }

    /// 移除已送达通知（确认/跳过后清锁屏残留）
    func removeDelivered(_ notifyIds: [String]) async throws {
        // 与 cancel 同纪律：同族判定（-wd 旧针 + -occ 逐次针的送达残留）
        let deliveredIds = await center.deliveredNotifications().map(\.request.identifier)
        let targets = deliveredIds.filter { candidate in
            notifyIds.contains { Self.isSameFamily(candidate, as: $0) }
        }
        if !targets.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: targets)
        }
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

    /// 本仓通知 id 前缀（对账 dose-/slot-/snooze-、预约分级 apt- 与错过跟进
    /// apt-followup-/复诊 followup-apt-、到期 exp-、续药 refill-、
    /// 备份 backup-、随访 followup-、语音 voice-rem-、预警 alert-）。
    /// 第七轮修复：apt- 前缀漏登记——语言切换时预约分级提醒跳过文案重写，
    /// 旧语言的标题/正文永久滞留（FR14.5 对预约通道失效）。
    /// 第八轮修复：snooze- 漏登记——稍后提醒语言切换时同样跳过重写。
    /// 第十轮收敛：前缀知识收敛 Domain ReminderChannelRules.categoryKey
    /// 单一事实源——本处不再维护第二份前缀清单（此前三处并行副本已两度
    /// 漂移：apt- 与 snooze- 各漏一次）。
    private static func isAppOwned(_ id: String) -> Bool {
        ReminderChannelRules.categoryKey(for: id) != nil
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
