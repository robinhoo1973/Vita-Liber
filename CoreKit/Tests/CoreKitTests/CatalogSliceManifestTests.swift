import Domain
import Foundation
import Protocols
import Testing
@testable import Infrastructure

/// 切片清单解码与验签入口金样（B0 契约件，2026-10-28 切片-only 批次）。
/// 纯 Foundation + 注入式哈希/签名桩——Linux 真跑；密码学全链路在 macOS 验收套件。
@Suite("SU-M2-SLICE · 清单解码与验签入口")
struct CatalogSliceManifestTests {

    private let hasher = StubHasher()

    // MARK: - fixtures

    /// 确定性 FNV 展开哈希（形态同 sha256Hex：64 位小写十六进制；非密码学，仅桩）。
    private struct StubHasher: ContentHashing {
        func sha256Hex(_ data: Data) -> String {
            var acc: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in data { acc = (acc ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            var out = ""
            for index in 0..<32 {
                acc = acc &* 0x0000_0100_0000_01b3 &+ UInt64(index)
                out += String(format: "%02x", UInt8(truncatingIfNeeded: acc >> 56))
            }
            return out
        }
    }

    private func digest(_ char: Character) -> String { String(repeating: char, count: 64) }

    /// 实网 21 键形 + 二轮质询增设的 rootVersion（22 键）。
    private func payload(_ kind: CatalogSliceKind,
                         _ mutate: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        let sha = digest("a")
        var doc: [String: Any] = [
            "app": "vitaliber",
            "assetKind": "app-catalog-slice",
            "assetName": kind.packageAssetName,
            "catalogVersion": 2,
            "containerFormat": "zip+aes256gcm-v1",
            "contentSha256": sha,
            "counts": Dictionary(uniqueKeysWithValues:
                (CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: 1) ?? [])
                    .sorted().map { ($0, 100) }),
            "createdAt": "2026-10-27T23:16:56+00:00",
            "format": "vita-liber-app-slice-manifest/v1",
            "installable": true,
            "minAppBuild": 1,
            "minAppMarketingVersion": "0.0.1",
            "note": "test",
            "packageSha256": digest("b"),
            "packageSize": 1_000,
            "regionScope": ["CN"],
            "rootVersion": 1,
            "schemaVersion": 1,
            "sqliteEntryName": kind.sqliteEntryName,
            "sqliteSha256": sha,
            "sqliteSize": 2_000,
            "tables": (CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: 1) ?? []).sorted(),
        ]
        mutate(&doc)
        return doc
    }

    private func envelope(_ payload: [String: Any], keyIDs: [String] = ["c0", "c1"]) throws -> Data {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let signature = Data(repeating: 0x11, count: 64).base64EncodedString()
        let doc: [String: Any] = [
            "payload": payloadData.base64EncodedString(),
            "signatures": keyIDs.map { ["keyId": $0, "signature": signature] },
        ]
        return try JSONSerialization.data(withJSONObject: doc)
    }

    private func candidate(_ kind: CatalogSliceKind, servedAs: String? = nil,
                           _ mutate: (inout [String: Any]) -> Void = { _ in }) throws
        -> VerifiedCatalogSliceCandidate {
        try CatalogSliceManifestDecoder.candidate(
            manifestJSON: try envelope(payload(kind, mutate)), kind: kind,
            servedAs: servedAs ?? kind.manifestAssetName, hasher: hasher)
    }

    /// pinned root（4 钥、双 2-of-2、动态到期）+ 切片签名 keyID 集。
    private func trustRoot(now: Date, version: Int64 = 1) throws
        -> (json: Data, catalogKeyIDs: [String], rootKeyIDs: [String]) {
        let rootPairs = [Data(repeating: 0x21, count: 32), Data(repeating: 0x22, count: 32)]
        let catalogPairs = [Data(repeating: 0x31, count: 32), Data(repeating: 0x32, count: 32)]
        let rootIDs = rootPairs.map { hasher.sha256Hex($0) }
        let catalogIDs = catalogPairs.map { hasher.sha256Hex($0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let expires = formatter.string(from: now.addingTimeInterval(365 * 24 * 3600))
        let rootDoc: [String: Any] = [
            "schemaVersion": 1, "role": "root", "app": "vitaliber", "assetKind": "medical-data",
            "version": version, "expiresAt": expires,
            "keys": (rootPairs + catalogPairs).map { ["id": hasher.sha256Hex($0), "publicKey": $0.base64EncodedString()] },
            "rootKeyIDs": rootIDs, "rootThreshold": 2,
            "catalogKeyIDs": catalogIDs, "catalogThreshold": 2,
            "assetBaseURL": MedicalCatalogReleaseProtocol.releaseBaseURL,
            "allowedHosts": ["cnb.cool", "asset.cnb.cool"],
        ]
        return (try envelope(rootDoc, keyIDs: rootIDs), catalogIDs, rootIDs)
    }

    // MARK: - decode

    @Test("实网 22 键形解出并逐字段落位")
    func liveShapedDrugAccepted() throws {
        let decoded = try candidate(.drug)
        #expect(CatalogSliceManifestDecoder.payloadKeys.count == 22)
        #expect(decoded.kind == .drug)
        #expect(decoded.rootVersion == 1)
        #expect(decoded.assetName == "app-catalog-drug.bin")
        #expect(decoded.sqliteEntryName == "app-catalog-drug.sqlite")
        #expect(decoded.catalogVersion == 2)
        #expect(decoded.tables.sorted() == ["drug", "drug_detail", "drug_reference"])
        #expect(decoded.counts["drug_reference"] == 100)
        #expect(decoded.regionScope == ["CN"])
        #expect(decoded.minAppBuild == 1)
        #expect(decoded.signedPayloadDigest.count == 64)
    }

    @Test("facility/reference 表集精确冻结；未知内容 schema 无表集")
    func perKindTableSets() throws {
        #expect(try candidate(.facility).tables.sorted() == ["department", "hospital"])
        #expect(try candidate(.reference).tables.sorted() == ["diagnosis", "exam_item"])
        #expect(CatalogSliceManifestDecoder.expectedTables(.drug, schemaVersion: 1)
                == ["drug", "drug_detail", "drug_reference"])
        #expect(CatalogSliceManifestDecoder.expectedTables(.drug, schemaVersion: 2) == nil)
        #expect(CatalogSliceManifestDecoder.installedTableSet(.facility, schemaVersion: 1)
                == ["department", "hospital", "slice_meta"])
    }

    @Test("未知键与缺键一律拒；note 是唯一可缺省键")
    func strictKeySet() throws {
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["issuedAt"] = "2026-10-27T23:16:56+00:00" }
        }
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0.removeValue(forKey: "sqliteEntryName") }
        }
        _ = try candidate(.drug) { $0.removeValue(forKey: "note") }
    }

    @Test("served 名/载荷包名/成员名与 kind 三者绑定")
    func nameBinding() throws {
        #expect(throws: CatalogSliceManifestError.assetNameMismatch) {
            _ = try candidate(.drug, servedAs: "manifest.json")
        }
        #expect(throws: CatalogSliceManifestError.assetNameMismatch) {
            _ = try candidate(.drug) { $0["assetName"] = "app-catalog-facility.bin" }
        }
        #expect(throws: CatalogSliceManifestError.assetNameMismatch) {
            _ = try candidate(.drug) { $0["sqliteEntryName"] = "app-catalog-drug.bin" }
        }
    }

    @Test("schemaVersion/containerFormat/installable/scope 门")
    func versionGates() throws {
        #expect(throws: CatalogSliceManifestError.unsupportedSliceSchemaVersion) {
            _ = try candidate(.drug) { $0["schemaVersion"] = 2 }
        }
        #expect(throws: CatalogSliceManifestError.unsupportedContainerFormat) {
            _ = try candidate(.drug) { $0["containerFormat"] = "zip" }
        }
        #expect(throws: CatalogSliceManifestError.notInstallable) {
            _ = try candidate(.drug) { $0["installable"] = false }
        }
        #expect(throws: CatalogSliceManifestError.invalidScope) {
            _ = try candidate(.drug) { $0["assetKind"] = "medical-data" }
        }
    }

    @Test("双 SHA 形态与 content==sqlite 互核")
    func digestRules() throws {
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["contentSha256"] = String(repeating: "c", count: 64) }
        }
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["packageSha256"] = String(repeating: "C", count: 64) }
        }
    }

    @Test("表集/计数键/正值三向一致")
    func tableCountConsistency() throws {
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["tables"] = ["drug", "drug_detail", "drug_reference", "drug_package"] }
        }
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["counts"] = ["drug": 1, "drug_detail": 1] }
        }
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.facility) { $0["counts"] = ["department": 0, "hospital": 1] }
        }
    }

    @Test("createdAt 接受 RFC3339 两种零时区写法；垃圾拒")
    func createdAtForms() throws {
        _ = try candidate(.drug) { $0["createdAt"] = "2026-10-27T23:16:56Z" }
        _ = try candidate(.drug) { $0["createdAt"] = "2026-10-27T23:16:56+00:00" }
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["createdAt"] = "2026/10/27 23:16" }
        }
    }

    @Test("v4 指针载荷混入即拒（无兼容路径）")
    func legacyPointerRejected() throws {
        let legacy: [String: Any] = ["schemaVersion": 3, "role": "catalog", "app": "vitaliber",
                                     "assetKind": "medical-data", "catalogVersion": 2]
        let json = try envelope(legacy)
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try CatalogSliceManifestDecoder.candidate(
                manifestJSON: json, kind: .drug, servedAs: "app-catalog-drug.json", hasher: hasher)
        }
    }

    @Test("minApp 门 build 单调")
    func minAppGate() throws {
        let strict = try candidate(.drug) { $0["minAppBuild"] = 191 }
        #expect(!strict.isSupported(byAppBuild: 190))
        let ok = try candidate(.drug) { $0["minAppBuild"] = 186 }
        #expect(ok.isSupported(byAppBuild: 186))
        #expect(ok.isSupported(byAppBuild: 190))
    }

    @Test("rootVersion：缺/0 拒；超 pinned root 版本拒；低于 pinned 接受（轮换窗口）")
    func rootVersionBounds() throws {
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0.removeValue(forKey: "rootVersion") }
        }
        #expect(throws: CatalogSliceManifestError.invalidField) {
            _ = try candidate(.drug) { $0["rootVersion"] = 0 }
        }
        let now = Date()
        let pinned = try trustRoot(now: now, version: 1)
        #expect(throws: CatalogSliceManifestError.rootVersionOutOfRange) {
            _ = try MedicalCatalogTrustEvaluator(hasher: hasher, isValidSignature: { _, _, _ in true })
                .verifySlice(pinnedRootJSON: pinned.json,
                             manifestJSON: try envelope(payload(.drug) { $0["rootVersion"] = 2 },
                                                        keyIDs: pinned.catalogKeyIDs),
                             kind: .drug, servedAs: CatalogSliceKind.drug.manifestAssetName,
                             hasher: hasher, now: now)
        }
        let newerRoot = try trustRoot(now: now, version: 2)
        let accepted = try MedicalCatalogTrustEvaluator(hasher: hasher, isValidSignature: { _, _, _ in true })
            .verifySlice(pinnedRootJSON: newerRoot.json,
                         manifestJSON: try envelope(payload(.drug), keyIDs: newerRoot.catalogKeyIDs),
                         kind: .drug, servedAs: CatalogSliceKind.drug.manifestAssetName,
                         hasher: hasher, now: now)
        #expect(accepted.rootVersion == 1)
    }

    // MARK: - verifySlice

    @Test("verifySlice：2-of-2 通过；错签全拒；根 keyId 不计数")
    func verifySliceTrust() throws {
        let now = Date()
        let root = try trustRoot(now: now)
        let good = try MedicalCatalogTrustEvaluator(hasher: hasher, isValidSignature: { _, _, _ in true })
            .verifySlice(pinnedRootJSON: root.json,
                         manifestJSON: try envelope(payload(.drug), keyIDs: root.catalogKeyIDs),
                         kind: .drug, servedAs: CatalogSliceKind.drug.manifestAssetName,
                         hasher: hasher, now: now)
        #expect(good.kind == .drug)

        let rejecting = MedicalCatalogTrustEvaluator(hasher: hasher, isValidSignature: { _, _, _ in false })
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            _ = try rejecting.verifySlice(pinnedRootJSON: root.json,
                                          manifestJSON: try envelope(payload(.drug), keyIDs: root.catalogKeyIDs),
                                          kind: .drug, servedAs: CatalogSliceKind.drug.manifestAssetName,
                                          hasher: hasher, now: now)
        }
        // 根钥签切片清单：allowed=catalogKeyIDs，计数 0 → 阈值拒
        #expect(throws: MedicalCatalogTrustError.signatureThreshold) {
            _ = try MedicalCatalogTrustEvaluator(hasher: hasher, isValidSignature: { _, _, _ in true })
                .verifySlice(pinnedRootJSON: root.json,
                             manifestJSON: try envelope(payload(.drug), keyIDs: root.rootKeyIDs),
                             kind: .drug, servedAs: CatalogSliceKind.drug.manifestAssetName,
                             hasher: hasher, now: now)
        }
    }
}
