import Foundation

/// 用药计划模板的一个条目（v43，2026-10-23 业主：列出标准时段与常用提醒范围，
/// 并允许自定义范围）。
///
/// 语义（评审委员会两轮裁决）：
/// - `time` 是**唯一排程事实**：提醒只按该时刻发生（物化/通知/安全线均只读它）。
/// - `rangeStart/rangeEnd` 是**常用提醒范围**（展示元数据）：半开区间
///   `[start, end)`，不参与调度、不判漏服、不改变库存扣减；nil 表示用该时段的
///   默认范围。范围值不是医学建议（BR-006），界面统一称「常用提醒范围」。
/// - `slot` 是标准时段身份（可为 nil = 自定义条目）。存 token 而非强类型枚举，
///   未知 token 在解码时降级为自定义，绝不因新版新增时段让整组条目失效。
public struct MedicationScheduleEntry: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var slot: DoseTimeSlot?
    public var time: String
    public var rangeStart: String?
    public var rangeEnd: String?
    /// 自定义条目的稳定身份（标准时段用 slot 名；自定义用生成 id）。
    public var customId: UUID?

    public var id: String {
        if let slot { return "slot-\(slot.rawValue)" }
        return "custom-\((customId ?? UUID()).uuidString)"
    }

    public init(slot: DoseTimeSlot?, time: String,
                rangeStart: String? = nil, rangeEnd: String? = nil,
                customId: UUID? = nil) {
        self.slot = slot
        self.time = time
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.customId = slot == nil ? (customId ?? UUID()) : nil
    }

    // 宽容解码：slot 存 raw token，未知值降级为自定义；范围字段坏掉只丢范围。
    private enum CodingKeys: String, CodingKey {
        case slot, time, rangeStart, rangeEnd, customId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let token = try c.decodeIfPresent(String.self, forKey: .slot)
        slot = token.flatMap(DoseTimeSlot.init(rawValue:))
        time = try c.decode(String.self, forKey: .time)
        rangeStart = try c.decodeIfPresent(String.self, forKey: .rangeStart)
        rangeEnd = try c.decodeIfPresent(String.self, forKey: .rangeEnd)
        customId = try c.decodeIfPresent(UUID.self, forKey: .customId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(slot?.rawValue, forKey: .slot)
        try c.encode(time, forKey: .time)
        try c.encodeIfPresent(rangeStart, forKey: .rangeStart)
        try c.encodeIfPresent(rangeEnd, forKey: .rangeEnd)
        try c.encodeIfPresent(customId, forKey: .customId)
    }
}

/// 条目规则（纯函数，Linux 可单测）。
public enum MedicationScheduleEntryRules {
    /// 默认常用提醒范围 `[defaultTime, defaultTime+30min)`。
    /// 复用 FR9.17 的 30 分钟容差，不发明新的临床数字；半开区间保证
    /// `time ∈ range` 对默认值恒成立，且相邻时段范围不重叠。
    public static func defaultRange(for slot: DoseTimeSlot) -> (start: String, end: String) {
        let start = DoseScheduleEngine.minutes(slot.defaultTime) ?? 0
        let end = min(start + 30, 24 * 60)
        return (String(format: "%02d:%02d", start / 60, start % 60),
                String(format: "%02d:%02d", end / 60, end % 60))
    }

    /// 条目实际范围（未自定义时回落默认；自定义条目无范围 → nil）。
    public static func range(of entry: MedicationScheduleEntry)
        -> (start: String, end: String)? {
        if let start = entry.rangeStart, let end = entry.rangeEnd {
            return (start, end)
        }
        guard let slot = entry.slot else { return nil }
        return defaultRange(for: slot)
    }

    /// 旧数据（`[String]` 时刻数组）→ 条目：仅当时刻恰等于某时段默认时刻才认领
    /// 时段身份；匹配不到一律自定义，绝不就近吸附。
    public static func entries(fromLegacyTimes times: [String]) -> [MedicationScheduleEntry] {
        times.compactMap { time in
            guard DoseScheduleEngine.isValidTime(time) else { return nil }
            let slot = DoseTimeSlot.allCases.first { $0.defaultTime == time }
            return MedicationScheduleEntry(slot: slot, time: time)
        }
    }

    /// 规范化：非法条目剔除、按分钟去重（保留先出现者）、按分钟升序；
    /// 标准时段补默认范围字符串（写库即显式，避免依赖未来默认表变化）。
    public static func normalize(_ entries: [MedicationScheduleEntry])
        -> [MedicationScheduleEntry] {
        var seen = Set<Int>()
        let valid = entries.filter { DoseScheduleEngine.isValidTime($0.time) }
            .filter { seen.insert(DoseScheduleEngine.minutes($0.time) ?? 0).inserted }
        var normalized = valid.map { entry -> MedicationScheduleEntry in
            var copy = entry
            if let slot = entry.slot {
                let range = defaultRange(for: slot)
                copy.rangeStart = entry.rangeStart ?? range.start
                copy.rangeEnd = entry.rangeEnd ?? range.end
            }
            return copy
        }
        normalized.sort {
            (DoseScheduleEngine.minutes($0.time) ?? 0) < (DoseScheduleEngine.minutes($1.time) ?? 0)
        }
        return normalized
    }

    public static func times(_ entries: [MedicationScheduleEntry]) -> [String] {
        normalize(entries).map(\.time)
    }

    public enum ValidationError: String, Sendable, Equatable {
        case empty
        case invalidTime
        case duplicateTime
        case duplicateSlot
        case invalidRange
    }

    /// 保存闸门：空 / 非法时刻 / 重复分钟 / 同时段重复 / 范围非法（两端齐全、
    /// 合法、`start < end`；v1 不支持跨午夜）。时刻落在范围外**不阻断**（软提示）。
    public static func validate(_ entries: [MedicationScheduleEntry]) -> ValidationError? {
        let trimmed = entries.filter {
            !$0.time.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if trimmed.isEmpty { return .empty }
        if trimmed.contains(where: { !DoseScheduleEngine.isValidTime($0.time) }) {
            return .invalidTime
        }
        let minutes = trimmed.compactMap { DoseScheduleEngine.minutes($0.time) }
        if Set(minutes).count != minutes.count { return .duplicateTime }
        let slots = trimmed.compactMap(\.slot)
        if Set(slots).count != slots.count { return .duplicateSlot }
        for entry in trimmed {
            guard let start = entry.rangeStart, let end = entry.rangeEnd else {
                // 两端要么都有、要么都无（标准时段可只给一端？不允许半截）。
                if entry.rangeStart != nil || entry.rangeEnd != nil { return .invalidRange }
                continue
            }
            guard DoseScheduleEngine.isValidTime(start), DoseScheduleEngine.isValidTime(end),
                  let s = DoseScheduleEngine.minutes(start),
                  let e = DoseScheduleEngine.minutes(end), s < e else {
                return .invalidRange
            }
        }
        return nil
    }

    /// 软提示：提醒时刻不在常用范围内（不阻断保存）。
    public static func timesOutsideRange(_ entries: [MedicationScheduleEntry])
        -> [MedicationScheduleEntry] {
        entries.filter { entry in
            guard let range = range(of: entry),
                  let t = DoseScheduleEngine.minutes(entry.time),
                  let s = DoseScheduleEngine.minutes(range.start),
                  let e = DoseScheduleEngine.minutes(range.end) else { return false }
            return t < s || t >= e
        }
    }

    /// 半开区间归属（供测试与提示复用；含 start、不含 end）。
    public static func contains(_ time: String, in range: (start: String, end: String)) -> Bool {
        guard let t = DoseScheduleEngine.minutes(time),
              let s = DoseScheduleEngine.minutes(range.start),
              let e = DoseScheduleEngine.minutes(range.end) else { return false }
        return t >= s && t < e
    }
}
