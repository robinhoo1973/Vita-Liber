import Foundation

/// M1.5 提醒规则扩展（FR9.11 批次到期三级 / FR8.10 观察随访 / FR13.10 定期备份）。
/// Domain 纯函数：规则判定与提醒草稿构造，调度经既有 ReminderScheduling 通道。
public enum BatchExpiryTier: String, Sendable, Equatable, Codable {
    // 审查修复（spec 对齐，FR9.11 权威文案「提前 30 天 / 7 天 / 当日」）：
    // 原 t3（提前 3 天）为规格外档，且 fire < expireAt 使「当日」语义永远
    // 不可触达——到期前 2 天至到期日整段无任何临期通知
    case t30, t7, t0
}

public struct BatchExpiryRules {
    /// 三级触发点（FR9.11）：expire_at 前 30/7/3 天各一次
    public static let daysBefore: [BatchExpiryTier: Int] = [
        .t30: 30, .t7: 7, .t0: 0,
    ]

    /// 已过期批次不再提醒（到期即止）；触发点已过不补发。
    ///
    /// 评审修正（DST 纪律统一）：原实现用固定 `-N×86400` 秒回推——30 天档在
    /// 有夏令时的时区必然穿越一次调时，触发时刻漂移 1 小时，与本文件
    /// `ObservationFollowUpRules` 的日历日纪律自相矛盾。现按日历日回推并注入
    /// calendar（与 `DoseScheduleEngine`/`VoiceReminderRules` 同一纪律，可单测）。
    public static func fireDates(expireAt: Date, now: Date,
                                 calendar: Calendar = .current) -> [(tier: BatchExpiryTier, at: Date)] {
        daysBefore.compactMap { tier, days in
            guard let fire = calendar.date(byAdding: .day, value: -days, to: expireAt) else { return nil }
            // 当日档 fire == expireAt；已过触发点不补发
            return (fire >= now && fire <= expireAt) ? (tier, fire) : nil
        }.sorted { $0.at < $1.at }
    }

    /// 提醒草稿（写通用 Reminder 实体）
    public static func draft(lotName: String, expireAt: Date, tier: BatchExpiryTier) -> String {
        "药品「\(lotName)」\(tier.rawValue == "t30" ? "一个月后" : tier.rawValue == "t7" ? "7 天后" : "今天")到期（\(expireAt.formatted(date: .abbreviated, time: .omitted))）"
    }
}

public enum ObservationFollowUpRules {
    /// FR8.10：观察记录后定期对比提醒——默认 3 天后首访、此后每周（可配置）
    public static let firstFollowUpDays = 3
    public static let repeatIntervalDays = 7

    /// - Parameter calendar: 注入日历（与 `DoseScheduleEngine`/`VoiceReminderRules` 同一纪律）。
    ///   写死 `Calendar.current` 会让「跨夏令时是否漂移」这条正是本函数存在理由的性质
    ///   无法单测——测试跑在哪台机器的时区上就测哪个时区，等于不测。
    public static func followUpDate(from observedAt: Date, occurrence: Int,
                                    calendar: Calendar = .current) -> Date {
        // FR8.10：首访 = firstFollowUpDays（默认 3 天），此后每 repeatIntervalDays（默认 7 天）累加；
        // occurrence 为 0-based 计数，第 n 次随访 = 首访 + n×周期间隔。
        // DST 安全：按日历日推进（与 DoseScheduleEngine 同一纪律）——固定 86400 秒跨
        // 夏令时切换会漂移 1 小时，随访提醒时刻错位。
        let days = firstFollowUpDays + max(0, occurrence) * repeatIntervalDays
        guard let byCalendar = calendar.date(byAdding: .day, value: days, to: observedAt) else {
            // 兜底（评审修正注释与实现对齐）：日历加法失败是「日历对象本身不可用」的
            // 近乎不可达分支——此时任何按日历锚点重算的尝试同样不可信，只能退回
            // 固定 86400 秒作为最后手段，绝不返回 nil 也不静默吞掉随访。
            return observedAt.addingTimeInterval(TimeInterval(days) * 86_400)
        }
        return byCalendar
    }
}

public enum BackupReminderRules {
    /// FR13.10：定期备份提醒——距上次备份超过 30 天提醒（可配置）
    public static let defaultIntervalDays = 30

    public static func needsReminder(lastBackupAt: Date?, now: Date, intervalDays: Int = defaultIntervalDays,
                                     calendar: Calendar = .current) -> Bool {
        guard let last = lastBackupAt else { return true }   // 从未备份 → 提醒
        // 审查修复（DST）：日历日推进替代固定 86400 秒（切换日偏差 ±1 小时）
        guard let due = calendar.date(byAdding: .day, value: intervalDays, to: last) else { return true }
        return now >= due
    }
}

/// 语音提醒设定（FR17.10）：模糊时间必须落具体日期（FR10.2 规则）——不落不产出
public enum VoiceReminderRules {
    /// 相对时间短语 → 具体日期（「明天」「明早」「后天」「今天」）。
    /// 评审修正（文档与实现对齐）：注释此前声称支持「下周一」，实现与
    /// `VoiceGrammarDefaults.reminderRules` 均未支持——FR10.2 下「不落不产出」
    /// 是正确行为，错的是文档。周几类短语属明确需求，应先在文法表登记再实现。
    public static func resolveDate(phrase: String, now: Date, calendar: Calendar = .current) -> Date? {
        switch phrase {
        case "明天", "明早": return calendar.date(byAdding: .day, value: 1, to: now)
        case "后天": return calendar.date(byAdding: .day, value: 2, to: now)
        case "今天": return now
        default: return nil   // 模糊时间不落具体日期 = 不产出（FR10.2）
        }
    }

    /// 草稿集 → 具体触发时刻。日期来源三选一：`date`（具体月日）优先、
    /// `time`（相对短语），`hour` 字段（若有）给时刻；
    /// 任一环节无法落具体值即返回 nil，由 UI 要求补充——**绝不猜时间**，
    /// 猜错的提醒比没有提醒更糟（用户以为已设好而错过）。
    public static func resolveDate(from drafts: [FieldDraft], now: Date,
                                   calendar: Calendar = .current) -> Date? {
        // 具体日期（"9 10" = 9月10日）优先——年份取当前（已过则顺延一年）
        if let dateValue = drafts.first(where: { $0.key == "date" })?.value {
            let parts = dateValue.split(separator: " ").compactMap { Int($0) }
            guard parts.count == 2, (1...12).contains(parts[0]),
                  (1...31).contains(parts[1]) else { return nil }
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = parts[0]; comps.day = parts[1]
            guard let built = calendar.date(from: comps) else { return nil }
            // 审查修复（FR10.2 绝不猜时间）：Calendar 对非法月日（2月30/4月31）
            // 静默进位到下月——回读校验月日一致，不一致即拒绝并交 UI 澄清，
            // 「猜错的提醒比没有提醒更糟」。
            let check = calendar.dateComponents([.month, .day], from: built)
            guard check.month == parts[0], check.day == parts[1] else { return nil }
            var day = built
            // 审查修复（P0）：按「天」比较——原以午夜时刻与 now 比较，
            // 今天/过去的日期恒被顺延一年（语音设定当天提醒系统性失效）
            if calendar.startOfDay(for: day) < calendar.startOfDay(for: now) {
                day = calendar.date(byAdding: .year, value: 1, to: day) ?? day
            }
            guard let hourText = drafts.first(where: { $0.key == "hour" })?.value else { return day }
            guard let hour = Int(hourText), (0...23).contains(hour) else { return nil }
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        }
        // 相对日期短语（明天/后天/今天）
        guard let phrase = drafts.first(where: { $0.key == "time" })?.value,
              let day = resolveDate(phrase: phrase, now: now, calendar: calendar)
        else { return nil }
        // hour 字段缺失：日期已具体（如「明天」），允许按当天设提醒，不猜时刻
        guard let hourText = drafts.first(where: { $0.key == "hour" })?.value else { return day }
        // hour 字段存在但无法解析为合法时刻（如「25」）→ 返回 nil（绝不猜 00:00，
        // 由 UI 要求澄清）；猜错的提醒比没有提醒更糟（FR10.2）
        guard let hour = Int(hourText), (0...23).contains(hour) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }
}

/// 日历日偏移的统一出口（DST 纪律）：固定 86400 秒在切换日偏差 ±1 小时。
/// 审查修复：Infrastructure/视图层多处仍用 +N*86400（预排窗口/合并窗口/
/// 检索窗口），与 Domain 已定的日历日纪律漂移——全部走本出口。
public enum DayArithmetic {
    public static func offset(days: Int, from date: Date = Date(),
                              calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)
            ?? date.addingTimeInterval(TimeInterval(days) * 86400)
    }

    /// days 天前的 Unix 时刻（检索窗口用）
    public static func since(days: Int, now: Date = Date(),
                             calendar: Calendar = .current) -> TimeInterval {
        offset(days: -days, from: now, calendar: calendar).timeIntervalSince1970
    }
}

/// FR17.10 重复短语 → 触发组件（与 VoiceGrammarDefaults.repeatPatterns
/// 同一事实源——文法里登记的短语这里必须可映射，禁止两套词表）。
public enum VoiceRepeatRules {
    /// 返回 weekday 集合（Calendar：1=周日…7=周六）；空数组 = 每天。
    /// nil = 未知短语（调度层回落一次性，绝不猜语义——FR10.2 同款纪律）。
    public static func weekdays(for phrase: String, fireWeekday: Int) -> [Int]? {
        switch phrase {
        case "每天", "每日": return []
        case "每周一": return [2]
        case "每周二": return [3]
        case "每周三": return [4]
        case "每周四": return [5]
        case "每周五": return [6]
        case "每周六": return [7]
        case "每周日", "每周天": return [1]
        case "每周": return [fireWeekday]
        case "工作日": return [2, 3, 4, 5, 6]
        case "周末": return [1, 7]
        default: return nil
        }
    }
}

/// **M1.5 文法子集的唯一事实源**（FR17.9–17.14）。
///
/// 为什么必须在 Domain 而不是各自定义：规则表此前只存在于测试文件里，
/// 生产代码没有任何可用的文法——「测试通过但功能不存在」。同一份规则被
/// 生产与测试共用，才能保证金样定标结果对生产有效（否则测的是另一套语法）。
/// 与 GuidelineSource「医学数字单一事实源」同一取向。
public enum VoiceGrammarDefaults {
    public static let metricRules: [MetricGrammarRule] = [
        MetricGrammarRule(metricKey: "glucose",
                          patterns: [#"血糖\s*(\d+(?:\.\d+)?|[一二两三四五六七八九十百点]+)"#,
                                     #"血糖仪?\s*([一二两三四五六七八九十百点]+\s*[点\.]\s*[一二两三四五六七八九十]+)"#],
                          unitDefault: "mmol/L"),
        MetricGrammarRule(metricKey: "blood_pressure_sys",
                          patterns: [#"高压\s*(\d+)"#, #"收缩压\s*(\d+)"#,
                                     // FR7.10 例句「血压 148 92 心率 76」——分隔符允许
                                     // 空格、斜杠、全角／；先抽收缩压再抽舒张压靠捕获组位置
                                     #"血压\s*(\d+)\s*(?:[/／]|\s)\s*(\d+)"#],
                          unitDefault: "mmHg"),
        MetricGrammarRule(metricKey: "blood_pressure_dia",
                          patterns: [#"低压\s*(\d+)"#, #"舒张压\s*(\d+)"#,
                                     #"血压\s*\d+\s*(?:[/／]|\s)\s*(\d+)"#],
                          unitDefault: "mmHg"),
        MetricGrammarRule(metricKey: "heart_rate",
                          patterns: [#"心率\s*(\d+)"#, #"脉搏\s*(\d+)"#],
                          unitDefault: "次/分"),
        MetricGrammarRule(metricKey: "weight",
                          patterns: [#"体重\s*(\d+(?:\.\d+)?|[一二两三四五六七八九十百点]+)"#],
                          unitDefault: "kg"),
        MetricGrammarRule(metricKey: "blood_oxygen",
                          patterns: [#"血氧\s*(\d+)"#],
                          unitDefault: "%"),
        MetricGrammarRule(metricKey: "temperature",
                          patterns: [#"体温\s*(\d+(?:\.\d+)?)"#, #"发烧\s*(\d+(?:\.\d+)?)"#],
                          unitDefault: "℃"),
    ]

    public static let reminderRules: [ReminderGrammarRule] = [
        ReminderGrammarRule(kind: "any",
                            timePatterns: [#"(明天|明早|后天|今天)"#],
                            repeatPatterns: [#"(每天|每日|每周一|每周二|每周三|每周四|每周五|每周六|每周日|周一|周二|周三|周四|周五|周六|周日|每周|工作日|周末)"#],
                            hourPatterns: [#"(\d+)点"#, #"([上下]午)"#],
                            datePatterns: [#"(\d{1,2})月(\d{1,2})[日号]"#]),
        ReminderGrammarRule(kind: "selfTest",
                            timePatterns: [#"(明天|后天|今天)"#],
                            repeatPatterns: [#"(每天|每周)"#],
                            hourPatterns: [#"(\d+)点"#],
                            datePatterns: [#"(\d{1,2})月(\d{1,2})[日号]"#]),
    ]

    public static let profileRules: [ProfileGrammarRule] = [
        ProfileGrammarRule(fieldKey: "allergy", patterns: [#"过敏[药史:：]*(.+)"#, #"对(.+?)过敏"#]),
        ProfileGrammarRule(fieldKey: "pastHistory", patterns: [#"(?:得过|做过)(.+)"#,
                                                               #"(?:有|患过)(.+?(?:病|症))"#]),
        ProfileGrammarRule(fieldKey: "currentMeds", patterns: [#"(?:在吃|正在吃|吃着)(.+)"#]),
        ProfileGrammarRule(fieldKey: "emergencyContact", patterns: [#"紧急联系人是(.+)"#]),
        ProfileGrammarRule(fieldKey: "surgery", patterns: [#"(?:做过|动过)(.+?手术)"#]),
        ProfileGrammarRule(fieldKey: "familyHistory", patterns: [#"家里(?:有|得过)(.+)"#]),
    ]
}
