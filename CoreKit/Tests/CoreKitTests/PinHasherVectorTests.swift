import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

#if os(iOS) || os(macOS)
// binds: SU-M1a-PIN — tech-spec §8「Infrastructure … PBKDF2 向量」
//
// 平台守卫：CommonCrypto/Security 仅 Apple 平台可用，本套件在 Linux 上整体编译掉。
// 策略半场（格式/升级判定/恒时比较）在 PinHashSchemeTests，任意机器可跑。
//
// 这里做的是**已知答案测试**：期望值由 OpenSSL（Python hashlib.pbkdf2_hmac）独立算出，
// 前两组即 PBKDF2-HMAC-SHA256 的公开标准向量。若 CommonCrypto 调用写错（参数错位、
// 长度传错、PRF 选错），这里立刻红——而不是等到线上「PIN 永远验证不过」或更糟的
// 「任何 PIN 都能过」。
@Suite("SU-M1a-PIN · PBKDF2 已知答案向量（CommonCrypto 调用正确性）")
struct PinHasherVectorTests {

    private func hex(_ s: String) -> [UInt8] { PinHashScheme.hexBytes(s) ?? [] }

    @Test(arguments: [
        // (pin, saltHex, iterations, expectedDigestHex)
        ("password", "73616c74", 1,
         "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        ("password", "73616c74", 4096,
         "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
        ("135790", "0102030405060708090a0b0c0d0e0f10", 1000,
         "60538b43c3ed3f3ce7d3f61d46aac79db3962c8da178c335ac0461f337b731d8"),
    ])
    func PBKDF2向量一致(_ c: (pin: String, saltHex: String, iterations: Int, expected: String)) {
        let derived = PinHasher.pbkdf2SHA256(pin: c.pin, salt: hex(c.saltHex),
                                             iterations: c.iterations, outputBytes: 32)
        #expect(PinHashScheme.hexString(derived) == c.expected,
                "PBKDF2-HMAC-SHA256 与独立实现不一致（pin=\(c.pin) iters=\(c.iterations)）")
    }

    /// 新建即当前方案；同一 PIN 验证通过且无需升级
    @Test func 新建哈希用当前方案且验证通过() {
        let made = PinHasher.makeHash(pin: "135790")
        #expect(made.stored.hasPrefix("pbkdf2-sha256$600000$"))
        #expect(PinHasher.verify(pin: "135790", stored: made.stored) == .ok(needsRehash: false))
        #expect(PinHasher.verify(pin: "135791", stored: made.stored) == .failed)
    }

    /// 盐必须每次不同——固定盐会让同 PIN 产生同哈希，彩虹表即可批量还原
    @Test func 每次新建盐不同() {
        let a = PinHasher.makeHash(pin: "135790")
        let b = PinHasher.makeHash(pin: "135790")
        #expect(a.saltHex != b.saltHex)
        #expect(a.stored != b.stored)
        #expect(a.saltHex.count == PinHashScheme.saltBytes * 2)
    }

    /// FR1.6 透明升级链路：旧条目可验证，且回报 needsRehash=true
    @Test func 旧SHA256条目可验证并要求升级() {
        let salt = hex("0102030405060708090a0b0c0d0e0f10")
        let legacy = "\(PinHashScheme.hexString(salt)):\(PinHasher.legacySHA256(pin: "135790", salt: salt))"
        #expect(PinHasher.verify(pin: "135790", stored: legacy) == .ok(needsRehash: true))
        #expect(PinHasher.verify(pin: "000000", stored: legacy) == .failed)
    }

    /// 畸形/空串绝不放行（避免「解析失败被当成通过」这类最坏失效）
    @Test(arguments: ["", "garbage", "pbkdf2-sha256$600000$zz$bb", "aa:"])
    func 畸形落盘串验证失败(_ bad: String) {
        #expect(PinHasher.verify(pin: "135790", stored: bad) == .failed)
    }
}
#endif
