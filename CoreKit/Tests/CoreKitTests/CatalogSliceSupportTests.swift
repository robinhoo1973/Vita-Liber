import Domain
import Foundation
import Testing
@testable import Infrastructure

/// 切片信任/回执金样（B0 契约件；纯 Foundation，Linux 真跑）。
@Suite("SU-M2-SLICE · 切片 trust floor（内容身份）")
struct CatalogSliceTrustTests {

    // MARK: - fixtures

    private func digest(_ char: Character) -> String { String(repeating: char, count: 64) }

    private func candidate(_ kind: CatalogSliceKind, catalogVersion: Int64,
                           sqlite: Character = "a", rootVersion: Int64 = 1,
                           payloadDigest: Character = "d") -> VerifiedCatalogSliceCandidate {
        VerifiedCatalogSliceCandidate(
            kind: kind, rootVersion: rootVersion, catalogVersion: catalogVersion,
            assetName: kind.packageAssetName, sqliteEntryName: kind.sqliteEntryName,
            sqliteSHA256: digest(sqlite), sqliteSize: 2_000,
            contentSHA256: digest(sqlite),
            packageSHA256: digest("b"), packageSize: 1_000,
            regionScope: ["CN"],
            tables: (CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: 1) ?? []).sorted(),
            counts: Dictionary(uniqueKeysWithValues:
                (CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: 1) ?? [])
                    .sorted().map { ($0, 100) }),
            minAppMarketingVersion: "0.0.1", minAppBuild: 1,
            createdAt: Date(), note: nil,
            signedPayloadDigest: digest(payloadDigest))
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice-trust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)   // try?-ok: 测试夹具
        return url
    }

    // MARK: - tests

    @Test("每片独立文件：不同片同版不同内容不互相 equivocation")
    func perKindIsolation() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理
        let trust = CatalogSliceTrust(directory: directory)
        try trust.accept(candidate(.drug, catalogVersion: 2, sqlite: "a"))
        try trust.accept(candidate(.facility, catalogVersion: 2, sqlite: "c"))
        try trust.accept(candidate(.reference, catalogVersion: 2, sqlite: "e"))
        #expect(trust.observedFloor(.drug)?.catalogVersion == 2)
        #expect(trust.observedFloor(.facility)?.payloadDigest == digest("c"))
        #expect(trust.observedFloor(.reference)?.payloadDigest == digest("e"))
        // 每片一文件、v4 文件不存在
        for kind in CatalogSliceKind.allCases {
            #expect(FileManager.default.fileExists(
                atPath: CatalogSliceTrust.fileURL(kind: kind, directory: directory).path))
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("medical-catalog-trust.json").path))
    }

    @Test("重签幂等：同版同 sqlite 同 payload 摘要变化不触发 equivocation")
    func reSignIsIdempotent() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理
        let trust = CatalogSliceTrust(directory: directory)
        try trust.accept(candidate(.drug, catalogVersion: 2, sqlite: "a", payloadDigest: "d"))
        // f7 重签 minApp*/rootVersion：sqlite 不变、payload 摘要变 → no-op
        try trust.accept(candidate(.drug, catalogVersion: 2, sqlite: "a", payloadDigest: "f"))
        #expect(trust.observedFloor(.drug)?.payloadDigest == digest("a"))
    }

    @Test("同版异 sqlite = equivocation；低版本 = rollback")
    func equivocationAndRollback() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理
        let trust = CatalogSliceTrust(directory: directory)
        try trust.accept(candidate(.drug, catalogVersion: 3, sqlite: "a"))
        #expect(throws: MedicalCatalogTrustStore.Failure.equivocation) {
            try trust.accept(candidate(.drug, catalogVersion: 3, sqlite: "b"))
        }
        #expect(throws: MedicalCatalogTrustStore.Failure.rollback) {
            try trust.accept(candidate(.drug, catalogVersion: 2, sqlite: "a"))
        }
        // 失败不改变已持久化 floor
        #expect(trust.observedFloor(.drug)?.catalogVersion == 3)
        #expect(trust.observedFloor(.drug)?.payloadDigest == digest("a"))
    }

    @Test("落盘后可重开恢复（跨实例）")
    func persistsAcrossInstances() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理
        try CatalogSliceTrust(directory: directory).accept(candidate(.facility, catalogVersion: 4, sqlite: "c"))
        let reopened = CatalogSliceTrust(directory: directory)
        #expect(reopened.observedFloor(.facility)?.catalogVersion == 4)
    }
}

@Suite("SU-M2-SLICE · 安装回执")
struct CatalogSliceReceiptTests {

    private func digest(_ char: Character) -> String { String(repeating: char, count: 64) }

    private func candidate(_ kind: CatalogSliceKind) -> VerifiedCatalogSliceCandidate {
        VerifiedCatalogSliceCandidate(
            kind: kind, rootVersion: 1, catalogVersion: 5,
            assetName: kind.packageAssetName, sqliteEntryName: kind.sqliteEntryName,
            sqliteSHA256: digest("a"), sqliteSize: 2_000,
            contentSHA256: digest("a"),
            packageSHA256: digest("b"), packageSize: 1_000,
            regionScope: ["CN"],
            tables: (CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: 1) ?? []).sorted(),
            counts: Dictionary(uniqueKeysWithValues:
                (CatalogSliceManifestDecoder.expectedTables(kind, schemaVersion: 1) ?? [])
                    .sorted().map { ($0, 100) }),
            minAppMarketingVersion: "0.0.1", minAppBuild: 1,
            createdAt: Date(), note: nil,
            signedPayloadDigest: digest("d"))
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice-receipt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)   // try?-ok: 测试夹具
        return url
    }

    @Test("写读回环：字段全落位")
    func roundTrip() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理
        let receipt = CatalogSliceReceipt(candidate: candidate(.drug), installedAt: Date())
        #expect(CatalogSliceReceipt.write(receipt, directory: directory))
        let read = CatalogSliceReceipt.read(kind: .drug, directory: directory)
        #expect(read?.catalogVersion == 5)
        #expect(read?.rootVersion == 1)
        #expect(read?.sqliteSHA256 == digest("a"))
        #expect(read?.signedPayloadDigest == digest("d"))
        #expect(read?.installedAt == receipt.installedAt)
    }

    @Test("kind 不符 / 损坏 / 缺失均按无回执")
    func strictReadSide() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }   // try?-ok: 测试清理
        #expect(CatalogSliceReceipt.read(kind: .drug, directory: directory) == nil)
        #expect(CatalogSliceReceipt.write(CatalogSliceReceipt(candidate: candidate(.drug),
                                                              installedAt: Date()), directory: directory))
        #expect(CatalogSliceReceipt.read(kind: .facility, directory: directory) == nil)
        // 损坏字节
        let url = CatalogSliceReceipt.productionURL(kind: .drug, directory: directory)
        try Data("not json".utf8).write(to: url)
        #expect(CatalogSliceReceipt.read(kind: .drug, directory: directory) == nil)
    }

    @Test("写失败返回 false 不抛出（回执是派生数据）")
    func writeFailureIsNonThrowing() {
        // 目标目录不可创建：把父路径占为普通文件
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice-receipt-block-\(UUID().uuidString)")
        try? Data("x".utf8).write(to: blocker)   // try?-ok: 测试夹具
        defer { try? FileManager.default.removeItem(at: blocker) }   // try?-ok: 测试清理
        let receipt = CatalogSliceReceipt(candidate: candidate(.reference), installedAt: Date())
        #expect(CatalogSliceReceipt.write(receipt, directory: blocker) == false)
    }
}
