import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
@testable import VitaLiber

/// v27 子项目 J · J4（round1 §E.3 / §E.7 V6）：SP-19 展开记忆 + 时间轴视图模型的主卡投影
///（默认最新展开 / 记忆优先 / 筛选瞬态不写记忆 / 游标翻页追加去重）。CI-only（GRDB / XCTest）。
@MainActor
// binds: SU-M1c-REGRESSION（FR11.1 / FR11.2 / BR-001）
final class TimelineExpansionStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "TimelineExpansionStoreTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_记忆_默认nil_写后可读_forget回默认() {
        let store = TimelineExpansionStore(defaults: defaults())
        XCTAssertNil(store.remembered("encounter-a"), "从未记过 → nil（交给 Domain 默认）")
        store.set("encounter-a", expanded: false)
        XCTAssertEqual(store.remembered("encounter-a"), false)
        XCTAssertEqual(store.version, 1)
        store.set("encounter-a", expanded: true)
        XCTAssertEqual(store.remembered("encounter-a"), true)
        store.forget("encounter-a")
        XCTAssertNil(store.remembered("encounter-a"))
        XCTAssertEqual(store.rememberedCount, 0)
    }

    func test_LRU容量_淘汰最久未触碰的键() {
        let store = TimelineExpansionStore(defaults: defaults(), capacity: 2)
        store.set("a", expanded: true)
        store.set("b", expanded: false)
        store.set("a", expanded: false)          // 触碰 a → b 成为最久
        store.set("c", expanded: true)           // 超容量 → 淘汰 b
        XCTAssertNil(store.remembered("b"), "最久未触碰的键被淘汰（连同 Bool 键）")
        XCTAssertEqual(store.remembered("a"), false)
        XCTAssertEqual(store.remembered("c"), true)
        XCTAssertEqual(store.rememberedCount, 2)
    }

    // MARK: - 视图模型：主卡分组 / 展开集 / 筛选 / 翻页

    private func makeStore() async throws -> (GRDBStore, UUID) {
        let store = try GRDBStore.inMemory(), patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'A', 'self', 0, 0)",
                           arguments: [patient.uuidString])
        }
        return (store, patient)
    }

    private func seedEncounter(_ db: GRDBStore, patient: UUID, at seconds: Double, withPrescription: Bool) async throws -> UUID {
        let enc = try await EncounterStore(writer: db.writer).upsert(encounter: .init(patientId: patient, date: Date(timeIntervalSince1970: seconds), kind: "outpatient", hospital: "市一院"))
        if withPrescription {
            try await db.writer.write { d in
                try d.execute(sql: "INSERT INTO prescription (id, patient_id, encounter_id, source, prescribed_at, confirmed, created_at, updated_at) VALUES (?, ?, ?, 'manual', ?, 1, 0, 0)",
                              arguments: [UUID().uuidString, patient.uuidString, enc.uuidString, seconds])
            }
        }
        return enc
    }

    private func makeState(_ db: GRDBStore, defaults: UserDefaults) -> TimelineViewState {
        TimelineViewState(store: TimelineQueryStore(writer: db.writer), problemStore: HealthProblemStore(writer: db.writer),
                          expansion: TimelineExpansionStore(defaults: defaults))
    }

    func test_视图模型_默认最新主卡展开_记忆优先_筛选瞬态不写记忆() async throws {
        let (db, patient) = try await makeStore()
        let newest = try await seedEncounter(db, patient: patient, at: 1_700_100_000, withPrescription: true)
        let older = try await seedEncounter(db, patient: patient, at: 1_700_000_000, withPrescription: true)
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO observation (id, patient_id, kind, occurred_at, description, created_at, updated_at) VALUES (?, ?, 'skin', 1699990000, '红疹', 0, 0)",
                          arguments: [UUID().uuidString, patient.uuidString])
        }
        let ud = defaults()
        let state = makeState(db, defaults: ud)
        await state.load(patientId: patient)

        XCTAssertEqual(state.hubs.map(\.hub), [.encounter, .encounter, nil], "两张就诊主卡（新→旧）+ 观察叶子")
        XCTAssertEqual(state.visibleHubs.count, 3)
        let newestId = "encounter-encounter-\(newest.uuidString)", olderId = "encounter-encounter-\(older.uuidString)"
        XCTAssertEqual(state.expandedIds, [newestId], "无记忆：仅最新主卡展开")

        state.setExpanded(newestId, false)
        XCTAssertEqual(state.expandedIds, [], "记忆折叠优先于默认展开")
        XCTAssertEqual(state.expansion.remembered(newestId), false, "无筛选态写入 UserDefaults 记忆")
        state.setExpanded(olderId, true)
        XCTAssertEqual(state.expandedIds, [olderId])

        // 筛选命中子卡：命中主卡全部瞬态展开；用户在筛选态收起只落瞬态，不写记忆
        state.setFilter([.prescription])
        await state.load(patientId: patient)
        XCTAssertEqual(state.visibleHubs.map(\.entry.refID), [newest, older], "观察叶子被筛掉；两主卡因命中处方子卡保留")
        XCTAssertEqual(state.expandedIds, [newestId, olderId])
        state.setExpanded(newestId, false)
        XCTAssertEqual(state.expandedIds, [olderId], "筛选态收起生效（瞬态）")
        XCTAssertEqual(state.expansion.remembered(newestId), false, "筛选态不改写记忆（仍是此前无筛选时写入的值）")
        XCTAssertEqual(state.expansion.rememberedCount, 2)

        // 回到无筛选：记忆值生效，瞬态清空
        state.setFilter(nil)
        await state.load(patientId: patient)
        XCTAssertEqual(state.expandedIds, [olderId])
    }

    func test_视图模型_游标翻页追加去重_跨成员为空() async throws {
        let (db, patient) = try await makeStore()
        for i in 0..<(TimelineViewState.pageSize + 5) {
            _ = try await seedEncounter(db, patient: patient, at: 1_600_000_000 + Double(i) * 86_400, withPrescription: false)
        }
        let state = makeState(db, defaults: defaults())
        await state.load(patientId: patient)
        XCTAssertEqual(state.hubs.count, TimelineViewState.pageSize, "首页 = 页大小")
        XCTAssertNotNil(state.nextCursor)
        await state.loadMore(patientId: patient)
        XCTAssertEqual(state.hubs.count, TimelineViewState.pageSize + 5, "第二页追加")
        XCTAssertNil(state.nextCursor, "末页无游标")
        XCTAssertEqual(Set(state.hubs.map(\.id)).count, state.hubs.count, "按 id 去重")
        await state.loadMore(patientId: patient)
        XCTAssertEqual(state.hubs.count, TimelineViewState.pageSize + 5, "无游标不再取")

        let other = makeState(db, defaults: defaults())
        await other.load(patientId: UUID())
        XCTAssertTrue(other.hubs.isEmpty, "BR-001：他人成员为空")
    }
}
