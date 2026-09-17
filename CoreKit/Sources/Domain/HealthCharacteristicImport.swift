import Foundation

/// Apple 健康**特征型**数据（血型 / 出生日期 / 生理性别）与成员档案的对接（业主 2026-09-17 定：
/// 导入，走**档案候选**——D 级候选、用户显式确认才写入；不覆盖已有值；不进趋势管道）。
///
/// **平台事实**（2026-09-17 查证）：
/// - 特征型（`HKCharacteristicType`）**可读**、只读——不能写、不能建查询，用户只能在「健康」App 里手改；
///   且只需**读**授权（写集合里放特征型不会出现在授权单上）。
/// - **医疗急救卡 / SOS 联系人没有任何公开 API**（读不到、也写不进）——只能引导用户手填（FR15.2）。
/// - **临床记录（Health Records / FHIR）只读**，不可创建或保存 `HKClinical`。
///
/// 本文件只放**纯规则**（映射与候选裁决），HealthKit 的类型映射在 Infrastructure 侧。
public struct HealthCharacteristics: Sendable, Equatable {
    /// 已格式化的血型（`A+` / `A−` / `AB+` / `O−`…）；Health 里未填为 nil。
    public var bloodType: String?
    /// `yyyy-MM-dd`，或用户只填了年份时为 `yyyy`（精度随来源，不擅自细化）。
    public var birthDate: String?
    /// 生理性别（`male` / `female` / `other`——Health 的三档取值，落到档案前由用户确认）。
    public var gender: String?

    public init(bloodType: String? = nil, birthDate: String? = nil, gender: String? = nil) {
        self.bloodType = bloodType; self.birthDate = birthDate; self.gender = gender
    }

    public var isEmpty: Bool { bloodType == nil && birthDate == nil && gender == nil }
}

/// 档案候选的裁决（纯函数，零 IO）。
public enum HealthCharacteristicImport {

    public enum Field: String, CaseIterable, Sendable {
        case bloodType, birthDate, gender
    }

    public struct Candidate: Equatable, Sendable, Identifiable {
        public let field: Field
        /// 健康里的值（**候选**：未经用户确认不得写入档案，BR-003 同族）。
        public let proposed: String
        /// 档案现值；非空即**默认保留**（不覆盖——档案里的值可能来自医院原文或用户手填，优先级更高）。
        public let existing: String?
        public var id: String { field.rawValue }
        /// 可采用 = 有候选值 ∧ 档案无值。
        public var isAdoptable: Bool { !proposed.isEmpty && (existing?.isEmpty ?? true) }
        /// 档案已有值 → 本行只呈现对照，不提供「采用」（避免覆盖用户/医院来源的值）。
        public var keepsExisting: Bool { !(existing?.isEmpty ?? true) }
    }

    /// 生成候选清单：三项各成一行（有值才有行；健康里没有的字段不出现）。
    ///
    /// **出生日期精度**：档案现值若是「仅年份」形态（4 位数字），候选**降到年份**——
    /// 用户刻意选择的粗粒度不因导入而被细化（FR3.1 精度口径）。
    public static func candidates(characteristics: HealthCharacteristics,
                                  profile: PatientProfile) -> [Candidate] {
        var out: [Candidate] = []
        if let blood = characteristics.bloodType, !blood.isEmpty {
            out.append(Candidate(field: .bloodType, proposed: blood, existing: normalized(profile.bloodType)))
        }
        if let birth = characteristics.birthDate, !birth.isEmpty {
            let existing = normalized(profile.birthDate)
            out.append(Candidate(field: .birthDate,
                                 proposed: matchesYearOnlyPrecision(existing) ? year(of: birth) : birth,
                                 existing: existing))
        }
        if let gender = characteristics.gender, !gender.isEmpty {
            out.append(Candidate(field: .gender, proposed: gender, existing: normalized(profile.gender)))
        }
        return out
    }

    /// 有无可采用的候选（决定入口是否值得出现）。
    public static func hasAdoptable(_ candidates: [Candidate]) -> Bool {
        candidates.contains { $0.isAdoptable }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 档案现值是否为「仅年份」形态（4 位数字，如 `1990`）。
    private static func matchesYearOnlyPrecision(_ existing: String?) -> Bool {
        guard let existing else { return false }
        return existing.count == 4 && existing.allSatisfy(\.isNumber)
    }

    /// 取日期串的年份部分（`1990-05-03` → `1990`）。
    private static func year(of date: String) -> String {
        String(date.prefix(while: { $0.isNumber }))
    }
}
