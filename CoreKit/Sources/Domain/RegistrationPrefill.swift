import Foundation

/// 首启注册的 Apple 健康特征型预填规则（业主 2026-09-17 定：注册必要字段 =
/// 特征性数据（血型/出生日期/生理性别）+ 紧急联系人；健康里有数据 → 表单默认值；
/// 没有 → 手动填写，**绝不阻断注册**）。
/// 纯函数零 IO——预填映射与校验 Linux 可单测。
public enum RegistrationPrefill {
    /// 标准血型八档（与 HealthKit 血型取值一一对应；急救卡/健康 App 共用词表）。
    public static let standardBloodTypes = ["A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−"]

    public struct Defaults: Sendable, Equatable {
        /// male/female/other（Health 三档原样透传，到表单由用户确认）。
        public var gender: String?
        /// 四位年份（必填字段的默认值）。
        public var birthYear: String?
        /// 01-12；Health 里只填了年份时为 nil（精度随来源）。
        public var birthMonth: String?
        /// 01-31；同上。
        public var birthDay: String?
        /// 标准八档之一；非标准值不进预填。
        public var bloodType: String?
        public var isEmpty: Bool { gender == nil && birthYear == nil && bloodType == nil }

        public init(gender: String? = nil, birthYear: String? = nil, birthMonth: String? = nil,
                    birthDay: String? = nil, bloodType: String? = nil) {
            self.gender = gender; self.birthYear = birthYear
            self.birthMonth = birthMonth; self.birthDay = birthDay
            self.bloodType = bloodType
        }
    }

    /// Health 特征型 → 表单默认值。血型只在标准八档内预填（特殊血型说明是用户
    /// 自己的措辞，机器不代写）；出生日期精度随来源（`yyyy` 或 `yyyy-MM-dd`）。
    public static func defaults(from characteristics: HealthCharacteristics) -> Defaults {
        var defaults = Defaults()
        defaults.gender = characteristics.gender
        if let birth = characteristics.birthDate {
            let parts = birth.split(separator: "-").map(String.init)
            if parts.count == 1, parts[0].count == 4 {
                defaults.birthYear = parts[0]
            } else if parts.count == 3 {
                defaults.birthYear = parts[0]; defaults.birthMonth = parts[1]; defaults.birthDay = parts[2]
            }
        }
        if let blood = characteristics.bloodType, standardBloodTypes.contains(blood) {
            defaults.bloodType = blood
        }
        return defaults
    }
}

/// 首位紧急联系人草稿（注册原子流入 `contact` 表；phone 必填——DDL NOT NULL）。
public struct EmergencyContactDraft: Sendable, Equatable {
    public var name: String
    /// 关系（FR3.1 枚举：配偶/子女/父母/祖父母/其他——本人不属于联系人类）。
    public var relation: String
    public var phone: String

    public init(name: String, relation: String, phone: String) {
        self.name = name; self.relation = relation; self.phone = phone
    }

    /// 三字段 trim 非空 ∧ 手机号基本形态（数字 5–20 位，允许 + - 空格括号）。
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !relation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.validPhone(phone)
    }

    public static func validPhone(_ phone: String) -> Bool {
        guard phone.allSatisfy({ $0.isNumber || "+- ()".contains($0) }) else { return false }
        let digits = phone.filter(\.isNumber).count
        return digits >= 5 && digits <= 20
    }
}
