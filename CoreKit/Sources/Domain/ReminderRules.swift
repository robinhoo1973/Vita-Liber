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
}
