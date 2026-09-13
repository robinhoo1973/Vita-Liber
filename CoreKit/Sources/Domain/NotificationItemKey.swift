import Foundation

/// FR14.8 / FR2.1⑦ `notification_state.item_key` 唯一编码——首页与通知中心共用（round2 U-N4）。
/// alert_event→alert · appointment→apt · refill→lot（批次库存通知，续药/临期共用）· dose_slot→dose（历史键，首页不再归档用药）
/// · ocr→ocr（按文档；通知中心不再用跨成员 ocr-queue）· 其余 = kind 原文（stock_backlog / pending_card / profile_progress）。
public enum NotificationItemKey {
    public static func key(kind: String, sourceId: String) -> String {
        let prefix: String
        switch kind {
        case "alert_event": prefix = "alert"
        case "appointment": prefix = "apt"
        case "refill": prefix = "lot"
        case "dose_slot": prefix = "dose"
        default: prefix = kind
        }
        return "\(prefix)-\(sourceId)"
    }
    public static func key(for item: AggregatedReminderItem) -> String { key(kind: item.id.kind, sourceId: item.id.sourceId) }

    /// 「稍后（次日键）」：基键 + 自然日后缀；次日键不同即自动重现——无新列、无定时器。
    public static func snoozedUntilTomorrowKey(_ base: String, now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(base)@\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// 读侧：能把该行从首页隐藏的键集；空 = 任何持久状态都不能隐藏（dose_slot BR-004、逾期 OCR BR-003、profile_progress）。
    public static func hideKeys(for item: AggregatedReminderItem, now: Date, calendar: Calendar = .current) -> [String] {
        let base = key(for: item)
        let day = snoozedUntilTomorrowKey(base, now: now, calendar: calendar)
        switch item.id.kind {
        case "alert_event", "appointment": return [base]
        case "refill", "stock_backlog": return [base, day]
        case "ocr": return item.isPinned ? [] : [base, day]
        case "pending_card": return [day]   // 历史 pending_card- 归档不再隐藏 D 级草稿（U-N5）
        default: return []
        }
    }

    /// 写侧：归档 = 基键；稍后 = 次日键；其余动作不写通知状态。
    public static func writeKey(for item: AggregatedReminderItem, disposition: ReminderDisposition,
                                now: Date, calendar: Calendar = .current) -> String? {
        switch disposition {
        case .archive: return key(for: item)
        case .snoozeUntilTomorrow: return snoozedUntilTomorrowKey(key(for: item), now: now, calendar: calendar)
        default: return nil
        }
    }
}
