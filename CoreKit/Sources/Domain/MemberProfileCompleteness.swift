import Foundation

/// 档案完善进度规则（首页进度卡 · mock 对齐项，结构轮 2026-09-15 自
/// AppState 迁入）：字段集合与计数语义是 Domain 规则（tech-spec §1.1 规则 4）——
/// 此前内联在 @MainActor AppState，测试必须组装整个 App 状态才能断言；
/// 迁移后以纯函数单测（P7）。
public enum MemberProfileCompleteness {
    /// 语音访谈四段（过敏/既往史/当前用药/紧急联系人）——FR17.11/BR-001
    /// 按成员持久化的完成步骤键，与 AppState 持久化键同源。
    public static let voiceInterviewKeys: Set<String> = ["allergy", "pastHistory", "currentMeds", "emergencyContact"]

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
    public static func isValidBirthDate(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 4, let year = Int(trimmed),
           (1900...currentYear()).contains(year) {
            return true
        }
        guard trimmed.count == 10, let parsed = parsedBirthDate(trimmed) else { return false }
        return parsed >= birthDateEarliest && parsed <= Date()
    }

    /// 合法 `yyyy-MM-dd` 串 → 本地公历当日零点（详情页补录编辑器初值，2026-09-26
    /// 审查补充）；非法/空串返回 nil——调用方以今天作 picker 初始值展示，未经
    /// 显式选择不落库。归一化伪日期（如 02-30）经往返一致检查拒绝，与
    /// `isValidBirthDate` 同一判据。
    public static func parsedBirthDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard trimmed.count == 10, parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let parsed = birthDateCalendar.date(from: DateComponents(year: y, month: m, day: d)),
              birthDateString(from: parsed) == trimmed else { return nil }
        return parsed
    }

    /// DatePicker 落库字符串（与 Health 导入同口径的 `yyyy-MM-dd`；公历、给定时区当日）。
    public static func birthDateString(from date: Date) -> String {
        let parts = birthDateCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    private static func currentYear() -> Int {
        Calendar.current.component(.year, from: Date())
    }

    /// 血型/证件/医保 3 个直接字段（非空即完成）+ 生日（非空且**合法**才完成）+ 语音访谈四段 = 8 项。
    /// 空白串不计完成（trim 后判空）；nil 表示档案未加载/已不存在——
    /// 首页不生成虚假的 0/8 提示或占位。
    public static func progress(profile: PatientProfile?,
                                interviewCompleted: Set<String>,
                                total: Int = 8) -> (done: Int, total: Int)? {
        guard let profile, profile.deletedAt == nil else { return nil }
        let done = [profile.bloodType, profile.idNo, profile.insuranceNo].filter {
            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }.count
        let birthDone = profile.birthDate.map { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isValidBirthDate(value)
        } ?? false
        return (done + (birthDone ? 1 : 0) + interviewCompleted.intersection(voiceInterviewKeys).count, total)
    }
}
