import Testing
@testable import Domain
import Foundation

/// 电话国家区号目录（2026-10-29 首启修复批）：canonical/parse 往返、国旗生成、
/// 拨号前缀最长匹配、无前缀旧存量回落默认地区。
@Suite("电话国家区号目录")
struct PhoneCountryCatalogTests {
    @Test("canonical 写入纯数字 + 区号，parse 往返一致")
    func canonicalRoundTrip() {
        let canonical = PhoneCountryCatalog.canonical(region: "CN", nationalDigits: "138 0013 8000")
        #expect(canonical == "+8613800138000")
        let parsed = PhoneCountryCatalog.parse(canonical)
        #expect(parsed.region == "CN")
        #expect(parsed.nationalDigits == "13800138000")
    }

    @Test("无前缀旧存量按默认地区解析")
    func legacyPlainDigitsFallBackToDefault() {
        let parsed = PhoneCountryCatalog.parse("13800138000")
        #expect(parsed.region == PhoneCountryCatalog.defaultRegion)
        #expect(parsed.nationalDigits == "13800138000")
    }

    @Test("共享拨号前缀取主地区显示锚（+1 → US，+7 → RU）")
    func sharedDialPrefersAnchorRegion() {
        #expect(PhoneCountryCatalog.parse("+12125550123").region == "US")
        #expect(PhoneCountryCatalog.parse("+79991234567").region == "RU")
        #expect(PhoneCountryCatalog.parse("+8613800138000").region == "CN")
    }

    @Test("最长前缀优先：+86 不被 +8 类前缀误切")
    func longestDialPrefixWins() {
        // 目录中无 +8 单前缀，这里验证三分位前缀匹配本身（+852 香港 vs 默认）。
        let parsed = PhoneCountryCatalog.parse("+85291234567")
        #expect(parsed.region == "HK")
        #expect(parsed.nationalDigits == "91234567")
    }

    @Test("国旗 emoji = 区域指示符；未知地区回落地球")
    func flagDerivation() {
        #expect(PhoneCountryCatalog.flag("CN") == "🇨🇳")
        #expect(PhoneCountryCatalog.flag("us") == "🇺🇸")
        #expect(PhoneCountryCatalog.flag("XYZ") == "🌐")
    }

    @Test("全地区数字往返：canonical→parse 保留国内号数字（区域显示锚可不同）")
    func digitsRoundTripForEveryRegion() {
        for region in PhoneCountryCatalog.allRegions {
            let canonical = PhoneCountryCatalog.canonical(region: region, nationalDigits: "91234567")
            let parsed = PhoneCountryCatalog.parse(canonical)
            #expect(parsed.nationalDigits == "91234567", "数字往返丢失：\(region) -> \(canonical)")
            #expect(parsed.region == (PhoneCountryCatalog.preferredRegionByDial[PhoneCountryCatalog.dialCodeByRegion[region]!] ?? region),
                    "区域应为文档锚或原地区：\(region)")
        }
    }

    @Test("目录自身一致：每个地区拨号码为 1–3 位数字，且存在默认地区")
    func catalogSelfConsistency() {
        for (region, dial) in PhoneCountryCatalog.dialCodeByRegion {
            #expect(region.count == 2, "地区码长度异常：\(region)")
            #expect((1...3).contains(dial.count), "拨号前缀长度异常：\(region)=\(dial)")
            // CI 40862004631 红修复：rethrows 闭包参数（allSatisfy）置于
            // #expect 展开内会丢非抛出推断（call can throw）——先求值再断言。
            let digitsOnly = dial.allSatisfy { $0.isNumber }
            #expect(digitsOnly, "拨号前缀非数字：\(region)=\(dial)")
        }
        #expect(PhoneCountryCatalog.dialCodeByRegion[PhoneCountryCatalog.defaultRegion] != nil)
    }
}
