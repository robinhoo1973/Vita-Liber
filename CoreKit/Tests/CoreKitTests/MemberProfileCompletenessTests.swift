import Foundation
import Testing
@testable import Domain

/// 业主裁决 3（2026-09-26）：生日字段有效性 + 完整度只认合法日期。
/// 规则：`yyyy`（1900…今年）或 `yyyy-MM-dd`（1900-01-01…今天，拒绝归一化日期如 02-30）；
/// 非空但非法的存量值不计完成度（不迁移数据，读时忽略）。
struct MemberProfileCompletenessTests {

    @Test func birthDateValidityAcceptsBothPrecisionForms() {
        let valid = MemberProfileCompleteness.isValidBirthDate
        #expect(valid("1990"))                      // 年份精度（FR3.1 口径）
        #expect(valid("1990-05-12"))                // 完整日期
        #expect(valid(" 1990-05-12 "))              // trim 后合法
        #expect(valid("1900-01-01"))                // 下边界
    }

    @Test func birthDateValidityRejectsJunkAndNormalizedDates() {
        let valid = MemberProfileCompleteness.isValidBirthDate
        #expect(!valid(""))
        #expect(!valid("   "))
        #expect(!valid("abc"))
        #expect(!valid("2023-02-30"))               // DateFormatter 会归一化，必须往返一致
        #expect(!valid("1899"))                     // 早于 1900
        #expect(!valid("1899-12-31"))
        #expect(!valid("9999-01-01"))               // 晚于今天
        #expect(!valid("1962-03"))                  // 占位符里的旧示例格式并不合法
    }

    @Test func completenessCountsBirthOnlyWhenValid() {
        func done(_ birth: String?) -> Int {
            MemberProfileCompleteness.progress(
                profile: PatientProfile(displayName: "A", relation: "本人", birthDate: birth, bloodType: "A+"),
                interviewCompleted: [])!.done
        }
        #expect(done(nil) == 1)                     // 仅血型
        #expect(done("") == 1)                      // 空串不计
        #expect(done("   ") == 1)                   // 空白不计
        #expect(done("1990") == 2)                  // 合法年份计
        #expect(done("1990-05-12") == 2)            // 合法日期计
        #expect(done("abc") == 1)                   // 非法不计（裁决 3）
        #expect(done("2023-02-30") == 1)            // 归一化伪日期不计
        #expect(done("1962-03") == 1)               // 非规范格式不计
    }

    @Test func deletedProfileYieldsNoProgress() {
        var profile = PatientProfile(displayName: "A", relation: "本人")
        profile.deletedAt = 123
        #expect(MemberProfileCompleteness.progress(profile: profile, interviewCompleted: []) == nil)
    }

    @Test func birthDateStringRoundTripsAsValid() {
        let rendered = MemberProfileCompleteness.birthDateString(from: .now)
        #expect(rendered.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
        #expect(MemberProfileCompleteness.isValidBirthDate(rendered))
        // 渲染串必须等于源 Date 的本地公历日（审查修复：原 UTC 钉死 formatter 在
        // 正偏移时区把上午的日期渲染成前一天，此断言在非 UTC 时区主机上会抓出回归）
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.dateComponents([.year, .month, .day], from: .now)
        let expected = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        #expect(rendered == expected)
    }

    /// 审查修复回归钉：DatePicker 保留打开时刻（本地凌晨）的语义下，渲染必须是
    /// 给定时区的当天；旧 UTC 实现在 UTC+8 渲染为前一天。时区显式注入
    /// （CI 36249512459 修复：`TimeZone.current` 在 Darwin 是进程启动缓存、
    /// 不随 `NSTimeZone.default` 变化——Linux corelibs 跟随才让旧写法假绿；
    /// 注入参数两平台确定性一致，且无需 .serialized 串行）。
    @Test func birthDateStringKeepsLocalCalendarDayInPositiveOffsetZone() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // UTC 1990-05-11T16:30Z = 上海 1990-05-12 00:30 —— 渲染必须落在上海的「当天」
        let lateEveningUTC = utc.date(from: DateComponents(year: 1990, month: 5, day: 11, hour: 16, minute: 30))!
        #expect(MemberProfileCompleteness.birthDateString(from: lateEveningUTC, in: shanghai) == "1990-05-12")
        // 「今天」串在东八区凌晨时段也必须有效（旧 UTC 解析把今天判成未来而误拒）
        let today = MemberProfileCompleteness.birthDateString(from: Date(), in: shanghai)
        #expect(MemberProfileCompleteness.isValidBirthDate(today))
    }
}
