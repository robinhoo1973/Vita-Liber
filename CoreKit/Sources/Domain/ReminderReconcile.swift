import Foundation

/// §5.4 对账决策（纯函数，可单测）：四层触发（启动/回前台/时区变更/BGTask）
/// 共用同一决策逻辑。输入 = 剂量的三个事实：是否已送达、用户动作、是否临期，
/// 输出 = 需要执行的动作。BR-004：已服不动；永不推断病因。
public enum ReconcileAction: Sendable, Equatable {
    case schedule                        // 未送达且临期 → 补排通知
    case markAwaitingUser                // 已送达且过宽限期 → 标记待用户处理
    case snooze(until: Date)             // 稍后提醒 = 取消原通知 + 新 trigger
    case none
}

public struct DoseDeliveryFact: Sendable, Equatable {
    public var dose: ScheduledDose
    public var delivered: Bool
    public var action: DoseUserAction?
    public var isDueSoon: Bool
    public var isExpiredGrace: Bool
    /// 药品定义投影（评审修正：UI 时段卡必须可区分多药——JOIN medication 带出）
    public var medicationName: String?
    public var spec: String?
    public var unitKind: String?
    public init(dose: ScheduledDose, delivered: Bool, action: DoseUserAction?,
                isDueSoon: Bool, isExpiredGrace: Bool,
                medicationName: String? = nil, spec: String? = nil, unitKind: String? = nil) {
        self.dose = dose; self.delivered = delivered; self.action = action
        self.isDueSoon = isDueSoon; self.isExpiredGrace = isExpiredGrace
        self.medicationName = medicationName; self.spec = spec; self.unitKind = unitKind
    }
}

public enum ReconcileEngine {
    /// §5.4 决策纯函数化：已服不动（BR-004）；
    /// 未送达且无动作 → （补）排——滚动预排窗口（7 天）内全部剂量都属于此支，
    /// 「临期」只是 isDueSoon 的查询侧提示，不是调度闸门；
    /// 已送达且过宽限期 → 标记待用户处理；跳过/忘记/不适不产生调度动作。
    public static func decide(_ f: DoseDeliveryFact, now: Date) -> ReconcileAction {
        switch (f.delivered, f.action) {
        case (_, .taken):
            return .none                                   // 已服不动（BR-004）
        case (false, nil):
            return .schedule
        case (true, nil) where f.isExpiredGrace:
            return .markAwaitingUser
        default:
            return .none
        }
    }

    /// 稍后提醒：目标时刻必须晚于 now，否则视为无效（返回 nil，调用侧不改状态）
    public static func snooze(until: Date, now: Date) -> ReconcileAction {
        until > now ? .snooze(until: until) : .none
    }

    /// 滚动预排窗口（iOS 64 pending 上限）：只预排未来 N 天；超限按优先级裁撤
    public static let preScheduleWindowDays = 7

    /// 优先级（对账裁撤顺序：用药 > 预约复诊 > 观察随访/临期）
    public enum Priority: Int, Sendable, Comparable {
        case medication = 0, appointment = 1, followUp = 2
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// 超限裁撤：把 pending 列表按优先级排序，截断到 budget 条
    public static func trim(_ pending: [(id: String, priority: Priority, fireAt: Date)], budget: Int) -> [String] {
        let sorted = pending.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.fireAt < $1.fireAt
        }
        guard sorted.count > budget else { return [] }
        return sorted.dropFirst(budget).map(\.id)
    }
}

/// 预约分级提醒（FR10.3 / §5.4 V3.31）：从 starts_at 反算四级触发点
public struct AppointmentTier: Sendable, Equatable, Hashable {
    public var label: String
    public var offsetSeconds: TimeInterval
    public init(label: String, offsetSeconds: TimeInterval) {
        self.label = label; self.offsetSeconds = offsetSeconds
    }
    public static let defaults: [AppointmentTier] = [
        .init(label: "7d", offsetSeconds: -7 * 86400),
        .init(label: "3d", offsetSeconds: -3 * 86400),
        .init(label: "1d", offsetSeconds: -86400),
        .init(label: "day", offsetSeconds: -4 * 3600),   // 当天 09:00 近似（确认 UI 可覆盖）
    ]
}

public enum AppointmentRules {
    /// 预约改期 = 取消全部旧 tiers → 重排新 tiers（幂等）
    public static func tierFireDates(startsAt: Date, tiers: [AppointmentTier], now: Date) -> [AppointmentTier: Date] {
        var out: [AppointmentTier: Date] = [:]
        for t in tiers {
            let fire = startsAt.addingTimeInterval(t.offsetSeconds)
            if fire > now { out[t] = fire }               // 已过期的层级不补发
        }
        return out
    }
}

/// 通道分层（FR9.18）降级矩阵：目标通道不可用 → InApp → Local → Persistent 顺序回退
public enum ReminderChannelKind: String, Sendable, Equatable, CaseIterable {
    case inApp, local, persistentRing, serverPush
}

public enum ChannelFallback {
    /// 降级矩阵（Domain 纯函数可单测）。serverPush 是 P1/D1，仅作目标不可用时的
    /// 显式回退目标，M1b 降级链不含它。
    public static func fallbackChain(from preferred: ReminderChannelKind) -> [ReminderChannelKind] {
        switch preferred {
        case .inApp: return [.inApp, .local, .persistentRing]
        case .local: return [.local, .inApp, .persistentRing]
        case .persistentRing: return [.persistentRing, .local, .inApp]
        case .serverPush: return [.local, .inApp, .persistentRing]
        }
    }

    /// 从候选链中选第一个「可用」通道；全不可用返回 nil（调用侧记 failed 送达）
    public static func resolve(preferred: ReminderChannelKind, availability: [ReminderChannelKind: Bool]) -> ReminderChannelKind? {
        fallbackChain(from: preferred).first { availability[$0] == true }
    }
}
