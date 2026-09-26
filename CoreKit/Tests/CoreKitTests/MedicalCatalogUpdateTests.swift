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

    @Test("replacement root is structurally valid, but pointers never verify under it and it cannot pose as a pointer")
    func replacementRootIsNotThePin() throws {
        let expected = try GoMedicalFixture.expected()
        let replacement = try GoMedicalFixture.data("replacement-root.json")
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let replacementRoot = try acceptAll.pinnedRoot(replacement, now: expected.nowDate)
        #expect(replacementRoot.catalogKeyIDs != expected.catalogKeyIDs)
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try acceptAll.verify(pinnedRootJSON: replacement, catalogJSON: pointer, expected: expectation, now: expected.nowDate)
        }
        #expect(throws: MedicalCatalogTrustError.self) {
            try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: replacement, expected: expectation, now: expected.nowDate)
        }
    }

    // MARK: signed pointer

    @Test("Go installable pointer decodes to the exported field values")
    func goInstallablePointerDecodes() throws {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let value = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        #expect(value.catalogVersion == expected.catalogVersion)
        #expect(value.dataVersion == expected.dataVersion)
        #expect(value.schemaVersion == expected.sqliteSchemaVersion)
        #expect(value.packageAssetName == expected.packageAssetName)
        #expect(value.packageSize == expected.packageSize)
        #expect(value.packageSHA256 == expected.packageSha256)
        #expect(value.sqliteSHA256 == expected.sqliteSha256)
        #expect(value.installable == expected.installable)
        #expect(value.issuedAt == MedicalCatalogReleaseProtocol.timestamp(expected.issuedAt))
        #expect(value.expiresAt == MedicalCatalogReleaseProtocol.timestamp(expected.expiresAt))
        #expect(value.repository == expected.repository)
        #expect(value.releaseTag == expected.releaseTag)
        let payload = try GoMedicalFixture.payload(of: pointer)
        #expect(value.signedPointerDigest == ReferenceSHA256().sha256Hex(payload))
    }

    @Test("Go installable pointer passes the pinned evaluation; unsigned bytes do not")
    func goInstallablePointerVerifies() throws {
        let expected = try GoMedicalFixture.expected()
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: pointer, expected: expectation, now: expected.nowDate)
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try rejectAll.verify(pinnedRootJSON: pin, catalogJSON: pointer, expected: expectation, now: expected.nowDate)
        }
    }

    @Test("progress pointer decodes as non-installable and cannot be served under an installable name")
    func progressPointerIsNotInstallable() throws {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.progressPointer)
        let value = try GoMedicalFixture.expectation(pointer, servedAs: expected.progressPointer)
        #expect(value.installable == false)
        #expect(value.catalogVersion == 21)
        #expect(throws: MedicalCatalogTrustError.assetNameMismatch) {
            try GoMedicalFixture.expectation(pointer, servedAs: "medical-data-catalog-installable-21.json")
        }
        let candidate = VerifiedMedicalCatalogCandidate(verified: value)
        #expect(candidate.installable == false)
    }

    @Test("expired pointer is rejected by the decoder and by the evaluator")
    func expiredPointerRejected() throws {
        let expected = try GoMedicalFixture.expected()
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let expired = try GoMedicalFixture.data(expected.expiredPointer)
        #expect(throws: MedicalCatalogTrustError.expired) {
            try GoMedicalFixture.expectation(expired, servedAs: expected.expiredPointer)
        }
        let stale = try GoMedicalFixture.expectation(expired, servedAs: expected.expiredPointer,
                                                     now: GoMedicalFixture.date("2026-09-01T00:00:00Z"))
        #expect(throws: MedicalCatalogTrustError.expired) {
            try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: expired, expected: stale, now: expected.nowDate)
        }
    }

    @Test("single catalog signature cannot reach the threshold")
    func singleSignatureRejected() throws {
        let expected = try GoMedicalFixture.expected()
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let single = try GoMedicalFixture.data("pointer-single-signature.json")
        let expectation = try GoMedicalFixture.expectation(single, servedAs: expected.installablePointer)
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: single, expected: expectation, now: expected.nowDate)
        }
    }

    @Test("root keys may never sign a pointer; unknown key IDs are ignored but never count")
    func onlyCatalogKeysCount() throws {
        let expected = try GoMedicalFixture.expected()
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        let payload = try GoMedicalFixture.payload(of: pointer)
        let fakeSignature = Data(repeating: 7, count: 64)
        let byRootKeys = GoMedicalFixture.envelope(payload: payload, signatures: expected.rootKeyIDs.map { ($0, fakeSignature) })
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: byRootKeys, expected: expectation, now: expected.nowDate)
        }
        let unknown = String(repeating: "e", count: 64)
        let withUnknown = GoMedicalFixture.envelope(
            payload: payload,
            signatures: [(unknown, fakeSignature)] + expected.catalogKeyIDs.map { ($0, fakeSignature) })
        try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: withUnknown, expected: expectation, now: expected.nowDate)
        let unknownPlusOne = GoMedicalFixture.envelope(
            payload: payload, signatures: [(unknown, fakeSignature), (expected.catalogKeyIDs[0], fakeSignature)])
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: unknownPlusOne, expected: expectation, now: expected.nowDate)
        }
    }

    @Test("envelope shape is strict: duplicates, bad base64, wrong sizes, unknown fields")
    func envelopeShapeIsStrict() throws {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
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
            #expect(throws: MedicalCatalogTrustError.malformedEnvelope) {
                try MedicalCatalogSignedPointerDecoder.expectation(
                    catalogJSON: json, servedAs: expected.installablePointer, now: expected.nowDate, hasher: ReferenceSHA256())
            }
        }
    }

    @Test("each signed pointer field gate rejects on its own")
    func pointerFieldGates() throws {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let upper = expected.sqliteSha256.uppercased()
        let cases: [(MedicalCatalogTrustError, (inout [String: Any]) -> Void)] = [
            (.invalidScope, { $0["repository"] = "someone/Vita-Liber" }),
            (.invalidScope, { $0["releaseTag"] = "medical-data-old" }),
            (.invalidScope, { $0["role"] = "root" }),
            (.invalidScope, { $0["app"] = "other" }),
            (.invalidScope, { $0["assetKind"] = "asr-model" }),
            (.invalidScope, { $0["schemaVersion"] = 2 }),
            (.invalidField, { $0["sqliteSchemaVersion"] = 6 }),
            (.invalidField, { $0["packageSize"] = 0 }),
            (.invalidField, { $0["sqliteSha256"] = upper }),
            (.invalidField, { $0["packageSha256"] = "abc" }),
            (.invalidField, { $0["dataVersion"] = "v20" }),
            (.invalidField, { $0["fetchStateSha256"] = "" }),
            (.invalidField, { $0["catalogVersion"] = 0 }),
            (.invalidField, { $0["rootVersion"] = 0 }),
            (.invalidField, { $0["issuedAt"] = "2026-09-26T12:00:00+00:00" }),
            (.invalidField, { $0["installable"] = "true" }),
            (.invalidField, { $0["extra"] = 1 }),
            (.invalidField, { $0.removeValue(forKey: "manifestSha256") }),
            (.assetNameMismatch, { $0["packageAssetName"] = "medical-data-package-sqlite-\(String(repeating: "a", count: 64))-cipher-\(expected.packageSha256).bin" }),
            (.expired, { $0["expiresAt"] = "2026-10-28T12:00:01Z" }),
            (.expired, { $0["expiresAt"] = "2026-09-26T12:00:00Z" }),
            (.expired, { $0["issuedAt"] = "2026-09-26T13:05:01Z"; $0["expiresAt"] = "2026-10-27T13:05:01Z" }),
        ]
        for (error, mutate) in cases {
            let mutated = try GoMedicalFixture.rewrap(pointer, mutate: mutate)
            #expect(throws: error) {
                try GoMedicalFixture.expectation(mutated, servedAs: expected.installablePointer)
            }
        }
    }

    @Test("signed fields that differ from the expectation are rejected even when otherwise valid")
    func signedExpectationBinding() throws {
        let expected = try GoMedicalFixture.expected()
        let pin = try GoMedicalFixture.data("pinned-root.json")
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let expectation = try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer)
        let otherHash = String(repeating: "c", count: 64)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["packageSize"] = expected.packageSize + 1 },
            { $0["dataVersion"] = otherHash },
            { $0["contentSha256"] = otherHash },
            { $0["packageSha256"] = otherHash
              $0["packageAssetName"] = MedicalCatalogReleaseProtocol.packageAssetName(sqliteSHA256: expected.sqliteSha256, packageSHA256: otherHash) },
            { $0["sqliteSha256"] = otherHash
              $0["packageAssetName"] = MedicalCatalogReleaseProtocol.packageAssetName(sqliteSHA256: otherHash, packageSHA256: expected.packageSha256) },
            { $0["catalogVersion"] = 22 },
            { $0["installable"] = false },
        ]
        for mutate in mutations {
            let mutated = try GoMedicalFixture.rewrap(pointer, mutate: mutate)
            #expect(throws: MedicalCatalogTrustError.expectationMismatch) {
                try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: mutated, expected: expectation, now: expected.nowDate)
            }
        }
        let rolled = try GoMedicalFixture.rewrap(pointer) { $0["rootVersion"] = 2 }
        #expect(throws: MedicalCatalogTrustError.rootMismatch) {
            try acceptAll.verify(pinnedRootJSON: pin, catalogJSON: rolled, expected: expectation, now: expected.nowDate)
        }
    }

    // MARK: names, transport policy, installer helpers

    @Test("asset-name grammar matches the Go names")
    func assetNamesMatchGo() throws {
        let expected = try GoMedicalFixture.expected()
        #expect(MedicalCatalogReleaseProtocol.pointerAssetName(installable: true, catalogVersion: 20) == expected.installablePointer)
        #expect(MedicalCatalogReleaseProtocol.pointerAssetName(installable: false, catalogVersion: 21) == expected.progressPointer)
        #expect(MedicalCatalogReleaseProtocol.packageAssetName(sqliteSHA256: expected.sqliteSha256,
                                                              packageSHA256: expected.packageSha256) == expected.packageAssetName)
        #expect(MedicalCatalogReleaseProtocol.isPackageAssetName(expected.packageAssetName))
        #expect(!MedicalCatalogReleaseProtocol.isPackageAssetName("medical-data-package-sqlite-../x.bin"))
        #expect(!MedicalCatalogReleaseProtocol.isPackageAssetName(expected.packageAssetName.uppercased()))
        #expect(MedicalCatalogReleaseProtocol.packageURL(assetName: expected.packageAssetName)?.absoluteString
                == "https://github.com/robinhoo1973/Vita-Liber/releases/download/medical-data/" + expected.packageAssetName)
        #expect(MedicalCatalogReleaseProtocol.packageURL(assetName: "medical-catalog.sqlite") == nil)
    }

    @Test("package transfer only follows HTTPS release hosts")
    func transferURLPolicy() throws {
        let allowed = [
            "https://github.com/robinhoo1973/Vita-Liber/releases/download/medical-data/x.bin",
            "https://release-assets.githubusercontent.com/github-production-release-asset/1",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1",
        ]
        let rejected = [
            "http://github.com/robinhoo1973/Vita-Liber/releases/download/medical-data/x.bin",
            "https://evil.example.com/x.bin",
            "https://github.com.evil.example.com/x.bin",
            "https://user:pass@github.com/x.bin",
            "https://github.com:8443/x.bin",
            "file:///tmp/x.bin",
        ]
        for value in allowed { #expect(MedicalCatalogReleaseProtocol.allowsTransferURL(try #require(URL(string: value)))) }
        for value in rejected { #expect(!MedicalCatalogReleaseProtocol.allowsTransferURL(try #require(URL(string: value)))) }
    }

    @Test("sameDataVersion only when schema and data version both match")
    func sameDataVersionNeedsBoth() throws {
        let expected = try GoMedicalFixture.expected()
        let pointer = try GoMedicalFixture.data(expected.installablePointer)
        let candidate = VerifiedMedicalCatalogCandidate(
            verified: try GoMedicalFixture.expectation(pointer, servedAs: expected.installablePointer))
        let same = MedicalCatalogInstalledVersion(schemaVersion: 5, dataVersion: expected.dataVersion)
        #expect(MedicalCatalogUpdateService.sameDataVersion(local: same, candidate: candidate))
        #expect(!MedicalCatalogUpdateService.sameDataVersion(
            local: MedicalCatalogInstalledVersion(schemaVersion: 4, dataVersion: expected.dataVersion), candidate: candidate))
        #expect(!MedicalCatalogUpdateService.sameDataVersion(
            local: MedicalCatalogInstalledVersion(schemaVersion: 5, dataVersion: String(repeating: "0", count: 64)), candidate: candidate))
    }

    @Test("fileSize reports regular-file bytes and throws for missing files or directories")
    func fileSizeHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("medical-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // try?-ok: 隔离测试目录清理
        let file = directory.appendingPathComponent("package.bin")
        try Data(repeating: 9, count: 747).write(to: file)
        #expect(try MedicalCatalogUpdateService.fileSize(of: file) == 747)
        #expect(throws: (any Error).self) { try MedicalCatalogUpdateService.fileSize(of: directory.appendingPathComponent("missing")) }
        #expect(throws: (any Error).self) { try MedicalCatalogUpdateService.fileSize(of: directory) }
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
    let installablePointer: String
    let progressPointer: String
    let expiredPointer: String
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
    static let directory = Bundle.module.bundlePath + "/Fixtures/medical/"

    static func url(_ name: String) -> URL { URL(fileURLWithPath: directory + name) }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func expected() throws -> GoMedicalExpected {
        try JSONDecoder().decode(GoMedicalExpected.self, from: data("expected.json"))
    }

    static func date(_ value: String) throws -> Date {
        try #require(MedicalCatalogReleaseProtocol.timestamp(value))
    }

    static func expectation(_ json: Data, servedAs name: String, now: Date? = nil) throws -> MedicalCatalogSignedExpectation {
        let clock = try now ?? expected().nowDate
        return try MedicalCatalogSignedPointerDecoder.expectation(catalogJSON: json, servedAs: name, now: clock,
                                                                  hasher: ReferenceSHA256())
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
