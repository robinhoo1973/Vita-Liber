import Foundation
import Testing
import Domain
import Protocols
import Infrastructure

@Suite("M-COMPRESS · 缩略图/模糊与敏感脱敏（Linux 占位可跑）")
struct CompressTests {

    @Test("generateThumbnail：Linux 占位返回 1x1 透明 PNG", .tags(.linuxRunnable))
    func generateThumbnailPlaceholder() async throws {
        #if os(Linux)
        let compressor = StubImageCompressor()
        #else
        return
        #endif

        let png = Self.testPNG()
        let spec = ThumbnailSpec(maxDimension: 320, blurRadius: 10, quality: 0.7)
        let thumb = try await compressor.generateThumbnail(Self.testPNG(), spec: spec)
        #expect(thumb.count > 0)
        // 占位返回 1x1 透明 PNG
        #expect(thumb.count == Self.transparentPNG().count)
    }

    @Test("authorizeOriginalAccess：非敏感策略直接返回数据", .tags(.linuxRunnable))
    func authorizeNonSensitive() async throws {
        #if os(Linux)
        let compressor = StubImageCompressor()
        #else
        return
        #endif

        let data = Self.testPNG()
        let policy = SensitiveMediaPolicy(isSensitive: false)
        let result = try await compressor.authorizeOriginalAccess(data, policy: policy)
        #expect(result == data)
    }

    @Test("authorizeOriginalAccess：敏感且需鉴权 → Linux 抛 authRequiredForOriginal", .tags(.linuxRunnable))
    func authorizeSensitiveRequiresAuth() async throws {
        #if os(Linux)
        let compressor = StubImageCompressor()
        #else
        return
        #endif

        let data = Self.testPNG()
        let policy = SensitiveMediaPolicy(isSensitive: true, requireAuthForOriginal: true)
        await #expect(throws: CompressError.authRequiredForOriginal) {
            try await compressor.authorizeOriginalAccess(data, policy: policy)
        }
    }

    @Test("SensitiveMediaProtection：isProtected / requestAccess 记录集合", .tags(.linuxRunnable))
    func sensitiveMediaProtection() async throws {
        #if os(Linux)
        let protector = StubImageCompressor()
        #else
        return
        #endif

        #expect(protector.isProtected("media-1") == false)
        let granted = try await protector.requestAccess("media-1", reason: "测试")
        #expect(granted == true)
        #expect(protector.isProtected("media-1") == true)
    }

    @Test("ThumbnailSpec / SensitiveMediaPolicy Codable 往返", .tags(.linuxRunnable))
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

    @Test("CompressError 可比较", .tags(.linuxRunnable))
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