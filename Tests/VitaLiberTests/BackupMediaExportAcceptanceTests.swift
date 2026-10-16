import XCTest
import Foundation
import GRDB
import ZIPFoundation
import Domain
import Infrastructure
import Protocols

/// 备份媒体随包（local-storage-layout-council §8 切片 11，macOS CI）：
/// 加密备份产出 .vlbm 载具（清单=明文哈希、blob 密文）；列在直接用 /
/// NULL 行现场哈希 / 文件缺失跳过 / 敏感条目敏感路由。
@MainActor
final class BackupMediaExportAcceptanceTests: XCTestCase {

    private let shaA = String(repeating: "a", count: 64)
    private let shaB = String(repeating: "b", count: 64)
    private let bytesA: [UInt8] = [1, 2, 3, 4]
    private let bytesB: [UInt8] = [9, 8, 7, 6]

    /// 内存密钥环桩（DeviceKeyRing 契约：密钥材料 Data，无平台依赖）。
    private final class StubKeyRing: DeviceKeyRing, @unchecked Sendable {
        private var master: Data?
        private let sub = Data((0..<32).map { UInt8($0 & 0xFF) })
        func masterKey(realmId: UUID) async throws -> Data? { master }
        func storeMasterKey(_ key: Data, realmId: UUID) async throws { master = key }
        func deviceSubKey() async throws -> Data { sub }
        func generateMasterKey() throws -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }
        func storeRecoveryWrapped(_ wrapped: Data, realmId: UUID) async throws {}
        func recoveryWrapped(realmId: UUID) async throws -> Data? { nil }
    }

    private func makeSeededStore(mediaBase: URL) async throws -> (store: GRDBStore, patient: UUID) {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        let owner = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 10, 20)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                VALUES (?, 'Owner', ?, 10)
                """, arguments: [owner.uuidString, patient.uuidString])
            // ①列在 + 文件在 CAS 位（单点转换纪律：不重复哈希）
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, meta_json, created_at, updated_at, original_sha256)
                VALUES (?, ?, '检验报告', 'active', ?, 'image/png', 0, 'camera', ?, 10, 20, ?)
                """, arguments: [UUID().uuidString, patient.uuidString, "sha:\(shaA)",
                                 "{\"original_path\":\"originals/aa/\(shaA).bin\"}",
                                 shaA])
            // ②列 NULL + legacy 绝对路径 + 文件在旧布局（现场哈希一次）
            let legacyURL = mediaBase.appendingPathComponent("originals/\(patient.uuidString)/legacy.png")
            try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(bytesB).write(to: legacyURL)
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, meta_json, created_at, updated_at)
                VALUES (?, ?, '检验报告', 'active', ?, 'image/png', 0, 'camera', ?, 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString, "file:legacy",
                                 "{\"original_path\":\"\(legacyURL.path)\"}"])
            // ③敏感列在 + 文件在敏感目录（敏感路由：sensitive/{memberId}/{sha}.bin）
            let sensitiveURL = mediaBase.appendingPathComponent("sensitive/\(patient.uuidString)/\(shaB).bin")
            try FileManager.default.createDirectory(at: sensitiveURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data([5, 5, 5]).write(to: sensitiveURL)
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, meta_json, created_at, updated_at, original_sha256)
                VALUES (?, ?, '检验报告', 'active', ?, 'image/png', 1, 'camera', ?, 10, 20, ?)
                """, arguments: [UUID().uuidString, patient.uuidString, "sha:\(shaB)",
                                 "{\"original_path\":\"sensitive/\(patient.uuidString)/\(shaB).bin\"}",
                                 shaB])
            // ④列在但文件缺失（绝不打包不存在字节；恢复报告 missing 如实呈现）
            let missingSha = String(repeating: "c", count: 64)
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, meta_json, created_at, updated_at, original_sha256)
                VALUES (?, ?, '检验报告', 'active', ?, 'image/png', 0, 'camera', ?, 10, 20, ?)
                """, arguments: [UUID().uuidString, patient.uuidString, "sha:\(missingSha)",
                                 "{\"original_path\":\"originals/cc/\(missingSha).bin\"}",
                                 missingSha])
        }
        return (store, patient)
    }

    func test_encryptedBackupProducesSealedCarrier() async throws {
        let mediaBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-media-\(UUID().uuidString)", isDirectory: true)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaBase, withIntermediateDirectories: true)
        // ①列在 CAS 位
        let casURL = mediaBase.appendingPathComponent(MediaDestinationRules.originalRelativePath(sha256: shaA))
        try FileManager.default.createDirectory(at: casURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytesA).write(to: casURL)

        let (store, _) = try await makeSeededStore(mediaBase: mediaBase)
        let service = BackupService(writer: store.writer, keyRing: StubKeyRing(),
                                    mediaBase: mediaBase, stagingRoot: staging)
        let pkg = try await service.createBackup(encrypted: true)

        let carrier = try XCTUnwrap(pkg.mediaCarrier)
        let manifest = try XCTUnwrap(pkg.mediaManifest)
        XCTAssertEqual(manifest.entries.count, 3)   // ④缺失文件跳过；①②③在包
        let shas = Set(manifest.entries.map(\.sha256))
        XCTAssertEqual(shas, Set([shaA, shaB, CryptoKitContentHasher().sha256Hex(Data(bytesB))]))

        // 清单哈希 = 明文哈希语义（条目相对路径规范形）
        for entry in manifest.entries {
            XCTAssertTrue(MediaDestinationRules.isCanonicalEntry(entry))
        }
        // 敏感条目路由到 sensitive/{memberId}/（跨患者去重边界）
        let sensitiveEntry = try XCTUnwrap(manifest.entries.first { $0.sha256 == shaB })
        XCTAssertTrue(sensitiveEntry.isSensitive)
        XCTAssertNotNil(sensitiveEntry.memberId)
        XCTAssertTrue(sensitiveEntry.relativePath.hasPrefix("sensitive/"))

        // 载具 zip：manifest.json + media/{sha2}/{sha}.bin；blob 密文 ≠ 明文
        let archive = try XCTUnwrap(Archive(url: carrier, accessMode: .read))
        XCTAssertNotNil(archive[MediaCarrierPackager.manifestFileName])
        let blob = try archive.extract(archive[MediaDestinationRules.carrierRelativePath(sha256: shaA)]!)
        XCTAssertNotEqual(blob, Data(bytesA))   // 载具内只存密文
    }

    func test_plaintextBackupCarriesNoCarrier() async throws {
        let mediaBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-media-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaBase, withIntermediateDirectories: true)
        let (store, _) = try await makeSeededStore(mediaBase: mediaBase)
        let service = BackupService(writer: store.writer, keyRing: StubKeyRing(),
                                    mediaBase: mediaBase,
                                    stagingRoot: FileManager.default.temporaryDirectory)
        let pkg = try await service.createBackup(encrypted: false)
        XCTAssertNil(pkg.mediaCarrier)   // 明文过渡模式：不承诺媒体字节（信封仍带元数据）
        XCTAssertNil(pkg.mediaManifest)
    }
}
