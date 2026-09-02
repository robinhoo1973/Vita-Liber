import Foundation
import Testing
@testable import Domain

/// M1.5 P0.5 · Domain 层验收用例（dev-pm §3.3 退出准则的 U 半场）
@Suite("M1.5 · 趋势语义（§5.29/F7）")
struct TrendServiceTests {
    @Test func 空心实心一眼可辨() {
        let hospital = TrendPoint(id: UUID(), measuredAt: Date(), value: 132, origin: .hospital)
        let manual = TrendPoint(id: UUID(), measuredAt: Date(), value: 128, origin: .manual)
        #expect(!hospital.isHollow)     // 医院实心
        #expect(manual.isHollow)        // 自测空心
    }

    @Test func 排除点软删与恢复语义() {
        var p = TrendPoint(id: UUID(), measuredAt: Date(), value: 200, origin: .manual, excluded: true)
        #expect(TrendRules.visible([p]).isEmpty, "排除点不得进聚合（保留原值可恢复）")
        p.excluded = false              // 恢复动作——原值保留
        #expect(TrendRules.visible([p]).count == 1)
    }

    @Test func 参考范围A级优先于B级() {
        let report = ReferenceRange(lower: 60, upper: 90, grade: .A)
        let library = ReferenceRange(lower: 65, upper: 85, grade: .B)
        #expect(TrendRules.resolveRange(reportRange: report, libraryRange: library) == report)
        #expect(TrendRules.resolveRange(reportRange: nil, libraryRange: library) == library)
        #expect(TrendRules.resolveRange(reportRange: nil, libraryRange: nil) == nil, "无来源=范围不可用（独立状态）")
    }

    @Test func 换算留痕不覆盖原值() {
        let conv = UnitConversion(fromUnit: "mmol/L", toUnit: "mg/dL", factor: 18.0,
                                  note: "换算自 mmol/L")
        let original = TrendPoint(id: UUID(), measuredAt: Date(), value: 6.0, origin: .manual)
        let series = TrendSeries(metricType: .glucose, points: [original])
        let converted = TrendRules.converted(series, using: conv)
        #expect(converted.points[0].value == 108.0)
        #expect(series.points[0].value == 6.0, "原值必须保留")
        #expect(conv.convert(6.0) == 108.0)
    }
}

// .serialized：NSRegularExpression 首次编译在 Linux ICU 上非线程安全——
// 并发创建曾致 SIGTRAP（libFoundation）；生产路径经 actor 串行化，测试同纪律
@Suite("M1.5 · 语音文法子集（§5.13/FR17.9-14）", .serialized)
struct VoiceGrammarTests {
    let metricRules = [
        MetricGrammarRule(metricKey: "glucose",
                          patterns: [#"血糖\s*(\d+(?:\.\d+)?|[一二两三四五六七八九十百点]+)"#],
                          unitDefault: "mmol/L"),
        MetricGrammarRule(metricKey: "blood_pressure_sys",
                          patterns: [#"高压\s*(\d+)"#, #"收缩压\s*(\d+)"#],
                          unitDefault: "mmHg"),
    ]
    let reminderRules = [
        ReminderGrammarRule(kind: "any",
                            timePatterns: [#"(明天|后天|今天)"#, #"(\d+)点"#],
                            repeatPatterns: [#"(每天|每周一|每周二)"#]),
    ]
    let profileRules = [
        ProfileGrammarRule(fieldKey: "allergy", patterns: [#"过敏[药史:：]*(.+)"#]),
        ProfileGrammarRule(fieldKey: "emergencyContact", patterns: [#"紧急联系人是(.+)"#]),
    ]

    @Test func 指标抽取与中文数字归一() {
        let drafts = VoiceStructuringEngine.extractMetric("今天血糖十三", rules: metricRules)
        #expect(drafts.contains { $0.key == "glucose" && $0.value == "13" })
    }

    /// 评审 S1 修正：混合形态（含点/零/大写）→ 原值保留 + 置信降 0.4 强制复核
    @Test func 混合形态原值保留且降置信() {
        let mixed = VoiceStructuringEngine.extractMetric("今天血糖十三点二", rules: metricRules)
        let draft = mixed.first { $0.key == "glucose" }
        #expect(draft != nil)
        #expect(draft!.value == "十三点二", "混合形态不得截断为 13")
        #expect(draft!.confidence == 0.4, "归一失败必须降置信强制复核")
    }

    @Test func 纯中文数字归一() {
        #expect(NumberNormalizer.normalize("一百三十二") == "132")
        #expect(NumberNormalizer.normalize("两") == "2")
        #expect(NumberNormalizer.normalize("6.8") == "6.8")
    }

    @Test func 指标抽取阿拉伯数字() {
        let drafts = VoiceStructuringEngine.extractMetric("高压132", rules: metricRules)
        #expect(drafts.contains { $0.key == "blood_pressure_sys" && $0.value == "132" })
    }

    @Test func 提醒时间与重复抽取() {
        let drafts = VoiceStructuringEngine.extractReminder("明天早上提醒我测血糖，每天", rules: reminderRules)
        #expect(drafts.contains { $0.key == "time" && $0.value == "明天" })
        #expect(drafts.contains { $0.key == "repeat" && $0.value == "每天" })
    }

    @Test func 档案访谈抽取() {
        let drafts = VoiceStructuringEngine.extractProfile("我过敏药：青霉素，紧急联系人是王女士", rules: profileRules)
        #expect(drafts.contains { $0.key == "allergy" && $0.value.contains("青霉素") })
        #expect(drafts.contains { $0.key == "emergencyContact" && $0.value.contains("王女士") })
    }

    @Test func 模板复用断言_语音草稿经统一确认集() {
        // FR17.13：四处确认必须走同一模板（VoiceInputTemplate.confirmationSet），
        // 产出全部待确认态（BR-003）——语音草稿绝不直接入正式数据
        let drafts = VoiceStructuringEngine.extractMetric("血糖6.2", rules: metricRules)
        let set = VoiceInputTemplate.confirmationSet(drafts: drafts)
        #expect(!set.isUsableInTimeline)
        #expect(set.fields.allSatisfy { $0.grade == .ocrUnconfirmed })
    }

    @Test func 模糊时间必须落具体日期() {
        let now = Date()
        let cal = Calendar.current
        #expect(VoiceReminderRules.resolveDate(phrase: "明天", now: now, calendar: cal) != nil)
        #expect(VoiceReminderRules.resolveDate(phrase: "周末", now: now, calendar: cal) == nil,
                "模糊时间不落具体日期=不产出（FR10.2）")
    }
}

@Suite("M1.5 · 提醒规则（FR9.11/FR8.10/FR13.10）")
struct ReminderRulesTests {
    @Test func 批次到期三级触发点() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expire = now.addingTimeInterval(20 * 86400)
        let fires = BatchExpiryRules.fireDates(expireAt: expire, now: now)
        #expect(fires.count == 2)   // 30 天前已过（不补发），7 天与 3 天两级
        #expect(fires[0].tier == .t7)
        #expect(fires[1].tier == .t3)
    }

    @Test func 过期批次不再提醒() {
        let now = Date()
        let expired = now.addingTimeInterval(-86400)
        #expect(BatchExpiryRules.fireDates(expireAt: expired, now: now).isEmpty)
    }

    /// BatchExpiryRules 的 DST 不变量（与 followUpDate 同纪律，评审修正）：
    /// 30 天档回推必须按日历日——固定 86400 秒的旧实现跨夏令时漂移 1 小时。
    /// 2026-03-06（EST）与 2026-04-05（EDT）之间恰好穿越 3/8 春季调时。
    @Test func 批次到期跨夏令时保持墙钟时刻() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 5; c.hour = 12; c.minute = 0
        guard let expire = cal.date(from: c) else { Issue.record("基准时刻构造失败"); return }
        let fires = BatchExpiryRules.fireDates(expireAt: expire,
                                               now: expire.addingTimeInterval(-90 * 86400),
                                               calendar: cal)
        guard let t30 = fires.first(where: { $0.tier == .t30 }) else {
            Issue.record("t30 档必须触发"); return
        }
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: t30.at)
        #expect(parts.month == 3 && parts.day == 6, "30 日历日回推，实得 \(parts.month ?? -1)/\(parts.day ?? -1)")
        #expect(parts.hour == 12 && parts.minute == 0,
                "跨 DST 后仍须是 12:00，实得 \(parts.hour ?? -1):\(parts.minute ?? -1)")
        // 反证：固定 86400 秒回推会落到 11:00——差异真实存在
        #expect(t30.at != expire.addingTimeInterval(-30 * 86400),
                "若与 −30×86400 秒相等，说明日历回推没有生效")
    }

    @Test func 观察随访提醒节奏() {
        // UTC 无夏令时，日历日 == 86400 秒，可用秒数表达期望值；
        // 天数引用规则常量而非字面量 3/7——规则改了测试要跟着红，而不是继续绿着测旧公式
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let observed = Date(timeIntervalSince1970: 0)
        let first = ObservationFollowUpRules.firstFollowUpDays
        let step = ObservationFollowUpRules.repeatIntervalDays
        #expect(ObservationFollowUpRules.followUpDate(from: observed, occurrence: 0, calendar: utc)
                == observed.addingTimeInterval(TimeInterval(first) * 86400))
        #expect(ObservationFollowUpRules.followUpDate(from: observed, occurrence: 2, calendar: utc)
                == observed.addingTimeInterval(TimeInterval(first + 2 * step) * 86400))
    }

    /// FR8.10 的 DST 不变量：随访提醒必须落在**同一墙钟时刻**，而不是同一绝对秒数。
    /// 这条正是 followUpDate 改用日历推进的理由，注入日历后才可测。
    @Test func 观察随访跨夏令时保持墙钟时刻() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-05 09:00 EST，+3 天跨越 3/8 的春季调时
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 5; c.hour = 9; c.minute = 0
        guard let observed = cal.date(from: c) else { Issue.record("基准时刻构造失败"); return }
        let followUp = ObservationFollowUpRules.followUpDate(from: observed, occurrence: 0, calendar: cal)
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: followUp)
        #expect(parts.hour == 9 && parts.minute == 0, "跨 DST 后仍须是 09:00，实得 \(parts.hour ?? -1):\(parts.minute ?? -1)")
        #expect(parts.day == 8 && parts.month == 3)
        // 固定 86400 秒的旧写法会落到 10:00——用绝对秒数比较可证明差异真实存在
        #expect(followUp != observed.addingTimeInterval(3 * 86400),
                "若与 +3×86400 秒相等，说明日历推进没有生效")
    }

    @Test func 定期备份提醒() {
        let now = Date()
        #expect(BackupReminderRules.needsReminder(lastBackupAt: nil, now: now))   // 从未备份
        #expect(BackupReminderRules.needsReminder(lastBackupAt: now.addingTimeInterval(-31 * 86400), now: now))
        #expect(!BackupReminderRules.needsReminder(lastBackupAt: now.addingTimeInterval(-10 * 86400), now: now))
    }
}
