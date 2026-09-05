import Foundation
import Testing
import Domain
import Protocols

/// 确定性解码桩（评审修正后的注入模型：Domain 纯计算 + 解码端口注入，Linux 可测）。
/// decode 输出由数据字节派生填充——同输入同输出；不同输入产出不同位图，
/// 行为接近真实解码器（确定性是 M-QUALITY 的第一设计原则）。
/// ADR-025 注记：自研 SHA256 已随 CryptoKit 迁移退役（生产 = CryptoKitContentHasher），
/// 本桩只需确定性，直接取原始字节即可——空数据回落单字节，防 i % 0。
struct DeterministicGrayscaleDecoder: GrayscaleDecoding {
    func decode(_ data: Data, maxDimension: Int) throws -> GrayscaleImage {
        let d = max(1, maxDimension)
        let h = data.isEmpty ? [UInt8(0x5A)] : Array(data)
        var buf = [UInt8](repeating: 0, count: d * d)
        for i in 0..<buf.count { buf[i] = h[i % h.count] }
        return GrayscaleImage(width: d, height: d, buffer: buf)
    }
}

@Suite("M-QUALITY · 拍摄质量与重复检测（纯 Domain，Linux 可跑）")
struct QualityTests {
    private let decoder: any GrayscaleDecoding = DeterministicGrayscaleDecoder()
    /// 便捷入口：注入解码桩后评估（assess 本身是纯函数，不抛错）。
    private func quality(of png: Data) throws -> CaptureQuality {
        try CaptureQualityAssessor.assess(decoder.decode(png, maxDimension: 256))
    }

    /// 确定性哈希桩（ADR-025：自研 SHA256 已退役，生产注入 CryptoKitContentHasher；
    /// Linux 无 CryptoKit——重复检测只要求「同数据同哈希」，base64 保真即可）。
    private func makeService() -> DuplicateDetectionService {
        DuplicateDetectionService(hash: { $0.base64EncodedString() })
    }

    // MARK: - CaptureQualityAssessor

    @Test("同一图片两次评估质量分完全一致（确定性）", .tags(.linuxRunnable))
    func assessDeterministic() throws {
        let png = Self.testPNG()
        let q1 = try quality(of: png)
        let q2 = try quality(of: png)
        #expect(q1 == q2)
        #expect(q1.score >= 0 && q1.score <= 1)
        #expect(q1.sharpness >= 0 && q1.sharpness <= 1)
        #expect(q1.brightness >= 0 && q1.brightness <= 1)
        #expect(q1.occlusion >= 0 && q1.occlusion <= 1)
        #expect(!q1.tags.isEmpty)
    }

    @Test("meetsThreshold 阈值判定正确", .tags(.linuxRunnable))
    func meetsThreshold() throws {
        let png = Self.testPNG()
        let q = try quality(of: png)
        #expect(q.meetsThreshold(0.0) == true)
        #expect(q.meetsThreshold(1.0) == false)
    }

    // MARK: - DuplicateDetectionService

    @Test("精确哈希：同一文件副本命中 exactHashMatch", .tags(.linuxRunnable))
    func exactHashMatch() throws {
        var svc = makeService()
        let png = Self.testPNG()
        try svc.register(recordID: "rec-1", imageData: png, decoder: decoder)
        let result = try svc.detect(png, decoder: decoder)
        #expect(result.isDuplicate == true)
        #expect(result.exactHashMatch == true)
        #expect(result.perceptualSimilarity == 1.0)
    }

    @Test("精确哈希：不同文件不命中", .tags(.linuxRunnable))
    func exactHashMiss() throws {
        var svc = makeService()
        let png1 = Self.testPNG()
        let png2 = Self.testPNG(suffix: "modified")
        try svc.register(recordID: "rec-1", imageData: png1, decoder: decoder)
        let result = try svc.detect(png2, decoder: decoder)
        #expect(result.exactHashMatch == false)
    }

    @Test("感知哈希：Linux 占位基于 SHA256 派生、同数据同 pHash", .tags(.linuxRunnable))
    func perceptualSimilarity() throws {
        var svc = makeService()
        let png1 = Self.testPNG()
        // 同数据 → 同 pHash（确定性解码桩 + 确定性 pHash 纯函数）
        try svc.register(recordID: "rec-1", imageData: png1, decoder: decoder)
        let result = try svc.detect(png1, decoder: decoder)
        #expect(result.perceptualSimilarity == 1.0)
    }

    @Test("零自动删除：detect 仅返回标记，不产生删除动作", .tags(.linuxRunnable))
    func zeroAutoDelete() throws {
        var svc = makeService()
        let png = Self.testPNG()
        try svc.register(recordID: "rec-1", imageData: png, decoder: decoder)
        let result = try svc.detect(png, decoder: decoder)
        #expect(result.isDuplicate == true)
    }

    // MARK: - Helpers

    static func testPNG(suffix: String = "") -> Data {
        let base = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
        if suffix.isEmpty { return base }
        return base + Data(suffix.utf8)
    }
}

extension Tag {
    @Tag static var linuxRunnable: Tag
}
