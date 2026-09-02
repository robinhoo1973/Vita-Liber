import Foundation

/// FR9.4/§5.4 schedule_json 统一编码：六类调度 → 计划期内 ScheduledDose 生成。
/// 调度引擎只消费该 schema；模糊医嘱（如「隔日一次」）在确认 UI 落成具体
/// fixed/interval 后才写库。
public enum MedicationSchedule: Sendable, Equatable, Codable {
    case fixed(times: [String])                                  // "08:00","20:00"
    case interval(everyMinutes: Int, start: String)
    case meal(relations: [String])                               // beforeBreakfast/afterDinner/...
    case asNeeded
    case cycle(everyDays: Int, daysOn: Int)
    case taper(stages: [TaperStage])

    public struct TaperStage: Sendable, Equatable, Codable {
        public var phase: Int
        public var fromDay: Int
        public var toDay: Int
        public var doseUnits: Double
        public var times: [String]
        public init(phase: Int, fromDay: Int, toDay: Int, doseUnits: Double, times: [String]) {
            self.phase = phase; self.fromDay = fromDay; self.toDay = toDay
            self.doseUnits = doseUnits; self.times = times
        }
    }
}

/// 计划生命周期状态机（FR9.15 / ADR-020）：调度与双轨扣减以 status 为闸门
public enum PlanStatus: String, Sendable, Equatable, Codable {
    case active, paused, ended
}

public struct ScheduledDose: Sendable, Equatable {
    public var dueAt: Date
    public var doseUnits: Double
    public var mealRelation: String?
    public var notifyId: String        // dose-{planId}-{epochSlot}
    public init(dueAt: Date, doseUnits: Double, mealRelation: String? = nil, notifyId: String) {
        self.dueAt = dueAt; self.doseUnits = doseUnits; self.mealRelation = mealRelation
        self.notifyId = notifyId
    }
}

/// 计划状态闸门（BR-004 前置语义：paused/ended 期间不产生任何 ScheduledDose）
public enum ScheduleGate {
    public static func dosesAllowed(_ status: PlanStatus) -> Bool { status == .active }
}

/// 调度引擎（纯函数，注入 calendar/now，Linux 可单测）
public enum DoseScheduleEngine {
    /// 生成 [fromDay, toDay]（相对计划 startDate 的 1-based 日界）内的全部剂量。
    /// - 时间字符串 "HH:mm" 按注入时区解析；解析失败跳过并返回 skip 计数（绝不静默错位）
    /// - taper：阶段内 doseUnits 按 stage 取值；无匹配阶段的日期不产生剂量
    /// - cycle：dayOfCycle ∈ [1, daysOn] 才产生
    public static func doses(
        schedule: MedicationSchedule,
        planId: UUID,
        startDate: Date,
        fromDay: Int,
        toDay: Int,
        calendar: Calendar
    ) -> (doses: [ScheduledDose], skippedTimes: Int) {
        var out: [ScheduledDose] = []
        var skipped = 0
        func append(_ day: Int, _ time: String, _ units: Double, meal: String? = nil) {
            guard let due = Self.date(day: day, time: time, startDate: startDate, calendar: calendar) else {
                skipped += 1
                return
            }
            let slot = Int(due.timeIntervalSince1970)
            out.append(ScheduledDose(
                dueAt: due,
                doseUnits: units,
                mealRelation: meal,
                notifyId: "dose-\(planId.uuidString)-\(slot)"))
        }
        for day in fromDay...toDay {
            switch schedule {
            case .fixed(let times):
                for t in times { append(day, t, 1.0) }
            case .interval(let everyMinutes, let start):
                // BR-004 安全闸：非法参数（everyMinutes<=0）绝不进入死循环——跳过该日并计入 skip
                guard everyMinutes > 0 else { skipped += 1; continue }
                guard let startDate0 = Self.date(day: day, time: start, startDate: startDate, calendar: calendar) else { skipped += 1; continue }
                // 评审修正：日历加法失败（近乎不可达）原实现静默产出 0 剂且不计 skip，
                // 与「绝不静默错位」纪律相悖——改为计 skip 跳过该日
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: startDate0)
                else { skipped += 1; continue }
                var t = startDate0
                // 间隔给药按「绝对时间」推进：每 N 分钟就是每 N 真实分钟。
                // 夏令时**不做**墙钟补偿——补偿反而会制造 3 小时或 5 小时的真实给药间隔，
                // 对间隔给药是用药安全问题。切换日次数随当日真实长度自然增减
                // （dayEnd 取日历日 +1，即 23/25 小时），这是预期行为。
                // 分钟级单位下 calendar.date(byAdding:) 与 addingTimeInterval 结果等价
                // （实测已确认），此处取后者：本循环按剂量数迭代（每 30 分钟 × 30 天
                // ≈ 1440 次/计划），日历组件运算比一次浮点加法贵一个数量级。
                // 先转 TimeInterval 再乘，避免 everyMinutes 极大时 Int 乘法溢出陷阱。
                while t < dayEnd {
                    out.append(ScheduledDose(dueAt: t, doseUnits: 1.0, notifyId: "dose-\(planId.uuidString)-\(Int(t.timeIntervalSince1970))"))
                    t = t.addingTimeInterval(TimeInterval(everyMinutes) * 60)
                }
            case .meal(let relations):
                for r in relations { append(day, Self.mealDefaultTime(r), 1.0, meal: r) }
            case .asNeeded:
                break                                              // 按需不预排
            case .cycle(let everyDays, let daysOn):
                // 除零保护：everyDays<=0 直接跳过（不会让日程引擎崩溃）
                guard everyDays > 0 else { continue }
                let dayOfCycle = ((day - 1) % everyDays) + 1
                if dayOfCycle <= daysOn {
                    for t in ["08:00"] { append(day, t, 1.0) }
                }
            case .taper(let stages):
                for s in stages where day >= s.fromDay && day <= s.toDay {
                    for t in s.times { append(day, t, s.doseUnits) }
                }
            }
        }
        out.sort { $0.dueAt < $1.dueAt }
        return (out, skipped)
    }

    /// 餐时关系→默认时刻（确认 UI 可覆盖为 fixed；FR9.17 聚合容差 ±30min 以此时刻为锚）
    public static func mealDefaultTime(_ relation: String) -> String {
        switch relation {
        case "beforeBreakfast": return "07:30"
        case "afterBreakfast": return "08:30"
        case "beforeLunch": return "11:30"
        case "afterLunch": return "12:30"
        case "beforeDinner": return "17:30"
        case "afterDinner": return "19:30"
        default: return "08:00"
        }
    }

    static func date(day: Int, time: String, startDate: Date, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        let dayStart = calendar.startOfDay(for: startDate)
        guard let dayDate = calendar.date(byAdding: .day, value: day - 1, to: dayStart) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: dayDate)
    }
}
