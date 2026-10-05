#if os(iOS) || os(macOS)
import Foundation
import Testing
@testable import Infrastructure

/// 信封字节合同金样（2026-10-05 审查补齐）：`scripts/release/asr_envelope.py`
/// 用主密钥（= ASRPackageCrypto.masterKeyHex）与身份 `qwen3--v1.0-r2` 生成的
/// 确定性信封必须被 Swift 侧逐字节解开——两侧 HKDF 派生（Swift 32 字节派生
/// 取前 12 vs python 直接 len=12，RFC 5869 前缀性质）、零盐语义、AAD 布局
/// （header + u32 BE 块序号）任何一侧漂移即红。这是 L1 层唯一的
/// Swift↔python 逐字节闸门：此前两侧只有各自语言的往返测试，跨语言漂移
/// 只能在真机下载报 authenticationFailed 才发现。
@Suite("ASR 信封跨语言字节合同")
struct ASREnvelopeGoldenTests {
    private static let identity = "qwen3--v1.0-r2"
    private static let plaintext = "VitaLiber ASR envelope golden vector (Swift-python byte contract).\n"
    private static let envelopeBase64 = "VkxBU1IBAQQAAAAAAAAAAAAAQwAAAAEAAABTYpWiRI7riSetxu3jaE2BYGylXagHA4NqCCX2y172sER8gPYhW8QLTZhCI36DSsq4J0GrMvlfbAymglsTR8HRjYoKuCb0KJGP8DqVirFLA7qbz3Q="

    private func scratchDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func pythonGeneratedEnvelopeDecryptsByteForByte() throws {
        let envelope = try #require(Data(base64Encoded: Self.envelopeBase64))
        #expect(ASRPackageCrypto.isEnvelope(envelope))
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: 隔离夹具清理
        let source = root.appendingPathComponent("envelope.bin")
        let destination = root.appendingPathComponent("plain.bin")
        try envelope.write(to: source)
        try ASRPackageCrypto.decryptEnvelope(at: source, to: destination, identity: Self.identity)
        let decrypted = try Data(contentsOf: destination)
        #expect(decrypted == Data(Self.plaintext.utf8))
    }

    @Test func tamperedEnvelopeFailsAuthentication() throws {
        let envelope = try #require(Data(base64Encoded: Self.envelopeBase64))
        var tampered = envelope
        tampered[tampered.count - 1] ^= 0xFF   // 翻转末块 tag 尾字节 → 认证必败
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: 隔离夹具清理
        let source = root.appendingPathComponent("envelope.bin")
        let destination = root.appendingPathComponent("plain.bin")
        try tampered.write(to: source)
        #expect(throws: (any Error).self) {
            try ASRPackageCrypto.decryptEnvelope(at: source, to: destination, identity: Self.identity)
        }
    }

    @Test func wrongIdentityFailsAuthentication() throws {
        let envelope = try #require(Data(base64Encoded: Self.envelopeBase64))
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: 隔离夹具清理
        let source = root.appendingPathComponent("envelope.bin")
        let destination = root.appendingPathComponent("plain.bin")
        try envelope.write(to: source)
        // 身份进入 key/nonce 派生——身份串漂移（variant/version/revision 拼装错误）
        // 必须以认证失败拒绝，而不是解出垃圾或崩溃。
        #expect(throws: (any Error).self) {
            try ASRPackageCrypto.decryptEnvelope(at: source, to: destination, identity: "qwen3--v1.0-r3")
        }
    }
}
#endif
