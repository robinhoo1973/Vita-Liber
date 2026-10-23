import Foundation

/// FR9.4 服药时段（2026-10-23 业主指令）：把一天拆成用户可确认的固定锚点时段，
/// 计划创建时按时段选择提醒时刻，而不是让用户手输 "HH:mm" 自由文本。
///
/// 默认时刻取医院常用标准给药时间（HealthcareBC CST / Cerner 常用默认），
/// 用户可在计划表单逐时段调整自己的提醒时刻；时段只决定**提醒时刻**，
/// 不推断空腹/随餐等医学语义（BR-006），医嘱原文仍由用户确认后落 Prescription。
/// 起床后不是餐锚，mealRelation 为 nil，避免把「起床后」误当空腹或餐前。
public enum DoseTimeSlot: String, CaseIterable, Sendable, Codable, Hashable {
    case afterWake
    case beforeBreakfast
    case afterBreakfast
    case beforeLunch
    case afterLunch
    case beforeDinner
    case afterDinner
    case beforeSleep

    /// 默认提醒时刻（"HH:mm"）。与 `DoseScheduleEngine.mealDefaultTime` 的餐锚
    /// 默认值保持同源；起床后是新增锚点，取 07:00。
    public var defaultTime: String {
        switch self {
        case .afterWake: return "07:00"
        case .beforeBreakfast: return "07:30"
        case .afterBreakfast: return "08:30"
        case .beforeLunch: return "11:30"
        case .afterLunch: return "12:30"
        case .beforeDinner: return "17:30"
        case .afterDinner: return "19:30"
        case .beforeSleep: return "21:30"
        }
    }

    /// 餐食关系 token（FR9.4 既有词表）；起床后无餐食语义 → nil（绝不猜）。
    public var mealRelation: String? {
        switch self {
        case .afterWake: return nil
        case .beforeBreakfast: return "beforeBreakfast"
        case .afterBreakfast: return "afterBreakfast"
        case .beforeLunch: return "beforeLunch"
        case .afterLunch: return "afterLunch"
        case .beforeDinner: return "beforeDinner"
        case .afterDinner: return "afterDinner"
        case .beforeSleep: return "beforeSleep"
        }
    }
}

/// 时段 → 时刻序列（纯函数，Linux 可单测）：
/// - 用户覆盖时刻优先于默认时刻；
/// - 非法时刻丢弃（绝不静默落成 08:00——与 fixed 保存闸门同纪律）；
/// - 同一时刻去重（同义时段不生成重复剂量）；
/// - 结果按分钟升序（调度引擎与冲突提示均期望有序输入）。
public enum DoseTimeSlotRules {
    public static func times(_ slots: [DoseTimeSlot],
                             overrides: [DoseTimeSlot: String] = [:]) -> [String] {
        var seen = Set<String>()
        return slots
            .map { overrides[$0] ?? $0.defaultTime }
            .filter { DoseScheduleEngine.isValidTime($0) }
            .filter { seen.insert($0).inserted }
            .sorted { minutes($0) < minutes($1) }
    }

    /// "HH:mm" → 当日分钟数；调用方均已通过 isValidTime，非法值按 0 处理仅用于排序。
    public static func minutes(_ time: String) -> Int {
        DoseScheduleEngine.minutes(time) ?? 0
    }

    /// "HH:mm" + 日期 → Date（计划表单/快速新建的 DatePicker 绑定共用）。
    /// 非法时刻返回 nil（绝不猜）。
    public static func date(for time: String,
                            on day: Date = Date(),
                            calendar: Calendar = .current) -> Date? {
        guard let minutes = DoseScheduleEngine.minutes(time) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60,
                             second: 0, of: day)
    }

    /// Date → "HH:mm"（DatePicker 回写共用）。
    public static func timeString(from date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }
}
