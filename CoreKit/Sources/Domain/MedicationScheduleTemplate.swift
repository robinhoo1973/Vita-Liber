import Foundation

/// 用药计划模板（2026-10-23 业主裁决：用药计划 = 一天中的固定服药时段，
/// **与药品无关**；把药品与计划关联是「用药提醒」的动作）。
///
/// 本类型只持有「哪些时刻该提醒」；药品、剂量、疗程都在绑定行
/// （`medication_plan`）上。时段模板可被多条用药提醒复用。
public struct MedicationScheduleTemplate: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var patientId: UUID
    /// 用户可读名称（如「早晚餐后」）；nil 时界面按时段摘要展示。
    public var name: String?
    /// 规范化的提醒时刻（"HH:mm"，按分钟升序、去重）。
    public var times: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, patientId: UUID, name: String?, times: [String],
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.patientId = patientId; self.name = name
        self.times = times; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// 模板规则（纯函数，Linux 可单测）：校验/规范化/摘要。
public enum MedicationScheduleTemplateRules {
    /// 规范化时刻集合：非法项剔除、按分钟去重、升序。
    /// 调用方须先用 `validate` 拒绝非法输入——这里不做「静默丢弃后建一个
    /// 少剂量计划」的兜底（与 fixed 通道零剂量事故同纪律）。
    public static func normalize(_ times: [String]) -> [String] {
        var seen = Set<Int>()
        return times
            .filter { DoseScheduleEngine.isValidTime($0) }
            .filter { seen.insert(DoseScheduleEngine.minutes($0) ?? 0).inserted }
            .sorted { (DoseScheduleEngine.minutes($0) ?? 0) < (DoseScheduleEngine.minutes($1) ?? 0) }
    }

    /// 校验：至少一个时刻；全部合法；同一分钟不得重复出现。
    /// 返回 nil = 通过；否则返回错误类别供界面就地说明。
    public static func validate(_ times: [String]) -> ValidationError? {
        let trimmed = times.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if trimmed.isEmpty { return .empty }
        if trimmed.contains(where: { !DoseScheduleEngine.isValidTime($0) }) { return .invalidTime }
        let minutes = trimmed.compactMap { DoseScheduleEngine.minutes($0) }
        if Set(minutes).count != minutes.count { return .duplicateTime }
        return nil
    }

    public enum ValidationError: String, Sendable, Equatable {
        case empty
        case invalidTime
        case duplicateTime
    }

    /// 摘要（「07:30 · 19:30」）；界面在无名称时展示，避免再存一份文本。
    public static func summary(_ times: [String]) -> String {
        normalize(times).joined(separator: " · ")
    }
}
