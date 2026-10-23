import Foundation

/// 档案完善进度规则（首页进度卡 · mock 对齐项，结构轮 2026-09-15 自
/// AppState 迁入）：字段集合与计数语义是 Domain 规则（tech-spec §1.1 规则 4）——
/// 此前内联在 @MainActor AppState，测试必须组装整个 App 状态才能断言；
/// 迁移后以纯函数单测（P7）。
public enum MemberProfileCompleteness {
    /// 生日精度下限（2026-09-26 业主裁决 3）：结构控件只允许 1900-01-01 起。
    /// 与本类型同源的公历日历（每访问取当前时区——静态缓存会冻结到首次访问时的时区，
    /// 跨时区变更后渲染出旧日的日期；与 `EntityCardProjection.canonicalDateText` 同口径）。
    public static let birthDateEarliest = birthDateCalendar.date(from: DateComponents(year: 1900, month: 1, day: 1))!

    /// 生日规范日历（2026-09-26 审查修复：原实现用 UTC 钉死的 DateFormatter 渲染
    /// DatePicker 落库串——东八区等正偏移时区上午选择/保存的生日静默少一天，
    /// 「今天」串在本地凌晨时段又被 `parsed <= Date()` 误拒；改为公历 + 当前时区，
    /// 与 `EntityCardProjection.canonicalDateText` 同一口径）。
    private static var birthDateCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// 生日字段有效性（业主裁决 3，2026-09-26）：只认 `yyyy-MM-dd` 或 `yyyy` 两种精度形态
    /// （与 HealthCharacteristicImport 的 FR3.1 精度口径同源），且日期落在
    /// 1900-01-01 … 今天 的闭区间内。非空但非法的存量值（如 "abc"、"2023-02-30"）无效——
    /// 不计完整度，详情页提示补录；不做存量迁移（读时忽略，BR-002 原始数据原则）。
    public static func isValidBirthDate(_ value: String, in timeZone: TimeZone? = nil) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 4, let year = Int(trimmed),
           (1900...currentYear(in: timeZone)).contains(year) {
            return true
        }
        guard trimmed.count == 10, let parsed = parsedBirthDate(trimmed, in: timeZone) else { return false }
        return parsed >= birthDateEarliest && parsed <= Date()
    }

    /// 合法 `yyyy-MM-dd` 串 → 本地公历当日零点（详情页补录编辑器初值，2026-09-26
    /// 审查补充）；非法/空串返回 nil——调用方以今天作 picker 初始值展示，未经
    /// 显式选择不落库。归一化伪日期（如 02-30）经往返一致检查拒绝，与
    /// `isValidBirthDate` 同一判据。
    public static func parsedBirthDate(_ value: String, in timeZone: TimeZone? = nil) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard trimmed.count == 10, parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var calendar = birthDateCalendar
        if let timeZone { calendar.timeZone = timeZone }
        guard let parsed = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              birthDateString(from: parsed, in: timeZone) == trimmed else { return nil }
        return parsed
    }

    /// DatePicker 落库字符串（与 Health 导入同口径的 `yyyy-MM-dd`；公历、给定时区当日）。
    public static func birthDateString(from date: Date, in timeZone: TimeZone? = nil) -> String {
        var calendar = birthDateCalendar
        if let timeZone { calendar.timeZone = timeZone }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// 完整出生日期（`yyyy-MM-dd`，精度足够）→ 周岁；只有年份的档案返回
    /// nil（FR3.1：年龄仅在日期精度足够时计算，急救页否则仅显示出生年份）。
    public static func ageYears(birthDate: String?, now: Date = Date(),
                                calendar: Calendar = .current) -> Int? {
        guard let birthDate, let birth = parsedBirthDate(birthDate),
              birth >= birthDateEarliest, birth <= now else { return nil }
        guard let years = calendar.dateComponents([.year], from: birth, to: now).year,
              years >= 0 else { return nil }
        return years
    }

    /// 出生年份（`yyyy` 或 `yyyy-MM-dd`）——年龄不可算时急救页展示的替代事实。
    /// 非空但非法的存量值返回 nil（读时忽略，不臆断）。
    public static func birthYear(_ birthDate: String?, in timeZone: TimeZone? = nil) -> Int? {
        guard let birthDate else { return nil }
        let trimmed = birthDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBirthDate(trimmed, in: timeZone) else { return nil }
        return Int(trimmed.prefix(4))
    }

    private static func currentYear(in timeZone: TimeZone? = nil) -> Int {
        var calendar = Calendar.current
        if let timeZone { calendar.timeZone = timeZone }
        return calendar.component(.year, from: Date())
    }

    /// 血型（非空即完成）+ 生日（非空且**合法**才完成）= 2 项。
    /// 身份证件号/医保号已按业主 2026-10-22 要求停止收集与显示，不计入档案完善度。
    /// 空白串不计完成（trim 后判空）；nil 表示档案未加载/已不存在——
    /// 首页不生成虚假的 0/2 提示或占位。
    public static func progress(profile: PatientProfile?, total: Int = 2) -> (done: Int, total: Int)? {
        guard let profile, profile.deletedAt == nil else { return nil }
        let done = [profile.bloodType].filter {
            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }.count
        let birthDone = profile.birthDate.map { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isValidBirthDate(value)
        } ?? false
        return (done + (birthDone ? 1 : 0), total)
    }


}
