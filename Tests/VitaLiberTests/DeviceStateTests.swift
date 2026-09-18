import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-F16
/// round2 H1/H3/H-N3（子项目 C6）：`F16DeviceState` 把可观察事实（开关 / 设备能力 / 本人档案 /
/// 绑定 / 已导入行）映射为 `HealthImportPageState` 三态——缺本人档案是独立状态而非「同步失败」，
/// 开关关闭优先于一切；`run()` 抛 `disabled` 时状态对象呈现「已关闭」而非通用失败。
@MainActor
final class DeviceStateTests: XCTestCase {
    private func makeState(seedOwner: Bool) async throws -> (GRDBStore, HealthImportStore, F16DeviceState) {
        let db: GRDBStore
        if seedOwner {
            (db, _) = try await GRDBStore.inMemoryWithOwner()
        } else {
            db = try GRDBStore.inMemory()
        }
        let imports = HealthImportStore(writer: db.writer)
        let service = HealthKitSyncService(provider: F16StubProvider(), imports: imports,
                                           guidelines: GuidelineStore(writer: db.writer),
                                           scheduler: InMemoryReminderScheduler())
        return (db, imports, F16DeviceState(syncService: service, dataChange: AppDataChangeCenter(),
                                            settings: AppSettingsStore(store: SettingsStore(writer: db.writer))))
    }

    func test_missingOwnerMapsToOwnerMissingStateNotSyncFailed() async throws {
        let (_, _, state) = try await makeState(seedOwner: false)   // 不种 local_owner
        // currentAuthorization 先取设备能力再刷新仪表盘——available 只在此处写入，
        // 直接调 refreshDashboard 会让 pageState 停在 .unavailable（能力未知）而非缺本人
        let connected = await state.currentAuthorization()
        XCTAssertFalse(connected)
        XCTAssertTrue(state.ownerMissing, "H-N3：缺本人档案是独立可观察事实")
        XCTAssertEqual(state.phase, .idle, "缺本人档案不得降级为「同步失败」")
        XCTAssertNil(state.dashboard)
        XCTAssertEqual(state.pageState(enabled: true), .ownerMissing)
        XCTAssertEqual(state.pageState(enabled: false), .disabled, "关闭优先于一切")
        XCTAssertFalse(HealthImportVisibility.showsImportedData(state.pageState(enabled: true)))
    }

    func test_pageStateFollowsBindingAndImportedRows() async throws {
        let (_, imports, state) = try await makeState(seedOwner: true)
        _ = await state.currentAuthorization()
        XCTAssertFalse(state.ownerMissing)
        XCTAssertEqual(state.pageState(enabled: true), .notConnected)
        _ = try await imports.connect(timeZoneID: "UTC")
        _ = await state.currentAuthorization()
        XCTAssertTrue(state.connected)
        // 已连接但零已导入行 → 独立空态（H-N5），展示区存在但趋势链接不可用（H2）
        XCTAssertEqual(state.pageState(enabled: true), .connectedEmpty)
        XCTAssertTrue(HealthImportVisibility.showsImportedData(state.pageState(enabled: true)))
        XCTAssertFalse(HealthImportVisibility.allowsTrendLink(state.pageState(enabled: true),
                                                              patientId: state.dashboard?.patientId))
        XCTAssertEqual(state.pageState(enabled: false), .disabled)
    }

    func test_syncWithToggleOffPresentsDisabledNotGenericFailure() async throws {
        let (db, imports, state) = try await makeState(seedOwner: true)
        _ = try await imports.connect(timeZoneID: "UTC")
        try await db.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, 'false')",
                           arguments: [AppSettingKey.authHealthRead.rawValue])
        }
        // 视图层开关旗标与库内设置可短暂不一致（写入在途）：服务侧 run() 复核抛 disabled，
        // 状态对象必须呈现「已关闭」而不是「同步失败」（H3/H-N4）
        await state.sync(authEnabled: true, quietStart: "22:00", quietEnd: "07:00", maxRounds: 1)
        XCTAssertEqual(state.phase, .degraded(L10n.f16AuthDisabled))
        XCTAssertEqual(state.pageState(enabled: false), .disabled)
    }
}

/// 最小可用读取源：设备可用、授权流程视为已完成、任何道均为空页、无窗口快照。
private actor F16StubProvider: HealthReadingProvider {
    enum Failure: Error { case noSnapshot }
    func isAvailable() -> Bool { true }
    func requestAuthorization() {}
    func changes(for kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) -> HealthChangeBatch {
        HealthChangeBatch(added: [], deleted: [], anchor: anchor ?? Data("\(kind.rawValue).\(scope.lane.rawValue)".utf8), hasMore: false)
    }
    func snapshot(for window: HealthImportWindow, calendar: Calendar) throws -> HealthWindowSnapshot { throw Failure.noSnapshot }
}
