#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("ASR 完整资源运行时校验")
struct ASRAssetRuntimeTests {
    @Test func 在用模型租约阻止删除目录() throws {
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
    func 模型与VAD的说明文件均验证而不冲突(_ choice: VoiceEngineChoice) throws {
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
