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
        // 闭包内属性引用纪律:shaA/shaB/bytesB 为类属性,write 逃逸闭包内需 self——
        // 局部快照既免 self 又保持只读语义
        let shaA = self.shaA
        let shaB = self.shaB
        let bytesB = self.bytesB
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
            // ⑤b blur 派生行（与 SensitiveAssetStore.savePhoto 同形：id「{uuid}.blur」非 UUID，
            // parent_id 回指原图行）。回归病历：旧导出对 asset.id 走 requiredUUID 必抛
            // corruptIdentity——凡存过照片的库导出/同步全断；本行保证该路径永久在测。
            try db.execute(sql: """
                INSERT INTO asset (id, kind, relative_path, file_protection, size_bytes, parent_id, created_at)
                VALUES (?, 'blur', ?, 'complete', 5, ?, 11)
                """, arguments: ["\(assetId.uuidString).blur",
                                 "MedicalNotes/sensitive/\(patient.uuidString)/\(assetId.uuidString).blur.jpg",
                                 assetId.uuidString])
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
        let blobURL = carrier.deletingLastPathComponent().appendingPathComponent("blob-\(UUID().uuidString).bin")
        _ = try archive.extract(archive[MediaDestinationRules.carrierRelativePath(sha256: shaA)]!, to: blobURL)
        let blob = try Data(contentsOf: blobURL)
        try? FileManager.default.removeItem(at: blobURL)   // try?-ok: 暂存清理失败由系统回收
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
        // ⑤b blur 行字符串保真往返（id「{uuid}.blur」；parent_id 回指原图）
        let restoredBlur = try await destination.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE kind = 'blur'")
        }
        XCTAssertEqual(restoredBlur?["id"] as String?, "\(photoId.uuidString).blur")
        XCTAssertEqual(restoredBlur?["parent_id"] as String?, photoId.uuidString)
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

    /// 回归（评审 idx38/50/58，coexist 成员重映射族）：ADR-019 coexist 下成员行重映射新 id——
    /// envelope 全部行的 patient 随映射改写（文档 meta 已改写为 sensitive/{newMember}/、照片按行
    /// 成员拼读路径），但媒体载具导入先于 DB 事务、只知**源**成员路径。修复前：敏感字节滞留
    /// sensitive/{source}/——文档读不可达（敏感件 resolver 禁 sha 回落），且对账引用集按行成员
    /// 判定 → 源目录文件无引用、600s 宽限后整删＝原件永久丢失（BR-002）。
    /// 本用例钉住：恢复后敏感字节必须归位到重映射成员目录（文档与照片两族）。
    func test_coexistRestoreRefilesSensitiveMediaToRemappedMember() async throws {
        let mediaBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-media-coexist-\(UUID().uuidString)", isDirectory: true)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-staging-coexist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaBase, withIntermediateDirectories: true)

        let (source, sourcePatient) = try await makeSeededStore(mediaBase: mediaBase)
        let photoId = try await photoAssetId(source)
        try writePhotoFile(mediaBase: mediaBase, patient: sourcePatient, assetId: photoId)
        let sourceService = BackupService(writer: source.writer, keyRing: StubKeyRing(),
                                          mediaBase: mediaBase, stagingRoot: staging)
        let pkg = try await sourceService.createBackup(encrypted: true)
        let carrier = try XCTUnwrap(pkg.mediaCarrier)

        // 目标：独立媒体根 + 空库；预置同 id 成员行制造成员冲突；载具按源成员路径导入
        let destMediaBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-media-coexist-dest-\(UUID().uuidString)", isDirectory: true)
        let dest = try GRDBStore.inMemory()
        try await dest.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 10, 20)
                """, arguments: [sourcePatient.uuidString])
        }
        let destService = BackupService(writer: dest.writer, keyRing: StubKeyRing(),
                                        mediaBase: destMediaBase, stagingRoot: staging)
        let analysis = try await destService.analyzeConflicts(from: pkg.data)
        XCTAssertTrue(analysis.conflicts.contains { $0.id == sourcePatient },
                      "同 id 成员行必须构成 ADR-019 冲突（coexist 前置）")
        let masterKey = try XCTUnwrap(analysis.masterKey)
        let imported = try await destService.importMediaCarrier(from: carrier, masterKey: masterKey)
        XCTAssertEqual(imported.imported, 4)
        let sourceSensitive = destMediaBase.appendingPathComponent("sensitive/\(sourcePatient.uuidString)/\(shaB).bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceSensitive.path),
                      "导入口先行：字节此刻仍在源成员目录（refile 的修复对象）")

        var resolutions: [UUID: ExportService.ConflictResolution] = [:]
        for conflict in analysis.conflicts where conflict.id != sourcePatient {
            resolutions[conflict.id] = .keep
        }
        resolutions[sourcePatient] = .coexist
        try await destService.restore(envelope: analysis.envelope, resolutions: resolutions)

        let newMemberRaw = try await dest.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM patient_profile WHERE id != ?",
                                arguments: [sourcePatient.uuidString])
        }
        let target = try XCTUnwrap(newMemberRaw)

        // 敏感文档：meta 相对路径 = 事实落点（成员段已重映射），经 resolver 首候选字节可达
        let docRow = try await dest.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM document_file WHERE is_sensitive = 1")
        }
        let doc = try XCTUnwrap(docRow)
        let meta = try JSONSerialization.jsonObject(with: Data((doc["meta_json"] as String).utf8)) as? [String: Any]
        let storedPath = try XCTUnwrap(meta?["original_path"] as? String)
        XCTAssertEqual(storedPath, "sensitive/\(target)/\(shaB).bin")
        let candidate = try XCTUnwrap(MediaPathResolver.candidates(
            storedPath: storedPath, originalSha256: doc["original_sha256"] as String?).first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destMediaBase.appendingPathComponent(candidate).path),
            "敏感原件必须在 meta 指向的位置真实存在（修复前滞留源成员目录=读不可达+GC 整删）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceSensitive.path),
                      "归位按拷贝语义：源侧副本暂留（拷贝-提交窗口内崩溃时源字节仍可挽救）；文档类源副本由 MediaReconciler 按孤儿清理（照片类副本无回收路径=已登记残留，见 BackupService.refileSensitiveMedia 注释）")

        // 照片：读取按行成员拼目录——字节必须归位到重映射成员目录
        let obsPatient = try await dest.writer.read { db in
            try String.fetchOne(db, sql: "SELECT patient_id FROM observation LIMIT 1")
        }
        XCTAssertEqual(obsPatient, target)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destMediaBase.appendingPathComponent("sensitive/\(target)/\(photoId.uuidString).jpg").path))
    }
}
