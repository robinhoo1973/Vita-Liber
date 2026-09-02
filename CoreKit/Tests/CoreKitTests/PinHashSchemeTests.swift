import Foundation
import Testing
@testable import Domain

// binds: SU-M1a-PIN — tech-spec §6 / FR1.6 口令哈希方案与透明升级
//
// 这套测试存在的理由：PIN 哈希此前**零测试**——因为实现整体被
// `#if os(iOS) || os(macOS)` 守住，Linux CI 根本编译不到它。
// 把格式与策略抽到 Domain 后，安全关键判定终于可在任意机器上验证。
@Suite("SU-M1a-PIN · 口令哈希方案与透明升级（§6/FR1.6）")
struct PinHashSchemeTests {

    @Test func 生产参数对齐OWASP() {
        #expect(PinHashScheme.iterations == 600_000, "PBKDF2-HMAC-SHA256 迭代数须为 OWASP(2023) 推荐值")
        #expect(PinHashScheme.saltBytes == 32)
    }

    @Test func 新方案落盘串自描述且可回解() {
        let stored = PinHashScheme.format(saltHex: "aabb", digestHex: "ccdd")
        #expect(stored == "pbkdf2-sha256$600000$aabb$ccdd")
        guard case .pbkdf2(let iterations, let salt, let digest)? = PinHashScheme.parse(stored) else {
            Issue.record("新方案必须可解析"); return
        }
        #expect(iterations == 600_000)
        #expect(salt == "aabb" && digest == "ccdd")
    }

    @Test func 旧SHA256条目仍可识别() {
        guard case .legacySHA256(let salt, let digest)? = PinHashScheme.parse("00ff:1234") else {
            Issue.record("旧条目必须仍可识别，否则存量用户无法验证 PIN"); return
        }
        #expect(salt == "00ff" && digest == "1234")
    }

    /// 旧方案（单轮 SHA256、6 位 PIN 只有 10^6 空间）必须无条件升级
    @Test func 旧条目一律需要重哈希() {
        #expect(PinHashScheme.needsRehash("00ff:1234"))
    }

    @Test func 当前方案不需要重哈希() {
        #expect(!PinHashScheme.needsRehash(PinHashScheme.format(saltHex: "aa", digestHex: "bb")))
    }

    /// 将来上调迭代数时，低于生产值的旧条目也要自动升级
    @Test func 迭代数偏低的条目需要重哈希() {
        #expect(PinHashScheme.needsRehash("pbkdf2-sha256$1000$aa$bb"))
    }

    /// 不可识别的串必须解析失败 → 验证失败，绝不放行
    @Test(arguments: ["", "garbage", "pbkdf2-sha256$600000$aa", "pbkdf2-sha256$0$aa$bb",
                      "pbkdf2-sha256$abc$aa$bb", "zz:1234", "00ff:", ":1234", "0f0:11"])
    func 畸形串一律解析失败(_ bad: String) {
        #expect(PinHashScheme.parse(bad) == nil, "畸形串必须拒绝：\(bad)")
        #expect(!PinHashScheme.needsRehash(bad), "解析失败不谈升级")
    }

    /// 迭代数上限（评审补）：验证必须按落盘串**自报**的迭代数重跑 KDF——被篡改串
    /// 报天文数字时一次验证就是数小时 CPU（可用性 DoS）。parse 对上界外值 fail-closed：
    /// 验证失败、不升级、绝不放行。上限 10M 为将来上调生产值留 16 倍余量。
    @Test func 迭代数超上限拒绝且上限值本身合法() {
        #expect(PinHashScheme.parse("pbkdf2-sha256$10000001$aa$bb") == nil)
        #expect(PinHashScheme.parse("pbkdf2-sha256$2147483647$aa$bb") == nil)
        #expect(!PinHashScheme.needsRehash("pbkdf2-sha256$10000001$aa$bb"))
        #expect(PinHashScheme.parse("pbkdf2-sha256$10000000$aa$bb") != nil)
    }

    @Test func 恒时比较语义正确() {
        #expect(PinHashScheme.constantTimeEquals("abcd", "abcd"))
        #expect(!PinHashScheme.constantTimeEquals("abcd", "abce"))
        #expect(!PinHashScheme.constantTimeEquals("abcd", "abcde"))   // 长度不等即假
        #expect(PinHashScheme.constantTimeEquals("", ""))
    }

    @Test func 十六进制往返() {
        #expect(PinHashScheme.hexBytes("00ff10") == [0x00, 0xff, 0x10])
        #expect(PinHashScheme.hexString([0x00, 0xff, 0x10]) == "00ff10")
        #expect(PinHashScheme.hexBytes("0f0") == nil)      // 奇数长度
        #expect(PinHashScheme.hexBytes("zz") == nil)
    }
}
