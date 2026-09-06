import Foundation

/// FR2.3/FR6.8 待确认 OCR 队列窗口规则（BR 纯函数——视图层禁止内联判定，
/// 架构规则 4：No business decisions inside Views）。
///
/// 第四轮全仓审查修复（5WHY 根因）：「D 级文档 + 72h 置顶」判定曾以三种表述
/// 散落在 HomeView（DayArithmetic 日历日）、PendingOcrQueueView（72*3600 秒、
/// -3*86400 秒）、NotificationCenterView（grade=='D' 裸字符串）各写一遍——
/// 固定秒数算法在 DST 切换日与日历日口径分歧 ±1 小时，同一条文档在首页
/// 与队列的置顶判定互相矛盾。收敛为单一 Domain 出口，全部走日历日算术。
public enum PendingOcrRules {

    /// 是否超过 72 小时未处理（FR2.3 置顶钉住；严格大于——恰好 72h 不算超窗）。
    /// 日历日出口（DayArithmetic），禁止固定 86400 秒（DST 纪律）。
    public static func isOverdue(createdAt: Date, now: Date = Date()) -> Bool {
        createdAt < DayArithmetic.offset(days: -3, from: now)
    }

    /// 是否落在最近 `days` 个日历天内（队列「3 天」筛选窗与首页置顶同口径）。
    public static func isWithinLastDays(_ days: Int, createdAt: Date, now: Date = Date()) -> Bool {
        createdAt > DayArithmetic.offset(days: -days, from: now)
    }
}
