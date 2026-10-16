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
        /// 包裹段如实存取（评审修复：原实现写丢弃/读恒 nil——主密钥在位却恒「无包裹段」，
        /// 与真实钥匙环行为不符：触发补发分支 + 隐藏「包裹段随帧走」的接线缺陷）。
        private var wrappeds: [UUID: Data] = [:]
        private let sub = Data((0..<32).map { UInt8($0 & 0xFF) })
        func masterKey(realmId: UUID) async throws -> Data? { master }
        func storeMasterKey(_ key: Data, realmId: UUID) async throws { master = key }
        func deviceSubKey() async throws -> Data { sub }
        func generateMasterKey() throws -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }
        func storeRecoveryWrapped(_ wrapped: Data, realmId: UUID) async throws { wrappeds[realmId] = wrapped }
        func recoveryWrapped(realmId: UUID) async throws -> Data? { wrappeds[realmId] }
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
            // ⑤F8 照片（asset photo 行 + observation.media_asset_ids 引用 + 文件）
            let assetId = UUID()
            try db.execute(sql: """
                INSERT INTO asset (id, kind, relative_path, file_protection, width, height, size_bytes, created_at)
                VALUES (?, 'photo', ?, 'complete', 100, 100, 5, 10)
                """, arguments: [assetId.uuidString,
                                 "MedicalNotes/sensitive/\(patient.uuidString)/\(assetId.uuidString).jpg"])
            try db.execute(sql: """
                INSERT INTO observation (id, patient_id, kind, occurred_at, created_at, updated_at, media_asset_ids)
                VALUES (?, ?, 'skin', 1700006500, 10, 20, ?)
                """, arguments: [UUID().uuidString, patient.uuidString,
                                 "[\"\(assetId.uuidString)\"]"])
        }
        return (store, patient)
    }

    /// seeded ⑤ 的照片 assetId（DB 反查，测试侧不双写 UUID）
    private func photoAssetId(_ store: GRDBStore) async throws -> UUID {
        let id = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset WHERE kind = 'photo'")
        }
        return try XCTUnwrap(id.flatMap(UUID.init(uuidString:)))
    }

    /// 写 seeded ⑤ 的照片字节（makeSeededStore 后调用）
    private func writePhotoFile(mediaBase: URL, patient: UUID, assetId: UUID) throws {
        let url = mediaBase.appendingPathComponent("sensitive/\(patient.uuidString)/\(assetId.uuidString).jpg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([5, 5, 5]).write(to: url)
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

        let (store, patient) = try await makeSeededStore(mediaBase: mediaBase)
        // ⑤照片字节（asset 行已在 seeded store 内）
        let photoId = try await photoAssetId(store)
        try writePhotoFile(mediaBase: mediaBase, patient: patient, assetId: photoId)
        let service = BackupService(writer: store.writer, keyRing: StubKeyRing(),
                                    mediaBase: mediaBase, stagingRoot: staging)
        let pkg = try await service.createBackup(encrypted: true)

        let carrier = try XCTUnwrap(pkg.mediaCarrier)
        let manifest = try XCTUnwrap(pkg.mediaManifest)
        XCTAssertEqual(manifest.entries.count, 4)   // ④缺失文件跳过；①②③⑤在包
        let photoSHA = CryptoKitContentHasher().sha256Hex(Data([5, 5, 5]))
        let shas = Set(manifest.entries.map(\.sha256))
        XCTAssertEqual(shas, Set([shaA, shaB, CryptoKitContentHasher().sha256Hex(Data(bytesB)), photoSHA]))

        // 清单哈希 = 明文哈希语义（条目相对路径规范形）
        for entry in manifest.entries {
            XCTAssertTrue(MediaDestinationRules.isCanonicalEntry(entry))
        }
        // ⑤照片条目：kind=photo、敏感路由、路径形状（{assetId}.jpg）
        let photoEntry = try XCTUnwrap(manifest.entries.first { $0.kind == .photo })
        XCTAssertTrue(photoEntry.isSensitive)
        XCTAssertNotNil(photoEntry.memberId)
        XCTAssertTrue(photoEntry.relativePath.hasSuffix("\(photoId.uuidString).jpg"))
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

    func test_restoreMediaRoundTripRelinksDocuments() async throws {
        let mediaBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-media-rt-\(UUID().uuidString)", isDirectory: true)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-staging-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaBase, withIntermediateDirectories: true)
        let casURL = mediaBase.appendingPathComponent(MediaDestinationRules.originalRelativePath(sha256: shaA))
        try FileManager.default.createDirectory(at: casURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytesA).write(to: casURL)

        let (source, sourcePatient) = try await makeSeededStore(mediaBase: mediaBase)
        let photoId = try await photoAssetId(source)
        try writePhotoFile(mediaBase: mediaBase, patient: sourcePatient, assetId: photoId)
        let sourceService = BackupService(writer: source.writer, keyRing: StubKeyRing(),
                                          mediaBase: mediaBase, stagingRoot: staging)
        let pkg = try await sourceService.createBackup(encrypted: true)
        let carrier = try XCTUnwrap(pkg.mediaCarrier)

        // 目标设备：空库 + 空媒体根 + 同钥匙环（deviceSubKey 相同 = 可解帧）
        let destination = try GRDBStore.inMemory()
        let restoreBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreBase, withIntermediateDirectories: true)
        let restoreService = BackupService(writer: destination.writer, keyRing: StubKeyRing(),
                                           mediaBase: restoreBase, stagingRoot: staging)

        // 媒体先行（幂等）→ DB 单事务——与 restic「内容→索引→快照」写序同构
        let analysis = try await restoreService.analyzeConflicts(from: pkg.data)
        let masterKey = try XCTUnwrap(analysis.masterKey)
        let mediaReport = try await restoreService.importMediaCarrier(from: carrier, masterKey: masterKey)
        XCTAssertEqual(mediaReport.imported, 4)
        XCTAssertEqual(mediaReport.missing.count, 0)
        let records = try await restoreService.restore(from: pkg.data)
        XCTAssertGreaterThan(records, 0)

        // 重连断言：行列 original_sha256 在、meta 路径相对、字节可达
        let docs = try await destination.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM document_file ORDER BY created_at")
        }
        XCTAssertEqual(docs.count, 4)
        for row in docs {
            let sha = row["original_sha256"] as String?
            XCTAssertNotNil(sha, "恢复行必须携带原件身份")
            let meta = try JSONSerialization.jsonObject(with: Data((row["meta_json"] as String).utf8)) as? [String: Any]
            let path = meta?["original_path"] as? String
            XCTAssertNotNil(path)
            XCTAssertFalse(path?.hasPrefix("/") == true, "恢复后绝不写回绝对路径")
        }
        // 非敏感 CAS 字节可达
        let restoredA = restoreBase.appendingPathComponent(MediaDestinationRules.originalRelativePath(sha256: shaA))
        XCTAssertEqual(try Data(contentsOf: restoredA), Data(bytesA))
        // 敏感件落在敏感成员目录（跨患者去重边界保持；memberId 由行反查）
        let sensitiveRows = docs.filter { ($0["is_sensitive"] as Int?) == 1 }
        XCTAssertEqual(sensitiveRows.count, 1)
        let memberId = sensitiveRows[0]["patient_id"] as String
        let sensitiveFile = restoreBase.appendingPathComponent("sensitive/\(memberId)/\(shaB).bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sensitiveFile.path))
        // 缺失文档（④）：行在、列在、字节缺——「原件缺失」态（报告已如实呈现），不伪造
        let missingSha = String(repeating: "c", count: 64)
        let missingFile = restoreBase.appendingPathComponent(
            MediaDestinationRules.originalRelativePath(sha256: missingSha))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingFile.path))
        // ⑤照片簿记与字节：asset 行在 + 文件落敏感成员目录（blur 派生再生）
        let restoredAsset = try await destination.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE kind = 'photo'")
        }
        XCTAssertNotNil(restoredAsset)
        let restoredPhoto = restoreBase.appendingPathComponent(
            "sensitive/\(sourcePatient.uuidString)/\(photoId.uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPhoto.path))
        XCTAssertEqual(try Data(contentsOf: restoredPhoto), Data([5, 5, 5]))
        // 幂等：再次导入同一载具 → 全 alreadyPresent（字节零改写）
        let again = try await restoreService.importMediaCarrier(from: carrier, masterKey: masterKey)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.alreadyPresent, 4)
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
