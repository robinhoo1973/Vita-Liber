import Foundation
import Testing
import Protocols
@testable import Infrastructure

/// medical-data Release 线协议契约（平台中立，Linux 可跑）：Go `medrelease`
/// 导出的 golden 夹具必须被 Swift 按原字节解码、按同一规则接受/拒绝。
/// Ed25519 验签本身在 `MedicalCatalogReleaseAcceptanceTests`（CryptoKit，macOS CI）。
@Suite("Medical catalog release wire contract")
struct MedicalCatalogUpdateTests {
    private let acceptAll = MedicalCatalogTrustEvaluator(hasher: ReferenceSHA256(), isValidSignature: { _, _, _ in true })
    private let rejectAll = MedicalCatalogTrustEvaluator(hasher: ReferenceSHA256(), isValidSignature: { _, _, _ in false })

    // MARK: pinned root

    @Test("Go pinned root decodes with key-ID binding and 2-of-2 key sets")
    func goPinnedRootDecodes() throws {
        let expected = try GoMedicalFixture.expected()
        let root = try acceptAll.pinnedRoot(GoMedicalFixture.data("pinned-root.json"), now: expected.nowDate)
        #expect(root.version == 1)
        #expect(root.keys.count == 4)
        #expect(root.rootKeyIDs == expected.rootKeyIDs)
        #expect(root.catalogKeyIDs == expected.catalogKeyIDs)
    }

    @Test("pinned root still needs its own 2 root signatures")
    func pinnedRootNeedsRootSignatures() throws {
        let expected = try GoMedicalFixture.expected()
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try rejectAll.pinnedRoot(GoMedicalFixture.data("pinned-root.json"), now: expected.nowDate)
        }
        let oneSignature = try GoMedicalFixture.dropSignatures(GoMedicalFixture.data("pinned-root.json"), keeping: 1)
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try acceptAll.pinnedRoot(oneSignature, now: expected.nowDate)
        }
    }

    @Test("pinned root structural gates: thresholds, key binding, base URL, hosts, expiry")
    func pinnedRootStructuralGates() throws {
        let expected = try GoMedicalFixture.expected()
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let cases: [(MedicalCatalogTrustError, (inout [String: Any]) -> Void)] = [
            (.invalidKeySet, { $0["rootThreshold"] = 1 }),
            (.invalidKeySet, { $0["catalogThreshold"] = 1 }),
            (.invalidKeySet, { $0["catalogKeyIDs"] = expected.rootKeyIDs }),
            (.invalidKeySet, { root in
                var keys = root["keys"] as? [[String: Any]] ?? []
                keys[0]["id"] = String(repeating: "0", count: 64)
                root["keys"] = keys
            }),
            (.invalidScope, { $0["assetBaseURL"] = "https://github.com/someone/else/releases/download/medical-data" }),
            (.invalidScope, { $0["allowedHosts"] = ["github.com", "evil.example.com"] }),
            (.invalidScope, { $0["role"] = "catalog" }),
            (.expired, { $0["expiresAt"] = "2026-09-26T12:59:59Z" }),
            (.invalidField, { $0["expiresAt"] = "2028-09-26T12:00:00.000Z" }),
            (.malformedEnvelope, { $0["unexpected"] = true }),
        ]
        for (error, mutate) in cases {
            let mutated = try GoMedicalFixture.rewrap(pin, mutate: mutate)
            #expect(throws: error) { try acceptAll.pinnedRoot(mutated, now: expected.nowDate) }
        }
    }

    // 2026-10-28 切片-only B2：v3 签名指针/期望绑定各节随 `MedicalCatalogSignedPointer`
    // 一并删除（切片清单验签在 `CatalogSliceManifestTests` 覆盖同一 2-of-2/信封语义）。

    @Test("envelope shape is strict: duplicates, bad base64, wrong sizes, unknown fields")
    func envelopeShapeIsStrict() throws {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installableManifest)
        let payload = try GoMedicalFixture.payload(of: pointer)
        let signature = Data(repeating: 1, count: 64)
        let id = expected.catalogKeyIDs[0]
        let malformed: [Data] = [
            Data("{}".utf8),
            Data("not json".utf8),
            GoMedicalFixture.envelope(payload: payload, signatures: []),
            GoMedicalFixture.envelope(payload: payload, signatures: [(id, signature), (id, signature)]),
            GoMedicalFixture.envelope(payload: payload, signatures: [(id, Data(repeating: 1, count: 63))]),
            GoMedicalFixture.envelope(payload: Data(), signatures: [(id, signature)]),
            Data(#"{"payload":"@@@","signatures":[]}"#.utf8),
            try GoMedicalFixture.addingEnvelopeField(pointer),
        ]
        for json in malformed {
            // 切片-only（2026-10-28）：信封严格性直测——八类畸形全在信封层，
            // 载荷解码由 CatalogSliceManifestTests 覆盖。
            #expect(throws: MedicalCatalogTrustError.malformedEnvelope) {
                _ = try MedicalCatalogSignedEnvelope.decode(json)
            }
        }
    }

    // MARK: names, transport policy, installer helpers

    @Test("v3 asset-name grammar matches the Go names (fixed names + package-<version>.bin)")
    func assetNamesMatchGo() throws {
        let expected = try GoMedicalFixture.expected()
        #expect(MedicalCatalogReleaseProtocol.manifestAssetName == expected.manifestAssetName)
        #expect(MedicalCatalogReleaseProtocol.overviewAssetName == expected.overviewAssetName)
        #expect(MedicalCatalogReleaseProtocol.packageAssetName(catalogVersion: expected.catalogVersion) == expected.packageAssetName)
        #expect(MedicalCatalogReleaseProtocol.packageAssetVersion(expected.packageAssetName) == expected.catalogVersion)
        #expect(MedicalCatalogReleaseProtocol.packageAssetVersion("package-9223372036854775807.bin") == Int64.max)
        #expect(MedicalCatalogReleaseProtocol.isPackageAssetName(expected.packageAssetName))
        let rejected = ["package-41.bin\n", "medical-data-package-sqlite-../x.bin",
                        "medical-data-package-sqlite-\(expected.packageSha256).bin",   // v2 长名退役
                        "package-0.bin", "package-020.bin", "package-.bin",
                        "package-20.BIN", "PACKAGE-20.bin", "package-２０.bin", "package-٢١.bin",
                        "package-99999999999999999999.bin"]   // 20 位版本
        for name in rejected {
            #expect(!MedicalCatalogReleaseProtocol.isPackageAssetName(name), "不得接受 \(name)")
        }
        #expect(MedicalCatalogReleaseProtocol.packageURL(assetName: expected.packageAssetName)?.absoluteString
                == "https://cnb.cool/robinhoo1973/Resources/-/releases/download/medical-data/" + expected.packageAssetName)
        #expect(MedicalCatalogReleaseProtocol.packageURL(assetName: "medical-catalog.sqlite") == nil)
    }

    @Test("package transfer only follows HTTPS release hosts")
    func transferURLPolicy() throws {
        let allowed = [
            "https://asset.cnb.cool/robinhoo1973/Resources/1",
            "https://cnb.cool/robinhoo1973/Resources/-/releases/download/medical-data/x.bin",
        ]
        let rejected = [
            "http://asset.cnb.cool/x.bin",
            "https://evil.example.com/x.bin",
            "https://asset.cnb.cool.evil.example.com/x.bin",
            "https://user:pass@asset.cnb.cool/x.bin",
            "https://asset.cnb.cool:8443/x.bin",
            "file:///tmp/x.bin",
            "https://github.com/robinhoo1973/Vita-Liber/releases/download/medical-data/x.bin",
        ]
        for value in allowed { #expect(MedicalCatalogReleaseProtocol.allowsTransferURL(try #require(URL(string: value)))) }
        for value in rejected { #expect(!MedicalCatalogReleaseProtocol.allowsTransferURL(try #require(URL(string: value)))) }
    }

    @Test("fileSize reports regular-file bytes and throws for missing files or directories")
    func fileSizeHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("medical-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // try?-ok: 隔离测试目录清理
        let file = directory.appendingPathComponent("package.bin")
        try Data(repeating: 9, count: 747).write(to: file)
        #expect(try CatalogPackageFiles.size(of: file) == 747)
        #expect(throws: (any Error).self) { try CatalogPackageFiles.size(of: directory.appendingPathComponent("missing")) }
        #expect(throws: (any Error).self) { try CatalogPackageFiles.size(of: directory) }
    }
}

// MARK: - Go golden fixture helpers

struct GoMedicalExpected: Decodable {
    let catalogKeyIDs: [String]
    let rootKeyIDs: [String]
    let catalogVersion: Int64
    let dataVersion: String
    let expiresAt: String
    let issuedAt: String
    let now: String
    let installable: Bool
    let manifestAssetName: String
    let overviewAssetName: String
    let installableManifest: String
    let progressManifest: String
    let expiredManifest: String
    let packageAssetName: String
    let packageSha256: String
    let packageSize: Int64
    let sqliteSha256: String
    let sqliteSchemaVersion: Int
    let releaseTag: String
    let repository: String
    let zipEntryName: String

    var nowDate: Date { MedicalCatalogReleaseProtocol.timestamp(now) ?? .distantPast }
}

enum GoMedicalFixture {
    static var directory: String { TestFixtures.path("medical/") }

    static func url(_ name: String) -> URL { URL(fileURLWithPath: directory + name) }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func expected() throws -> GoMedicalExpected {
        try JSONDecoder().decode(GoMedicalExpected.self, from: data("expected.json"))
    }

    static func date(_ value: String) throws -> Date {
        try #require(MedicalCatalogReleaseProtocol.timestamp(value))
    }

    static func object(_ json: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    static func payload(of envelopeJSON: Data) throws -> Data {
        let encoded = try #require(try object(envelopeJSON)["payload"] as? String)
        return try #require(Data(base64Encoded: encoded))
    }

    /// 改写 payload 字段后按原签名重新封装：只验证字段门/期望绑定，签名有效性由验签替身决定。
    static func rewrap(_ envelopeJSON: Data, mutate: (inout [String: Any]) -> Void) throws -> Data {
        var envelope = try object(envelopeJSON)
        var payload = try object(payload(of: envelopeJSON))
        mutate(&payload)
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        envelope["payload"] = bytes.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    static func dropSignatures(_ envelopeJSON: Data, keeping count: Int) throws -> Data {
        var envelope = try object(envelopeJSON)
        let signatures = try #require(envelope["signatures"] as? [Any])
        envelope["signatures"] = Array(signatures.prefix(count))
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    static func addingEnvelopeField(_ envelopeJSON: Data) throws -> Data {
        var envelope = try object(envelopeJSON)
        envelope["rootJSON"] = "network-supplied"
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    static func envelope(payload: Data, signatures: [(String, Data)]) -> Data {
        let entries = signatures.map { #"{"keyId":""# + $0.0 + #"","signature":""# + $0.1.base64EncodedString() + #""}"# }
        return Data((#"{"payload":""# + payload.base64EncodedString() + #"","signatures":["#
                     + entries.joined(separator: ",") + "]}").utf8)
    }
}

/// 参考 SHA-256：Apple 平台走 CryptoKit；Linux 测试宿主无 CryptoKit，借系统 `sha256sum`
/// 作独立参照（仅测试，生产哈希一律 CryptoKit——ADR-025）。
struct ReferenceSHA256: ContentHashing {
    func sha256Hex(_ data: Data) -> String {
        #if os(iOS) || os(macOS)
        return CryptoKitContentHasher().sha256Hex(data)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sha256sum"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        do { try process.run() } catch { return "" }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.closeFile()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: result.prefix(64), as: UTF8.self)
        #endif
    }
}
