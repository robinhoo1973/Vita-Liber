#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("ASR 完整资源运行时校验", .serialized)
struct ASRAssetRuntimeTests {
    /// 原名：在用模型租约阻止删除目录
    @Test func activeModelLeasePreventsDirectoryRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let assets = ASRModelAssets(root: root)
        var lease: ASRModelAssets.Lease? = assets.acquireLease()
        try ASRModelAssets.removeIfUnused(root)
        #expect(FileManager.default.fileExists(atPath: root.path))
        withExtendedLifetime(lease) {}
        lease = nil
        try ASRModelAssets.removeIfUnused(root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [VoiceEngineChoice.qwen3, .dolphin, .whisper])
    /// 原名：模型与VAD的说明文件均验证而不冲突
    func modelAndVADManifestsVerifyWithoutConflict(_ choice: VoiceEngineChoice) throws {
        // 2026-10-06 macOS CI 37350981011 实证:测试宿主 bundle 无 App 资源,
        // 共享信任库无种子 → routingIndex() 恒 nil → 校验目录描述符闸恒
        // engineUnavailable。注入含本测试全部 choice 的签名目录夹具
        // (SignedModelCatalogTests.Fixture 恰为 qwen3/zipformer/dolphin/whisper)。
        let fixture = try SignedModelCatalogTests.Fixture()
        let store = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: nil)
        let seededIndex = try store.acceptCatalog(fixture.catalog(version: 1))
        ASRFamilyIndexStore.routingIndexOverride = seededIndex
        defer { ASRFamilyIndexStore.routingIndexOverride = nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: 隔离校验夹具清理
        let roles: [String]
        switch choice {
        case .qwen3: roles = ["frontend", "encoder", "decoder", "vocab", "merges", "tokenizerConfig"]
        case .dolphin: roles = ["model", "tokens"]
        default: roles = ["encoder", "decoder", "tokens"]
        }
        func file(_ role: String, _ name: String) throws -> [String: Any] {
            let data = Data(name.utf8)
            try data.write(to: root.appendingPathComponent(name))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ["role": role, "path": name, "bytes": data.count, "sha256": hash]
        }
        var files = try roles.map { try file($0, $0 + ".onnx") }
        files.append(try file("notice", "MODEL-LICENSE"))
        let shared = [try file("vad", "vad.onnx"), try file("notice", "VAD-LICENSE")]
        let manifest: [String: Any] = ["formatVersion": 1, "models": [["id": choice.rawValue,
            "license": choice == .whisper ? "MIT" : "Apache-2.0", "revision": "fixture", "files": files]], "shared": shared]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let assets = ASRModelAssets(root: root)
        _ = try assets.validate(choice)
        #expect(assets.isPresent(choice))
        try Data("bad".utf8).write(to: root.appendingPathComponent("VAD-LICENSE"))
        #expect(throws: (any Error).self) { try assets.validate(choice) }
    }
}
#endif
