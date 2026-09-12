import Foundation
import Testing
@testable import Domain

/// FR17.15 版本比较（ASRVersion）——混合段数值前缀比较是审查修正的回归锚点：
/// 字典序会把 "6b" > "10"、"v9" > "v10"、"1.9" > "1.10" 排反（审查轮实证）。
@Suite("FR17.15 ASRVersion 版本比较")
struct ASRVersionTests {
    @Test func 混合段按数值前缀比较() {
        #expect(ASRVersion.isNewer("10", than: "6b"))
        #expect(!ASRVersion.isNewer("6b", than: "10"))
        #expect(ASRVersion.isNewer("v10", than: "v9"))
        #expect(!ASRVersion.isNewer("v9", than: "v10"))
    }

    @Test(arguments: [
        ("V10", "v9"),
        ("0.6b-int8-v10.03.25", "0.6b-int8-v9.03.25"),
        ("v10.1", "v9.10")
    ])
    func 字母后的数字比较适用于完整模型版本(_ newer: String, _ older: String) {
        #expect(ASRVersion.isNewer(newer, than: older))
        #expect(!ASRVersion.isNewer(older, than: newer))
    }

    @Test func 小数段不按字典序() {
        #expect(ASRVersion.isNewer("1.10", than: "1.9"))
        #expect(!ASRVersion.isNewer("1.9", than: "1.10"))
    }

    @Test func 纯数字段按整数比较且前导零等价() {
        #expect(ASRVersion.isNewer("20260912", than: "20260325"))
        #expect(!ASRVersion.isNewer("03", than: "3"))
        #expect(!ASRVersion.isNewer("3", than: "03"))
    }

    @Test func 未安装视为恒新() {
        #expect(ASRVersion.isNewer("0.6b-int8-v2026.03.25", than: nil))
        #expect(!ASRVersion.isNewer("", than: nil))
    }

    @Test func 前缀相同时段多者为新() {
        #expect(ASRVersion.isNewer("1.0.1", than: "1.0"))
        #expect(!ASRVersion.isNewer("1.0", than: "1.0.1"))
    }

    @Test func 相同版本不为新() {
        #expect(!ASRVersion.isNewer("0.6b-int8-v2026.03.25", than: "0.6b-int8-v2026.03.25"))
    }
}
