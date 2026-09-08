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
    /// 剂量所属成员（BR-001：查询侧必须可过滤成员，不得跨成员混排；
    /// 对账引擎消费全量事实，UI 消费过滤后事实）
    public var patientId: UUID?
    public init(dose: ScheduledDose, delivered: Bool, action: DoseUserAction?,
                isDueSoon: Bool, isExpiredGrace: Bool,
                medicationName: String? = nil, spec: String? = nil, unitKind: String? = nil,
                patientId: UUID? = nil) {
        self.dose = dose; self.delivered = delivered; self.action = action
        self.isDueSoon = isDueSoon; self.isExpiredGrace = isExpiredGrace
        self.medicationName = medicationName; self.spec = spec; self.unitKind = unitKind
        self.patientId = patientId
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
    /// 负值 = 提前 N **日历日**（审查修复：原固定秒 -N×86400 在 DST
    /// 切换日偏差 ±1 小时，与 BatchExpiryRules 已统一的日历日纪律一致）
    public var offsetDays: Int
    /// day 档（offsetDays=0）当天近似时刻（小时；确认 UI 可覆盖）
    public var dayHour: Int?
    public init(label: String, offsetDays: Int, dayHour: Int? = nil) {
        self.label = label; self.offsetDays = offsetDays; self.dayHour = dayHour
    }
    public static let defaults: [AppointmentTier] = [
        .init(label: "7d", offsetDays: -7),
        .init(label: "3d", offsetDays: -3),
        .init(label: "1d", offsetDays: -1),
        .init(label: "day", offsetDays: 0, dayHour: 9),
    ]
}

public enum AppointmentRules {
    /// 预约改期 = 取消全部旧 tiers → 重排新 tiers（幂等）
    public static func tierFireDates(startsAt: Date, tiers: [AppointmentTier], now: Date,
                                     calendar: Calendar = .current) -> [AppointmentTier: Date] {
        var out: [AppointmentTier: Date] = [:]
        for t in tiers {
            var fire = calendar.date(byAdding: .day, value: t.offsetDays, to: startsAt) ?? startsAt
            if let hour = t.dayHour {
                fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: fire) ?? fire
            }
            if fire > now { out[t] = fire }               // 已过期的层级不补发
        }
        return out
    }

    /// 标记错过的时间门槛（FR10.7）：未到开始时间的预约不可标错过——错标会取消
    /// 全部分级提醒并提前武装 2h 跟进（误标未来预约 = 提醒失声）。
    /// 视图/商店共享本规则，不得各自内联 `startsAt <= now`。
    public static func canMarkMissed(startsAt: Date, now: Date = Date()) -> Bool {
        startsAt <= now
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

/// FR9.18 分通道偏好的投递判定（第七轮全仓审查修复：六类提醒三选一的偏好
/// 此前零生产消费方——用户选「静音仅横幅」仍按时锁屏响铃（假宣告）。
/// 本判定是系统通知投递门的 Domain 规则：notifyId 前缀 → 类别 → 偏好值；
/// 「inApp」= 不投递系统通知（应用内横幅是唯一通道）；「persistentRing」
/// 在 Critical Alerts 授权益落地（W4/P2）前按降级链落到 local 照常投递。
public enum ReminderChannelRules {
    /// notifyId → 类别偏好键（§5.44 六源）；未识别前缀返回 nil（消费侧回落
    /// 全局 remindChannel 缺省，绝不臆断类别）
    public static func categoryKey(for notifyId: String) -> AppSettingKey? {
        // 第八轮全仓审查修复（前缀分类表补全）：voice-rem-（语音提醒，归属
        // 用药类通道）与 alert-（F16 设备预警，对应 remch.alert 六类偏好项）
        // 此前漏登记——落回全局 remindChannel 缺省，各自类别偏好零效果。
        if notifyId.hasPrefix("dose-") || notifyId.hasPrefix("slot-") || notifyId.hasPrefix("snooze-")
            || notifyId.hasPrefix("voice-rem-") {
            return .remindChannelMeds
        }
        if notifyId.hasPrefix("apt-") || notifyId.hasPrefix("followup-apt-") {
            return .remindChannelApts
        }
        if notifyId.hasPrefix("followup-") { return .remindChannelExam }   // 观察随访
        if notifyId.hasPrefix("exp-") || notifyId.hasPrefix("refill-") { return .remindChannelExpiry }
        if notifyId.hasPrefix("backup-") { return .remindChannelBackup }
        if notifyId.hasPrefix("alert-") { return .remindChannelAlert }
        return nil
    }

    /// 是否投递系统通知。preference 取类别键对应值，未识别类别回落全局缺省；
    /// 非法值（含历史脏数据）不改变现状（照常投递）——绝不因偏好解读失败
    /// 而静默 P0 提醒。
    public static func shouldDeliverSystem(_ notifyId: String,
                                           preference: String?) -> Bool {
        preference != ReminderChannelKind.inApp.rawValue
    }

    /// 应用内横幅承接覆盖判定：§4.22 InAppBannerHost 只渲染今日时段内
    /// **未决**剂量（todaySlots · action == nil，且另有横幅总开关、约 2h
    /// 到期窗口等运行时过滤），即 dose-/slot- 二族。
    /// 只有此二族的系统投递抑制（「静音仅横幅」/横幅开关）才有应用内承接；
    /// snooze-（剂量已置 .snoozed，被横幅过滤排除）与 voice-rem-（非剂量
    /// 记录，永不在 todaySlots）虽归用药通道偏好，但无应用内承接——按
    /// §5.58「目标通道不可用自动降级」纪律照常系统投递（宁响铃、绝不静默
    /// 丢弃），待 W4 横幅通道扩展后逐类别收紧。第十轮曾把抑制集放宽到整个
    /// .remindChannelMeds 族，使稍后提醒/语音提醒落入零通道（前台无声无横幅、
    /// 后台/锁屏被排程门直接丢弃）——本判定即该修复的单一事实源。
    /// 注：本判定是「该族存在应用内承接」的静态近似；横幅总开关关闭等
    /// 运行时不可用由 suppressSystemDelivery/foregroundDelivery 的
    /// bannerEnabled 参数逐判定降级（见各函数文档）。
    public static func hasInAppBannerCoverage(_ notifyId: String) -> Bool {
        notifyId.hasPrefix("dose-") || notifyId.hasPrefix("slot-")
    }

    /// 排程时系统投递抑制判定（ChannelGatedScheduler 消费，与前台
    /// foregroundDelivery 同口径）。抑制必须三者同时成立：
    /// (a) 该通知有应用内横幅承接 (b) 横幅总开关开启——承接真实存在
    /// (c) 偏好为「静音仅横幅」；否则照常系统投递（§5.58「目标通道不可用
    /// 自动降级」，宁响铃绝不静默丢弃）。第十一轮审查：排程门此前只查
    /// (a)(c) 不查 (b)——用户把用药设为「静音仅横幅」后又关闭横幅总开关
    /// （两个设置控件互相独立）时，剂量通知排程即被丢弃、前台呈现亦静默、
    /// 应用内横幅因开关关闭不渲染，P0 服药提醒落入零通道。
    public static func suppressSystemDelivery(_ notifyId: String,
                                              bannerEnabled: Bool,
                                              preference: String?) -> Bool {
        guard hasInAppBannerCoverage(notifyId), bannerEnabled else { return false }
        return !shouldDeliverSystem(notifyId, preference: preference)
    }

    /// 前台系统呈现策略（Domain 纯规则；App 层映射为 UNNotificationPresentationOptions，
    /// Domain 不得 import UserNotifications）：
    /// - 非用药族 / 用药族无应用内横幅承接（snooze-/voice-rem-）→ 横幅+声音
    /// - 用药族且有承接 +「静音仅横幅」+ 横幅总开关开启 → 完全静默（用户
    ///   对静音的显式选择；开关关闭时应用内横幅不存在，降级为系统横幅+声音）
    /// - 有承接 + 横幅开关开启 + 「响铃直到确认」→ 仅声音（横幅由应用内横幅承接，避免双弹；声音保留）
    /// - 有承接 + 横幅开关开启 + 其余通道 → 静默（应用内横幅是唯一前台呈现）
    /// - 有承接 + 横幅开关关闭 + 非 inApp 通道 → 横幅+声音（应用内横幅已关，系统横幅须照常）
    public static func foregroundDelivery(for notifyId: String,
                                          bannerEnabled: Bool,
                                          medsPreference: String?) -> ForegroundDelivery {
        guard categoryKey(for: notifyId) == .remindChannelMeds,
              hasInAppBannerCoverage(notifyId) else {
            return .bannerAndSound
        }
        let preference = medsPreference ?? AppSettingKey.remindChannelMeds.defaultValue
        if preference == ReminderChannelKind.inApp.rawValue {
            return bannerEnabled ? .silent : .bannerAndSound
        }
        guard bannerEnabled else { return .bannerAndSound }
        return preference == ReminderChannelKind.persistentRing.rawValue ? .soundOnly : .silent
    }
}

/// 前台系统呈现策略的中性枚举（Domain 零框架依赖，App 层再映射到
/// UNNotificationPresentationOptions）。
public enum ForegroundDelivery: Sendable, Equatable {
    case bannerAndSound   // 系统横幅 + 声音
    case soundOnly        // 仅声音（横幅由应用内横幅承接）
    case silent           // 完全静默（用户「静音仅横幅」显式选择）
}
