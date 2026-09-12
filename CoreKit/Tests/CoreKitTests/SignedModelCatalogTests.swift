#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Testing
@testable import Domain
@testable import Infrastructure

@Suite("ASR Release 签名目录与授权")
struct SignedModelCatalogTests {
    @Test func 双签目录授权编译后新版本并拒绝篡改字段() throws {
        let fixture = try Fixture()
        let store = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: nil)
        let index = try store.acceptCatalog(fixture.catalog(version: 1))
        #expect(index.models.count == 4)
        #expect(store.isAuthorized(index.models[0]))
        var changed = index.models[0]
        changed.sha256 = String(repeating: "b", count: 64)
        #expect(!store.isAuthorized(changed))
        changed = index.models[0]
        changed.minAppVersion = "0.0.0"
        #expect(!store.isAuthorized(changed))
    }

    @Test func 重复签名不能凑足门限() throws {
        let fixture = try Fixture()
        let store = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: nil)
        #expect(throws: (any Error).self) { try store.acceptCatalog(fixture.catalog(version: 1, duplicate: true)) }
    }

    @Test func 过期与回滚拒绝且不覆盖有效授权() throws {
        let fixture = try Fixture()
        let store = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: nil)
        let current = try store.acceptCatalog(fixture.catalog(version: 3))
        #expect(throws: (any Error).self) { try store.acceptCatalog(fixture.catalog(version: 2)) }
        #expect(throws: (any Error).self) { try store.acceptCatalog(fixture.catalog(version: 4, expired: true)) }
        #expect(store.isAuthorized(current.models[0]))
    }

    @Test func 重启恢复已验证的目录与防回滚状态() throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) } // try?-ok: 隔离测试目录清理
        let url = directory.appendingPathComponent("trust.json")
        let first = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: url)
        let index = try first.acceptCatalog(fixture.catalog(version: 3))
        let restored = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: url)
        #expect(restored.isAuthorized(index.models[0]))
        #expect(throws: (any Error).self) { try restored.acceptCatalog(fixture.catalog(version: 2)) }
    }

    @Test func 新安装以内嵌版本和摘要建立回滚下界() throws {
        let fixture = try Fixture()
        let current = try fixture.catalog(version: 3)
        let envelope = try JSONDecoder().decode(SignedModelEnvelope.self, from: current)
        let catalog = try JSONDecoder().decode(SignedModelCatalog.self, from: envelope.payload)
        let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog.index.models))
        let baseline: [String: Any] = ["schemaVersion": 1, "rootVersion": 1, "catalogVersion": 3,
            "catalogSHA256": SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined(), "entries": entries]
        let store = ModelCatalogTrustStore(bootstrapData: fixture.root,
            baselineData: try JSONSerialization.data(withJSONObject: baseline), stateURL: nil)
        #expect(throws: (any Error).self) { try store.acceptCatalog(fixture.catalog(version: 2)) }
        #expect(try store.acceptCatalog(current).models.count == 4)
    }

    @Test func 目录撤销可供已安装模型解析检查() throws {
        let fixture = try Fixture()
        let store = ModelCatalogTrustStore(bootstrapData: fixture.root, baselineData: nil, stateURL: nil)
        let old = try store.acceptCatalog(fixture.catalog(version: 1))
        let retained = ASRModelAssets(root: nil, packageSHA256: old.models[0].sha256, trust: store)
        try retained.checkPackageAuthorization()
        _ = try store.acceptCatalog(fixture.catalog(version: 2, checksum: String(repeating: "b", count: 64),
                                                     revoked: [String(repeating: "a", count: 64)]))
        #expect(store.isRevoked(old.models[0].sha256))
        #expect(!store.isAuthorized(old.models[0]))
        #expect(throws: (any Error).self) { try retained.checkPackageAuthorization() }
    }

    private struct Fixture {
        let root: Data
        let keys: [Curve25519.Signing.PrivateKey]
        let identifiers: [String]
        init() throws {
            keys = (0..<6).map { _ in Curve25519.Signing.PrivateKey() }
            identifiers = keys.map { SHA256.hash(data: $0.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined() }
            let value: [String: Any] = ["schemaVersion": 1, "role": "root", "app": "vitaliber", "assetKind": "asr", "version": 1,
                "expiresAt": Self.timestamp(730 * 86400), "keys": zip(identifiers, keys).map { ["id": $0.0, "publicKey": $0.1.publicKey.rawRepresentation.base64EncodedString()] },
                "rootKeyIDs": Array(identifiers.prefix(3)), "rootThreshold": 2,
                "catalogKeyIDs": Array(identifiers.suffix(3)), "catalogThreshold": 2,
                "assetBaseURL": "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models",
                "allowedHosts": ["github.com", "release-assets.githubusercontent.com"]]
            root = try Self.sign(value, indices: [0, 1], keys: keys, identifiers: identifiers)
        }
        func catalog(version: Int, duplicate: Bool = false, expired: Bool = false,
                     checksum: String = String(repeating: "a", count: 64), revoked: [String] = []) throws -> Data {
            let models: [[String: Any]] = ["qwen3", "zipformer", "dolphin", "whisper"].map {
                ["id": $0, "version": "9.0.0", "url": $0 + ".zip", "bytes": 123, "expandedBytes": 456,
                 "sha256": checksum, "runtime": "sherpa-onnx-1.13.4", "packaging": "zip",
                 "minAppVersion": "0.0.1", "license": $0 == "whisper" ? "MIT" : "Apache-2.0"]
            }
            let value: [String: Any] = ["schemaVersion": 1, "role": "catalog", "app": "vitaliber", "assetKind": "asr",
                "rootVersion": 1, "catalogVersion": version, "issuedAt": Self.timestamp(-60),
                "expiresAt": Self.timestamp(expired ? -10 : 29 * 86400), "revokedHashes": revoked,
                "index": ["schemaVersion": 1, "baseUrl": "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models", "models": models]]
            return try Self.sign(value, indices: duplicate ? [3, 3] : [3, 4], keys: keys, identifiers: identifiers)
        }
        static func timestamp(_ offset: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
        }
        static func sign(_ value: [String: Any], indices: [Int], keys: [Curve25519.Signing.PrivateKey], identifiers: [String]) throws -> Data {
            let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let signatures = try indices.map { ["keyId": identifiers[$0], "signature": try keys[$0].signature(for: payload).base64EncodedString()] }
            return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signatures": signatures])
        }
    }
}
#endif
