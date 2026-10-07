#if os(iOS) || os(macOS)
import Foundation
import Testing
import Domain
@testable import Infrastructure

/// SP-64 通告面 · Vision 金色字节合同（P3 合入门槛；委员会 S1 设计）。
///
/// 夹具 = CNB 仓 `tools/readme-sync/{vl-index.png,vl-index.payload}` 同批拷贝
/// （入库时与线上部署件逐字节一致已核；`vl-index.payload` = identity 前缀 + VLASR 信封）。
/// 断言：Vision 对本仓 PNG 的解码必须与 state 字节**逐字节相等**——跨解码器
/// （Vision payloadData / isoLatin1 回退 / 段头剥离）的合同由本条钉死；
/// 若 Vision 行为漂移 → 本测试红 → 服务器侧切换文本形态（`QR_PAYLOAD_BUDGET=0` 逃生门）。
@Suite("SP-64 通告面 · Vision 金色字节合同")
struct UpdateAdviceGoldenTests {
    private func fixture(_ name: String) throws -> Data {
        let path = TestFixtures.path("updateAdvice/" + name)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test func visionDecodesFixturePNGToFixturePayload() throws {
        let png = try fixture("vl-index.png")
        let expected = try fixture("vl-index.payload")
        let decoded = try UpdatePayloadQRDecoder.payloadBytes(fromPNGData: png)
        #expect(decoded == expected)
        #expect(decoded.count == expected.count)
        #expect(UpdatePayloadQRDecoder.isValidPayloadShape(decoded))
    }

    @Test func truncatedPNGRejected() throws {
        let png = try fixture("vl-index.png")
        let truncated = Data(png.prefix(png.count / 3))
        #expect(throws: (any Error).self) {
            _ = try UpdatePayloadQRDecoder.payloadBytes(fromPNGData: truncated)
        }
    }

    @Test func normalizePathsAndAmbiguity() {
        let hex = String(repeating: "a", count: 64)
        let valid = Data(("update-payload-" + hex).utf8) + Data("VLASR\u{01}".utf8)
            + Data(repeating: 0, count: 32)
        #expect(UpdatePayloadQRDecoder.normalize(valid) == valid)
        // 前缀垃圾 + 唯一 needle → 切片命中
        let prefixed = Data([1, 2, 3]) + valid
        #expect(UpdatePayloadQRDecoder.normalize(prefixed) == valid)
        // needle 出现两次（拼双份）→ 唯一切片拒 → nil（直接形状门不过，兜底歧义拒）
        let ambiguous = Data([9]) + valid + Data([9]) + valid
        #expect(UpdatePayloadQRDecoder.normalize(ambiguous) == nil)
        #expect(UpdatePayloadQRDecoder.normalize(Data(repeating: 7, count: 64)) == nil)
    }

    @Test func byteModeSegmentStripping() {
        // 构造 byte-mode 段头：模式 0b0100 + 8bit 计数 + 载荷字节（按位拼接）
        let hex = String(repeating: "b", count: 64)
        let payload = Data(("update-payload-" + hex).utf8) + Data("VLASR\u{01}".utf8)
            + Data(repeating: 1, count: 16)
        var bits: [UInt8] = []
        func append(_ value: Int, _ width: Int) {
            for index in stride(from: width - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> index) & 1))
            }
        }
        append(0b0100, 4)
        append(payload.count, 8)
        for byte in payload {
            append(Int(byte), 8)
        }
        var framed = Data()
        var current: UInt8 = 0
        var count = 0
        for bit in bits {
            current = (current << 1) | bit
            count += 1
            if count == 8 {
                framed.append(current)
                current = 0
                count = 0
            }
        }
        if count > 0 {
            // 尾比特补零至字节边界（此前丢弃尾 4bit → readBytes(count) 位不足 → 测试必红）
            framed.append(current << (8 - count))
        }
        let stripped = UpdatePayloadQRDecoder.stripByteModeSegment(framed)
        #expect(stripped == payload)
    }
}
#endif
