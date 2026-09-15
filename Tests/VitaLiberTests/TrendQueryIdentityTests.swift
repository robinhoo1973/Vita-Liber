import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure

// binds: SU-M15-TREND / SU-M2-F16
/// round2 H2（查询身份回传）+ BR-001（设备来源只可能归属本人绑定）：
/// `TrendQueryStore.series(_:)` 携身份、按来源过滤，设备来源对非本人成员拒绝而非静默空态；
/// 全来源查询对非本人成员过滤掉任何 device 行（旧备份/重映射残留不得跨成员呈现）。
@MainActor
final class TrendQueryIdentityTests: XCTestCase {
    private struct Seed {
        let db: GRDBStore
        let trends: TrendQueryStore
        let owner: UUID
        let family: UUID
    }

    private let range = DateInterval(start: Date(timeIntervalSince1970: 1_600_000_000),
                                     end: Date(timeIntervalSince1970: 1_900_000_000))

    private func makeSeed() async throws -> Seed {
        let db = try GRDBStore.inMemory()
        let owner = UUID()
        let family = UUID()
        try await db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, 'Owner', 'self', 0, 0), (?, 'Family', 'other', 0, 0)
                """, arguments: [owner.uuidString, family.uuidString])
            try db.execute(sql: "INSERT INTO local_owner (id, display_name, self_patient_id, created_at) VALUES (?, 'Owner', ?, 0)",
                           arguments: [UUID().uuidString, owner.uuidString])
        }
        return Seed(db: db, trends: TrendQueryStore(writer: db.writer), owner: owner, family: family)
    }

    private func insertDeviceHeartRate(_ seed: Seed, patient: UUID, value: Double, at: Double) async throws {
        try await seed.db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                  source_ref, aggregation_kind, measured_at, created_at)
                VALUES (?, ?, 'heartRate', ?, 'bpm', 'device', 1, 0, ?, 'hourlyAverage', ?, 0)
                """, arguments: [UUID().uuidString, patient.uuidString, value, "hk:heartRate:\(Int(at)):watch", at])
        }
    }

    func test_deviceOriginQueryRequiresSelfBindingAndForeignDeviceRowsAreHidden() async throws {
        let seed = try await makeSeed()
        // owner = A；家人 B 名下手工插入一行 origin='device'（模拟旧备份/重映射残留）
        try await insertDeviceHeartRate(seed, patient: seed.family, value: 77, at: 1_700_006_400)
        _ = try await seed.trends.addSample(patientId: seed.family, metric: .heartRate, value: 66, secondaryValue: nil,
                                            unit: "bpm", measuredAt: Date(timeIntervalSince1970: 1_700_010_000))
        do {
            _ = try await seed.trends.series(TrendQueryIdentity(patientId: seed.family, metric: .heartRate, origin: .device, range: range))
            XCTFail("expected refusal: device origin can only belong to the bound self patient (BR-001)")
        } catch TrendQueryStore.QueryError.deviceRequiresSelfBinding { }
        let query = TrendQueryIdentity(patientId: seed.family, metric: .heartRate, origin: nil, range: range)
        let all = try await seed.trends.series(query)
        XCTAssertFalse(all.points.contains { $0.origin == .device }, "Foreign device rows must not be presented for a non-self member")
        XCTAssertEqual(all.points.map(\.value), [66])
        XCTAssertEqual(all.identity, query)
        XCTAssertEqual(all.metricType, .heartRate)
    }

    func test_originFilterReturnsOnlyRequestedOrigin() async throws {
        let seed = try await makeSeed()
        try await insertDeviceHeartRate(seed, patient: seed.owner, value: 80, at: 1_700_006_400)
        _ = try await seed.trends.addSample(patientId: seed.owner, metric: .heartRate, value: 70, secondaryValue: nil,
                                            unit: "bpm", measuredAt: Date(timeIntervalSince1970: 1_700_010_000))
        let onlyManual = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .heartRate, origin: .manual, range: range))
        XCTAssertEqual(Set(onlyManual.points.map(\.origin)), [.manual])
        XCTAssertEqual(onlyManual.points.map(\.value), [70])
        let onlyDevice = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .heartRate, origin: .device, range: range))
        XCTAssertEqual(Set(onlyDevice.points.map(\.origin)), [.device], "The bound self patient may filter device readings")
        XCTAssertEqual(onlyDevice.points.map(\.value), [80])
        let everything = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .heartRate, origin: nil, range: range))
        XCTAssertEqual(everything.points.map(\.value), [80, 70])
        let none = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .heartRate, origin: .hospital, range: range))
        XCTAssertTrue(none.points.isEmpty)
        XCTAssertEqual(none.identity?.origin, .hospital)
    }

    /// 舒张压双查询（收缩压行 secondary_value + 独立行）都必须套来源过滤，否则过滤只对半生效。
    func test_originFilterAppliesToBothDiastolicQueries() async throws {
        let seed = try await makeSeed()
        _ = try await seed.trends.addSample(patientId: seed.owner, metric: .bloodPressureSys, value: 120, secondaryValue: 80,
                                            unit: "mmHg", measuredAt: Date(timeIntervalSince1970: 1_700_006_400))
        try await seed.db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
                  raw_label, measured_at, created_at)
                VALUES (?, ?, 'bloodPressureDia', 85, 'mmHg', 'hospital', 0, 0, 'DBP', ?, 0)
                """, arguments: [UUID().uuidString, seed.owner.uuidString, 1_700_010_000])
        }
        let manual = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .bloodPressureDia, origin: .manual, range: range))
        XCTAssertEqual(manual.points.map(\.value), [80])
        let hospital = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .bloodPressureDia, origin: .hospital, range: range))
        XCTAssertEqual(hospital.points.map(\.value), [85])
        let all = try await seed.trends.series(TrendQueryIdentity(patientId: seed.owner, metric: .bloodPressureDia, range: range))
        XCTAssertEqual(all.points.map(\.value), [80, 85])
    }

    /// 兼容包装 `series(for:metric:range:)` = 全来源查询，身份同样回传（TrendAcceptanceTests 等调用方不改）。
    func test_legacySignatureForwardsAsAllOriginsWithIdentity() async throws {
        let seed = try await makeSeed()
        try await insertDeviceHeartRate(seed, patient: seed.owner, value: 80, at: 1_700_006_400)
        let series = try await seed.trends.series(for: seed.owner, metric: .heartRate, range: range)
        XCTAssertEqual(series.points.map(\.value), [80])
        XCTAssertEqual(series.identity, TrendQueryIdentity(patientId: seed.owner, metric: .heartRate, origin: nil, range: range))
    }

    /// 排除点集同样受成员过滤：非本人成员的 device 排除点也不得出现在对照视图。
    func test_excludedForeignDeviceRowsAreHiddenToo() async throws {
        let seed = try await makeSeed()
        try await insertDeviceHeartRate(seed, patient: seed.family, value: 77, at: 1_700_006_400)
        try await seed.db.writer.write { try $0.execute(sql: "UPDATE metric_sample SET excluded = 1") }
        let series = try await seed.trends.series(TrendQueryIdentity(patientId: seed.family, metric: .heartRate, range: range))
        XCTAssertTrue(series.points.isEmpty)
        XCTAssertTrue(series.excludedPoints.isEmpty)
    }
}
