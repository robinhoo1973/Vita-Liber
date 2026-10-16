import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols

// binds: 备份批次 1 验收（discussions/2026-10-16-backup-sync-share-design.md V1.7 切片 8，macOS CI）
// - 整包核心表往返金样（10 表）
// - 拓扑序负向：提醒来源缺失 → source_* 置 NULL 且计入恢复（FR13.5 一票否决面）
// - G1 清偿：遗留 JSON 信封（formatVersion==1）恢复分支
@MainActor
final class BackupBatch1AcceptanceTests: XCTestCase {

    private func makeSeededStore() async throws -> (store: GRDBStore, patient: UUID, encounterID: UUID, reminderID: UUID) {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        let ownerId = UUID()
        let encounterID = UUID()
        let reminderID = UUID()
        try await store.writer.write { db in
            // 生产不变量：本人 profile 必带 owner_local_id——但 owner_local_id 外键
            // 指 local_owner 且 local_owner.self_patient_id 回指 profile,互环 FK 须
            // 三段式（ADR-015/恢复侧同款）：profile 先落 owner_local_id=NULL →
            // owner 落 → 回填 owner_local_id。直插带值必 FOREIGN KEY constraint
            // failed（CI #38980917489 实证）。
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 10, 20)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                VALUES (?, 'Owner', ?, 10)
                """, arguments: [ownerId.uuidString, patient.uuidString])
            try db.execute(sql: """
                UPDATE patient_profile SET owner_local_id = ? WHERE id = ?
                """, arguments: [ownerId.uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor, created_at, updated_at)
                VALUES (?, ?, 1700006400, 'outpatient', 'Fixture Hospital', 'Cardio', 'Dr. Fixture', 10, 20)
                """, arguments: [encounterID.uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO reminder (id, patient_id, kind, title, at_date, status, source, created_at, updated_at, source_table, source_id)
                VALUES (?, ?, 'followUp', '复诊', 1701000000, 'active', 'manual', 10, 20, 'encounter', ?)
                """, arguments: [reminderID.uuidString, patient.uuidString, encounterID.uuidString])
            try db.execute(sql: """
                INSERT INTO observation (id, patient_id, kind, occurred_at, created_at, updated_at)
                VALUES (?, ?, 'skin', 1700006500, 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO allergy_event (id, patient_id, substance, reaction_tags, severity, occurred_at, created_at, updated_at)
                VALUES (?, ?, '青霉素', '[]', 'mild', 1699999900, 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO immunization (id, patient_id, vaccine_name, administered_at, provider, created_at, updated_at)
                VALUES (?, ?, '流感', 1699999999, 'Fixture Clinic', 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO appointment (id, patient_id, hospital, starts_at, status, purpose, created_at, updated_at)
                VALUES (?, ?, 'Fixture Hospital', 1701200000, 'scheduled', 'followUp', 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO voice_note (id, patient_id, body, occurred_at, created_at, updated_at)
                VALUES (?, ?, 'fixture voice', 1700006500, 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO health_problem (id, patient_id, name, kind, created_at, updated_at)
                VALUES (?, ?, 'fixture problem', 'chronic', 10, 20)
                """, arguments: [UUID().uuidString, patient.uuidString])
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded, measured_at, created_at)
                VALUES (?, ?, 'heartRate', 72.5, 'bpm', 'device', 1, 0, 1700006500, 1700006501)
                """, arguments: [UUID().uuidString, patient.uuidString])
        }
        return (store, patient, encounterID, reminderID)
    }

    private static let roundTripTables = [
        "patient_profile", "local_owner", "encounter", "reminder", "observation",
        "allergy_event", "immunization", "appointment", "voice_note", "health_problem", "metric_sample",
    ]

    private func rows(_ store: GRDBStore, _ table: String) async throws -> [Row] {
        try await store.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id") }
    }

    func test_wholeEnvelopeRoundTripsAcrossCoreTables() async throws {
        let (source, _, _, _) = try await makeSeededStore()
        let package = try await BackupService(writer: source.writer).createBackup()
        XCTAssertTrue(package.data.starts(with: Data("VLBU1".utf8)))

        let destination = try GRDBStore.inMemory()
        let records = try await BackupService(writer: destination.writer).restore(from: package.data)
        XCTAssertGreaterThan(records, 0)

        for table in Self.roundTripTables {
            let before = try await rows(source, table)
            let after = try await rows(destination, table)
            XCTAssertEqual(after.count, before.count, "\(table) 行数不齐")
            // 逐列比对（Row 列序稳定——SELECT * 按 DDL 序）
            for (lhs, rhs) in zip(before, after) {
                XCTAssertEqual(lhs, rhs, "\(table) 行内容漂移")
            }
        }
    }

    func test_danglingReminderSourceFallsBackToNull() async throws {
        let (source, _, _, reminderID) = try await makeSeededStore()
        let package = try await BackupService(writer: source.writer).createBackup()

        // 清空信封内就诊——提醒来源缺失 → 恢复置 NULL 且计入报告（FR13.5 一票否决面）
        let frame = try EnvelopeFrame.parseBinary(package.data)
        let payload = try XCTUnwrap(frame?.payload)
        var envelope = try JSONDecoder().decode(ExportService.Envelope.self, from: payload)
        envelope.encounters = []
        let patchedPayload = try await ExportService(writer: source.writer).encode(envelope)

        var patched = Data("VLBU1".utf8)
        patched.append(contentsOf: [1])
        patched.append(contentsOf: CryptoKitContentHasher().sha256Hex(patchedPayload).utf8)
        var length = UInt64(patchedPayload.count).bigEndian
        withUnsafeBytes(of: &length) { patched.append(contentsOf: $0) }
        patched.append(patchedPayload)

        let destination = try GRDBStore.inMemory()
        let records = try await BackupService(writer: destination.writer).restore(from: patched)
        XCTAssertGreaterThan(records, 0)

        let row = try await destination.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM reminder WHERE id = ?", arguments: [reminderID.uuidString])
        }
        let restored = try XCTUnwrap(row)
        XCTAssertNil(restored["source_id"] as String?, "来源缺失必须置 NULL，绝不猜")
    }

    func test_encryptedBackupRoundTripAndWrongKeyRejected() async throws {
        let (source, _, _, _) = try await makeSeededStore()
        let subKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let ring = InMemoryKeyRing(subKey: subKey)
        let package = try await BackupService(writer: source.writer, keyRing: ring).createBackup(encrypted: true)
        XCTAssertEqual(EnvelopeFrame.binaryFormatVersion(package.data), 2)

        let destination = try GRDBStore.inMemory()
        let records = try await BackupService(writer: destination.writer, keyRing: ring).restore(from: package.data)
        XCTAssertGreaterThan(records, 0)
        let profileCount = try await rows(destination, "patient_profile").count
        XCTAssertEqual(profileCount, 1)

        // 错钥 → AEAD 认证失败 → checksumMismatch，零部分导入
        let wrongRing = InMemoryKeyRing(subKey: Data(repeating: 9, count: 32))
        do {
            _ = try await BackupService(writer: try GRDBStore.inMemory().writer, keyRing: wrongRing).restore(from: package.data)
            XCTFail("错钥必须拒绝")
        } catch BackupService.BackupError.checksumMismatch {
            // 期望路径
        }
    }

    func test_legacyJSONEnvelopeRestores() async throws {
        let (source, _, _, _) = try await makeSeededStore()
        let envelope = try await ExportService(writer: source.writer).exportJSON()
        let payload = try await ExportService(writer: source.writer).encode(envelope)
        // 遗留 JSON 信封以测试局部同构 Codable 构造：生产类型 BackupService.BackupEnvelope
        // 为 internal,包产品不可 @testable 导入——线格式（键名/类型）一致即可驱动
        // restore 的 v0 兼容路径,不触碰生产 API 面
        let outer = LegacyEnvelopeFixture(formatVersion: 1,
                                   sha256: CryptoKitContentHasher().sha256Hex(payload),
                                   exportedAt: envelope.exportedAt,
                                   payload: payload)
        let json = try JSONEncoder().encode(outer)

        let destination = try GRDBStore.inMemory()
        let records = try await BackupService(writer: destination.writer).restore(from: json)
        XCTAssertGreaterThan(records, 0)
        let profiles = try await rows(destination, "patient_profile")
        XCTAssertEqual(profiles.count, 1)
    }
}

/// 遗留 JSON 备份信封同构夹具（BackupService.BackupEnvelope 线格式副本,见
/// test_legacyJSONEnvelopeRestores 注）。
private struct LegacyEnvelopeFixture: Codable {
    var formatVersion: Int
    var sha256: String
    var exportedAt: TimeInterval
    var payload: Data
}

/// 测试用内存密钥环（DeviceKeyRing 端口实现；主密钥按 realm 隔离，子密钥固定注入）
private actor InMemoryKeyRing: DeviceKeyRing {
    private var masters: [UUID: Data] = [:]
    private var recoveryWrappeds: [UUID: Data] = [:]
    private let subKey: Data
    init(subKey: Data) { self.subKey = subKey }
    func masterKey(realmId: UUID) async throws -> Data? { masters[realmId] }
    func storeMasterKey(_ key: Data, realmId: UUID) async throws { masters[realmId] = key }
    func deviceSubKey() async throws -> Data { subKey }
    nonisolated func generateMasterKey() throws -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }   // 评审修复：actor 隔离见证不满足 nonisolated 同步协议要求（ConformanceIsolation）
    func storeRecoveryWrapped(_ wrapped: Data, realmId: UUID) async throws { recoveryWrappeds[realmId] = wrapped }
    func recoveryWrapped(realmId: UUID) async throws -> Data? { recoveryWrappeds[realmId] }
}
