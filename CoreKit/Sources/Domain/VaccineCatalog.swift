import Foundation

/// 疫苗程序参考目录（离线内置，不联网、不判定漏种、不提供接种建议）。
///
/// 国家免疫规划部分依据《国家免疫规划疫苗儿童免疫程序及说明（2021年版）》
/// （国家卫生健康委员会）整理；可选疫苗仅给出常见年龄窗口，具体以接种门诊、
/// 疫苗说明书和医生意见为准。详见 `sourceNote`。
public enum VaccineCatalog {
    public enum Category: String, Sendable, Equatable {
        case national
        case optional
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let disease: String
        /// 适用月龄下限（含）。
        public let minMonths: Int
        /// 适用月龄上限（含）；>= 1200 表示成人长期适用。
        public let maxMonths: Int
        public let doseNumber: Int
        /// nil = 不限性别；"female"/"male" = 仅该性别。
        public let sex: String?
        public let category: Category
        public init(id: String, name: String, disease: String,
                    minMonths: Int, maxMonths: Int, doseNumber: Int,
                    sex: String? = nil, category: Category) {
            self.id = id; self.name = name; self.disease = disease
            self.minMonths = minMonths; self.maxMonths = maxMonths
            self.doseNumber = doseNumber; self.sex = sex; self.category = category
        }
    }

    public static let sourceNote = """
    国家免疫规划部分依据《国家免疫规划疫苗儿童免疫程序及说明（2021年版）》\
    （国家卫生健康委员会）整理。可选疫苗按常见说明书年龄窗口列出，不构成接种建议；\
    是否接种、补种与间隔以接种门诊和疫苗说明书为准。
    """

    public static let allItems: [Item] = [
        // 0–6 岁国家免疫规划
        .init(id: "hepb_1", name: "乙肝疫苗", disease: "乙型肝炎",
              minMonths: 0, maxMonths: 1, doseNumber: 1, category: .national),
        .init(id: "bcg", name: "卡介苗", disease: "结核病",
              minMonths: 0, maxMonths: 1, doseNumber: 1, category: .national),
        .init(id: "hepb_2", name: "乙肝疫苗", disease: "乙型肝炎",
              minMonths: 1, maxMonths: 2, doseNumber: 2, category: .national),
        .init(id: "ipv_1", name: "脊灰灭活疫苗", disease: "脊髓灰质炎",
              minMonths: 2, maxMonths: 3, doseNumber: 1, category: .national),
        .init(id: "ipv_2", name: "脊灰灭活疫苗", disease: "脊髓灰质炎",
              minMonths: 3, maxMonths: 4, doseNumber: 2, category: .national),
        .init(id: "dtap_1", name: "百白破疫苗", disease: "百日咳、白喉、破伤风",
              minMonths: 3, maxMonths: 4, doseNumber: 1, category: .national),
        .init(id: "bopv_1", name: "脊灰减毒活疫苗", disease: "脊髓灰质炎",
              minMonths: 4, maxMonths: 5, doseNumber: 3, category: .national),
        .init(id: "dtap_2", name: "百白破疫苗", disease: "百日咳、白喉、破伤风",
              minMonths: 4, maxMonths: 5, doseNumber: 2, category: .national),
        .init(id: "dtap_3", name: "百白破疫苗", disease: "百日咳、白喉、破伤风",
              minMonths: 5, maxMonths: 6, doseNumber: 3, category: .national),
        .init(id: "hepb_3", name: "乙肝疫苗", disease: "乙型肝炎",
              minMonths: 6, maxMonths: 8, doseNumber: 3, category: .national),
        .init(id: "mena_1", name: "A 群流脑疫苗", disease: "流行性脑脊髓膜炎",
              minMonths: 6, maxMonths: 9, doseNumber: 1, category: .national),
        .init(id: "mmr_1", name: "麻腮风疫苗", disease: "麻疹、腮腺炎、风疹",
              minMonths: 8, maxMonths: 12, doseNumber: 1, category: .national),
        .init(id: "je_1", name: "乙脑减毒活疫苗", disease: "流行性乙型脑炎",
              minMonths: 8, maxMonths: 12, doseNumber: 1, category: .national),
        .init(id: "mena_2", name: "A 群流脑疫苗", disease: "流行性脑脊髓膜炎",
              minMonths: 9, maxMonths: 12, doseNumber: 2, category: .national),
        .init(id: "dtap_4", name: "百白破疫苗", disease: "百日咳、白喉、破伤风",
              minMonths: 18, maxMonths: 24, doseNumber: 4, category: .national),
        .init(id: "mmr_2", name: "麻腮风疫苗", disease: "麻疹、腮腺炎、风疹",
              minMonths: 18, maxMonths: 24, doseNumber: 2, category: .national),
        .init(id: "hepa_1", name: "甲肝疫苗", disease: "甲型肝炎",
              minMonths: 18, maxMonths: 24, doseNumber: 1, category: .national),
        .init(id: "hepa_2", name: "甲肝疫苗", disease: "甲型肝炎",
              minMonths: 24, maxMonths: 30, doseNumber: 2, category: .national),
        .init(id: "je_2", name: "乙脑减毒活疫苗", disease: "流行性乙型脑炎",
              minMonths: 24, maxMonths: 36, doseNumber: 2, category: .national),
        .init(id: "menac_1", name: "A+C 群流脑疫苗", disease: "流行性脑脊髓膜炎",
              minMonths: 36, maxMonths: 48, doseNumber: 1, category: .national),
        .init(id: "bopv_2", name: "脊灰减毒活疫苗", disease: "脊髓灰质炎",
              minMonths: 48, maxMonths: 60, doseNumber: 4, category: .national),
        .init(id: "dt", name: "白破疫苗", disease: "白喉、破伤风",
              minMonths: 72, maxMonths: 84, doseNumber: 5, category: .national),
        .init(id: "mmr_3", name: "麻腮风疫苗", disease: "麻疹、腮腺炎、风疹",
              minMonths: 72, maxMonths: 84, doseNumber: 3, category: .national),
        .init(id: "menac_2", name: "A+C 群流脑疫苗", disease: "流行性脑脊髓膜炎",
              minMonths: 72, maxMonths: 84, doseNumber: 2, category: .national),

        // 常见可选疫苗（按说明书年龄窗口，不是接种建议）
        .init(id: "varicella", name: "水痘疫苗", disease: "水痘",
              minMonths: 12, maxMonths: 144, doseNumber: 1, category: .optional),
        .init(id: "ev71", name: "EV71 手足口病疫苗", disease: "手足口病",
              minMonths: 6, maxMonths: 71, doseNumber: 1, category: .optional),
        .init(id: "pcv13", name: "13 价肺炎球菌结合疫苗", disease: "肺炎球菌感染",
              minMonths: 2, maxMonths: 71, doseNumber: 1, category: .optional),
        .init(id: "influenza", name: "流感疫苗", disease: "流行性感冒",
              minMonths: 6, maxMonths: 1200, doseNumber: 1, category: .optional),
        .init(id: "hpv", name: "HPV 疫苗", disease: "人乳头瘤病毒感染",
              minMonths: 108, maxMonths: 540, doseNumber: 1, sex: "female",
              category: .optional),
        .init(id: "shingles", name: "带状疱疹疫苗", disease: "带状疱疹",
              minMonths: 600, maxMonths: 1200, doseNumber: 1, category: .optional),
        .init(id: "ppsv23", name: "23 价肺炎球菌多糖疫苗", disease: "肺炎球菌感染",
              minMonths: 720, maxMonths: 1200, doseNumber: 1, category: .optional),
        .init(id: "td_adult", name: "破伤风-白喉疫苗", disease: "破伤风、白喉",
              minMonths: 216, maxMonths: 1200, doseNumber: 1, category: .optional),
        .init(id: "hepb_adult", name: "乙肝疫苗（成人补种）", disease: "乙型肝炎",
              minMonths: 216, maxMonths: 1200, doseNumber: 1, category: .optional),
    ]

    /// 由出生日期计算满月龄；非法/缺失返回 nil（不猜测）。
    public static func ageMonths(birthDate: String?, now: Date = Date(),
                                 calendar: Calendar = .current) -> Int? {
        guard let birthDate,
              let birth = MemberProfileCompleteness.parsedBirthDate(birthDate) else {
            return nil
        }
        let months = calendar.dateComponents([.month], from: birth, to: now).month ?? 0
        return max(0, months)
    }

    /// 按年龄/性别过滤；年龄未知时返回全部（由界面明示）。
    public static func items(ageMonths: Int?, sex: String?,
                             includeAllAges: Bool = false) -> [Item] {
        allItems.filter { item in
            if let sex, let required = item.sex, required != sex { return false }
            guard !includeAllAges, let ageMonths else { return true }
            return ageMonths >= item.minMonths && ageMonths <= item.maxMonths
        }
    }
}
