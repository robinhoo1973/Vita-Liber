import Foundation

/// 电话国家/地区区号目录（2026-10-29 业主：电话号码需九宫数字输入 + 国家区号选择，
/// 显示国家地区名称与国旗）。
///
/// 纪律：
/// - 纯数据 + 纯函数（Domain 零框架）：不查网络、不引第三方库（成熟实现面 = ICU/CLDR
///   的区号表在 Foundation 中**不存在**可枚举 API——`Locale` 只给地区名不给拨号码，
///   故静态表是本能力的唯一来源；ISO 3166 地区名走 `Locale.localizedString(forRegionCode:)`
///   系统本地化，三语随 App 语言）。
/// - 国旗 = 两枚区域指示符 Unicode（ISO 3166-1 alpha-2 → U+1F1E6…），零图片资产。
/// - 存储格式 = E.164 风格 `+<dial><national digits>`（去空格）；旧存量纯数字
///   （无 +）解析时按默认地区（CN）。
public enum PhoneCountryCatalog {
    /// 默认地区（无存量前缀时的回落；业主场景为中文用户）。
    public static let defaultRegion = "CN"

    /// ISO 3166-1 alpha-2 → 国际拨号前缀（不含 +）。同一拨号前缀多地区时，
    /// `canonicalRegion(forDial:)` 取字母序首个作为显示名（北美 +1 → "AG" 仅作
    /// 显示锚，用户选择列表仍按各自地区行展示）。
    public static let dialCodeByRegion: [String: String] = [
        "AD": "376", "AE": "971", "AF": "93", "AG": "1", "AI": "1", "AL": "355",
        "AM": "374", "AO": "244", "AQ": "672", "AR": "54", "AS": "1", "AT": "43",
        "AU": "61", "AW": "297", "AX": "358", "AZ": "994",
        "BA": "387", "BB": "1", "BD": "880", "BE": "32", "BF": "226", "BG": "359",
        "BH": "973", "BI": "257", "BJ": "229", "BL": "590", "BM": "1", "BN": "673",
        "BO": "591", "BQ": "599", "BR": "55", "BS": "1", "BT": "975", "BW": "267",
        "BY": "375", "BZ": "501",
        "CA": "1", "CC": "61", "CD": "243", "CF": "236", "CG": "242", "CH": "41",
        "CI": "225", "CK": "682", "CL": "56", "CM": "237", "CN": "86", "CO": "57",
        "CR": "506", "CU": "53", "CV": "238", "CW": "599", "CX": "61", "CY": "357",
        "CZ": "420",
        "DE": "49", "DJ": "253", "DK": "45", "DM": "1", "DO": "1", "DZ": "213",
        "EC": "593", "EE": "372", "EG": "20", "EH": "212", "ER": "291", "ES": "34",
        "ET": "251",
        "FI": "358", "FJ": "679", "FK": "500", "FM": "691", "FO": "298", "FR": "33",
        "GA": "241", "GB": "44", "GD": "1", "GE": "995", "GF": "594", "GG": "44",
        "GH": "233", "GI": "350", "GL": "299", "GM": "220", "GN": "224", "GP": "590",
        "GQ": "240", "GR": "30", "GT": "502", "GU": "1", "GW": "245", "GY": "592",
        "HK": "852", "HN": "504", "HR": "385", "HT": "509", "HU": "36",
        "ID": "62", "IE": "353", "IL": "972", "IM": "44", "IN": "91", "IO": "246",
        "IQ": "964", "IR": "98", "IS": "354", "IT": "39",
        "JE": "44", "JM": "1", "JO": "962", "JP": "81",
        "KE": "254", "KG": "996", "KH": "855", "KI": "686", "KM": "269", "KN": "1",
        "KP": "850", "KR": "82", "KW": "965", "KY": "1", "KZ": "7",
        "LA": "856", "LB": "961", "LC": "1", "LI": "423", "LK": "94", "LR": "231",
        "LS": "266", "LT": "370", "LU": "352", "LV": "371", "LY": "218",
        "MA": "212", "MC": "377", "MD": "373", "ME": "382", "MF": "590", "MG": "261",
        "MH": "692", "MK": "389", "ML": "223", "MM": "95", "MN": "976", "MO": "853",
        "MP": "1", "MQ": "596", "MR": "222", "MS": "1", "MT": "356", "MU": "230",
        "MV": "960", "MW": "265", "MX": "52", "MY": "60", "MZ": "258",
        "NA": "264", "NC": "687", "NE": "227", "NF": "672", "NG": "234", "NI": "505",
        "NL": "31", "NO": "47", "NP": "977", "NR": "674", "NU": "683", "NZ": "64",
        "OM": "968",
        "PA": "507", "PE": "51", "PF": "689", "PG": "675", "PH": "63", "PK": "92",
        "PL": "48", "PM": "508", "PN": "64", "PR": "1", "PS": "970", "PT": "351",
        "PW": "680", "PY": "595",
        "QA": "974",
        "RE": "262", "RO": "40", "RS": "381", "RU": "7", "RW": "250",
        "SA": "966", "SB": "677", "SC": "248", "SD": "249", "SE": "46", "SG": "65",
        "SH": "290", "SI": "386", "SJ": "47", "SK": "421", "SL": "232", "SM": "378",
        "SN": "221", "SO": "252", "SR": "597", "SS": "211", "ST": "239", "SV": "503",
        "SX": "1", "SY": "963", "SZ": "268",
        "TC": "1", "TD": "235", "TG": "228", "TH": "66", "TJ": "992", "TK": "690",
        "TL": "670", "TM": "993", "TN": "216", "TO": "676", "TR": "90", "TT": "1",
        "TV": "688", "TW": "886", "TZ": "255",
        "UA": "380", "UG": "256", "US": "1", "UY": "598", "UZ": "998",
        "VA": "39", "VC": "1", "VE": "58", "VG": "1", "VI": "1", "VN": "84",
        "VU": "678",
        "WF": "681", "WS": "685",
        "YE": "967", "YT": "262",
        "ZA": "27", "ZM": "260", "ZW": "263",
    ]

    public static var allRegions: [String] { dialCodeByRegion.keys.sorted() }

    /// 国旗 emoji（区域指示符；未知地区回落地球符号）。
    public static func flag(_ region: String) -> String {
        let upper = region.uppercased()
        guard upper.count == 2 else { return "🌐" }
        var scalars = String.UnicodeScalarView()
        for scalar in upper.unicodeScalars {
            guard let base = UnicodeScalar(0x1F1E6),
                  let value = UnicodeScalar(base.value + scalar.value - 65) else { return "🌐" }
            scalars.append(value)
        }
        return String(scalars)
    }

    /// 地区本地化显示名（随 `locale`；缺失回落地区码）。
    public static func displayName(_ region: String, locale: Locale) -> String {
        locale.localizedString(forRegionCode: region.uppercased()) ?? region.uppercased()
    }

    /// E.164 风格存储串：`+<dial><digits>`（仅数字）。
    public static func canonical(region: String, nationalDigits: String) -> String {
        let digits = nationalDigits.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        let dial = dialCodeByRegion[region.uppercased()] ?? dialCodeByRegion[defaultRegion]!
        return "+\(dial)\(digits)"
    }

    /// 共享拨号前缀的显示锚（+1 北美多地区、+7 俄/哈等：解析时取主地区展示）。
    public static let preferredRegionByDial: [String: String] = [
        "1": "US", "7": "RU", "44": "GB", "61": "AU", "212": "MA", "262": "RE",
        "290": "SH", "358": "FI", "590": "GP", "599": "CW", "672": "NF",
        "246": "IO", "500": "FK", "690": "TK", "683": "NU", "39": "IT",
    ]

    /// 解析存量存储串：长拨号前缀优先匹配；无 `+` 的纯数字按默认地区。
    public static func parse(_ stored: String) -> (region: String, nationalDigits: String) {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard trimmed.hasPrefix("+") else {
            // 旧存量无前缀：默认地区（CN）整串即国内号。
            return (defaultRegion, digits)
        }
        // 拨号前缀 1–3 位（ITU 最长 3 位）：从长到短找可匹配地区。
        let candidates = dialCodeByRegion.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }
        for entry in candidates where digits.hasPrefix(entry.value) {
            let national = String(digits.dropFirst(entry.value.count))
            let region = preferredRegionByDial[entry.value] ?? entry.key
            return (region, national)
        }
        return (defaultRegion, digits)
    }
}
