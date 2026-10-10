import Foundation
import Testing
import Domain
import Protocols
import Infrastructure

@Suite("M-COMPRESS · 缩略图/模糊与敏感脱敏（Linux 占位可跑）")
struct CompressTests {

    @Test("generateThumbnail：Linux 占位返回 1x1 透明 PNG")
    func generateThumbnailPlaceholder() async throws {
        let compressor = StubImageCompressor()

        let spec = ThumbnailSpec(maxDimension: 320, blurRadius: 10, quality: 0.7)
        let thumb = try await compressor.generateThumbnail(Self.testPNG(), spec: spec)
        #expect(thumb.count > 0)
        // 占位返回 1x1 透明 PNG
        #expect(thumb.count == Self.transparentPNG().count)
    }

    // 收口批D（2026-10-10）：authorizeOriginalAccess 两条用例随协议成员一并
    // 移除（生产轨零调用，原图解锁门在 App 层 SensitiveMediaContainer/
    // SensitiveMediaOriginalView，存储经 SensitiveAssetStore）。
    // 审查修复（2026-09-18 死抽象清除）：SensitiveMediaProtection 协议及两侧
    // 实现已删除（零消费方；BR-007/008 实际执行在 SensitiveAssetStore），
    // 本测试随协议一并移除。

    @Test("ThumbnailSpec / SensitiveMediaPolicy Codable 往返")
    func codableRoundtrip() throws {
        let spec = ThumbnailSpec(maxDimension: 256, blurRadius: 8, quality: 0.8)
        let sdata = try JSONEncoder().encode(spec)
        let sdec = try JSONDecoder().decode(ThumbnailSpec.self, from: sdata)
        #expect(sdec == spec)

        let policy = SensitiveMediaPolicy(isSensitive: true, requireAuthForOriginal: true, forceBlurThumbnail: true)
        let pdata = try JSONEncoder().encode(policy)
        let pdec = try JSONDecoder().decode(SensitiveMediaPolicy.self, from: pdata)
        #expect(pdec == policy)
    }

    @Test("CompressError 可比较")
    func errorEquatable() {
        #expect(CompressError.encodeFailed == CompressError.encodeFailed)
        #expect(CompressError.encodeFailed != CompressError.decodeFailed)
    }
}

extension CompressTests {
    static func testPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
    static func transparentPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
}