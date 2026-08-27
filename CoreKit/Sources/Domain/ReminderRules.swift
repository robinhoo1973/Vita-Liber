import Foundation

/// M1.5 提醒规则扩展（FR9.11 批次到期三级 / FR8.10 观察随访 / FR13.10 定期备份）。
/// Domain 纯函数：规则判定与提醒草稿构造，调度经既有 ReminderScheduling 通道。
public enum BatchExpiryTier: String, Sendable, Equatable, Codable {
    case t30, t7, t3            // 到期前 30/7/3 天三级提醒
}

public struct BatchExpiryRules {
    /// 三级触发点（FR9.11）：expire_at 前 30/7/3 天各一次
    public static let offsets: [BatchExpiryTier: TimeInterval] = [
        .t30: -30 * 86400,
        .t7: -7 * 86400,
        .t3: -3 * 86400,
    ]

    /// 已过期批次不再提醒（到期即止）；触发点已过不补发
    public static func fireDates(expireAt: Date, now: Date) -> [(tier: BatchExpiryTier, at: Date)] {
        offsets.compactMap { tier, offset in
            let fire = expireAt.addingTimeInterval(offset)
            return (fire > now && fire < expireAt) ? (tier, fire) : nil
        }.sorted { $0.at < $1.at }
    }

    /// 提醒草稿（写通用 Reminder 实体）
    public static func draft(lotName: String, expireAt: Date, tier: BatchExpiryTier) -> String {
        "药品「\(lotName)」\(tier.rawValue == "t30" ? "一个月后" : tier.rawValue == "t7" ? "7 天后" : "3 天后")到期（\(expireAt.formatted(date: .abbreviated, time: .omitted))）"
    }
}

public enum ObservationFollowUpRules {
    /// FR8.10：观察记录后定期对比提醒——默认 3 天后首访、此后每周（可配置）
    public static let firstFollowUpDays = 3
    public static let repeatIntervalDays = 7

    public static func followUpDate(from observedAt: Date, occurrence: Int) -> Date {
        let days = occurrence == 0 ? firstFollowUpDays : repeatIntervalDays
        return observedAt.addingTimeInterval(TimeInterval(days * 86400))
    }
}

public enum BackupReminderRules {
    /// FR13.10：定期备份提醒——距上次备份超过 30 天提醒（可配置）
    public static let defaultIntervalDays = 30

    public static func needsReminder(lastBackupAt: Date?, now: Date, intervalDays: Int = defaultIntervalDays) -> Bool {
        guard let last = lastBackupAt else { return true }   // 从未备份 → 提醒
        return now.timeIntervalSince(last) >= TimeInterval(intervalDays * 86400)
    }
}

/// 语音提醒设定（FR17.10）：模糊时间必须落具体日期（FR10.2 规则）——不落不产出
public enum VoiceReminderRules {
    /// 相对时间短语 → 具体日期（「明天」「后天」「下周一」）
    public static func resolveDate(phrase: String, now: Date, calendar: Calendar = .current) -> Date? {
        switch phrase {
        case "明天", "明早": return calendar.date(byAdding: .day, value: 1, to: now)
        case "后天": return calendar.date(byAdding: .day, value: 2, to: now)
        case "今天": return now
        default: return nil   // 模糊时间不落具体日期 = 不产出（FR10.2）
        }
    }

    /// 草稿集 → 具体触发时刻。`time` 字段给日期，`hour` 字段（若有）给时刻；
    /// 任一环节无法落具体值即返回 nil，由 UI 要求补充——**绝不猜时间**，
    /// 猜错的提醒比没有提醒更糟（用户以为已设好而错过）。
    public static func resolveDate(from drafts: [FieldDraft], now: Date,
                                   calendar: Calendar = .current) -> Date? {
        guard let phrase = drafts.first(where: { $0.key == "time" })?.value,
              let day = resolveDate(phrase: phrase, now: now, calendar: calendar)
        else { return nil }
        guard let hourText = drafts.first(where: { $0.key == "hour" })?.value,
              let hour = Int(hourText), (0...23).contains(hour)
        else { return day }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
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
                            timePatterns: [#"(明天|明早|后天|今天)"#, #"(\d+)点"#,
                                           #"([上下]午)"#],
                            repeatPatterns: [#"(每天|每日|每周一|每周二|每周三|每周四|每周五|每周六|每周日|周一|周二|周三|周四|周五|周六|周日|每周|工作日|周末)"#]),
        ReminderGrammarRule(kind: "selfTest",
                            timePatterns: [#"(明天|后天|今天)"#],
                            repeatPatterns: [#"(每天|每周)"#]),
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
