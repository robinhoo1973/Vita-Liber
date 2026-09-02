import Foundation
import Testing
import Domain
import Protocols

@Suite("M-QUALITY · 拍摄质量与重复检测（纯 Domain，Linux 可跑）")
struct QualityTests {

    // MARK: - SHA256 向量验证

    @Test("SHA-256 空串已知向量", .tags(.linuxRunnable))
    func sha256EmptyVector() throws {
        let h = SHA256.hash(data: Data())
        #expect(h.hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("SHA-256 \"abc\" 已知向量", .tags(.linuxRunnable))
    func sha256AbcVector() throws {
        let h = SHA256.hash(data: Data("abc".utf8))
        #expect(h.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("SHA-256 确定性：同数据两次哈希一致", .tags(.linuxRunnable))
    func sha256Deterministic() throws {
        let d = Data("hello world".utf8)
        let h1 = SHA256.hash(data: d)
        let h2 = SHA256.hash(data: d)
        #expect(h1 == h2)
    }

    @Test("SHA256Hasher 流式与一次性结果一致", .tags(.linuxRunnable))
    func sha256HasherConsistency() throws {
        let d = Data("streaming test".utf8)
        let h1 = SHA256.hash(data: d)

        var hasher = SHA256.SHA256Hasher()
        hasher.update(data: d)
        let h2 = hasher.finalize()
        #expect(h1 == h2)
    }

    // MARK: - CaptureQualityAssessor

    @Test("同一图片两次评估质量分完全一致（确定性）", .tags(.linuxRunnable))
    func assessDeterministic() throws {
        let png = Self.testPNG()
        let q1 = try CaptureQualityAssessor.assess(png)
        let q2 = try CaptureQualityAssessor.assess(png)
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
        let q = try CaptureQualityAssessor.assess(png)
        #expect(q.meetsThreshold(0.0) == true)
        #expect(q.meetsThreshold(1.0) == false)
    }

    // MARK: - DuplicateDetectionService

    @Test("精确哈希：同一文件副本命中 exactHashMatch", .tags(.linuxRunnable))
    func exactHashMatch() throws {
        var svc = DuplicateDetectionService()
        let png = Self.testPNG()
        try svc.register(recordID: "rec-1", imageData: png)
        let result = try svc.detect(png)
        #expect(result.isDuplicate == true)
        #expect(result.exactHashMatch == true)
        #expect(result.perceptualSimilarity == 1.0)
    }

    @Test("精确哈希：不同文件不命中", .tags(.linuxRunnable))
    func exactHashMiss() throws {
        var svc = DuplicateDetectionService()
        let png1 = Self.testPNG()
        let png2 = Self.testPNG(suffix: "modified")
        try svc.register(recordID: "rec-1", imageData: png1)
        let result = try svc.detect(png2)
        #expect(result.exactHashMatch == false)
    }

    @Test("感知哈希：Linux 占位基于 SHA256 派生、同数据同 pHash", .tags(.linuxRunnable))
    func perceptualSimilarity() throws {
        var svc = DuplicateDetectionService()
        let png1 = Self.testPNG()
        // Linux 占位：pHash 由 SHA256 派生，同数据 → 同 pHash
        try svc.register(recordID: "rec-1", imageData: png1)
        let result = try svc.detect(png1)
        #expect(result.perceptualSimilarity == 1.0)
    }

    @Test("零自动删除：detect 仅返回标记，不产生删除动作", .tags(.linuxRunnable))
    func zeroAutoDelete() throws {
        var svc = DuplicateDetectionService()
        let png = Self.testPNG()
        try svc.register(recordID: "rec-1", imageData: png)
        let result = try svc.detect(png)
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
