import XCTest
import GRDB
import Domain
import Infrastructure
@testable import VitaLiber

// binds: SU-M1c-REGRESSION — TC-M1c-09（FR14.8 归档状态合并/代次/失败可见）
@MainActor
final class NotificationCenterStateTests: XCTestCase {
    private func make() throws -> (NotificationCenterState, GRDBStore) {
        let db = try GRDBStore.inMemory()
        return (NotificationCenterState(store: NotificationStateStore(writer: db.writer)), db)
    }

    /// 原名：test_load只合并请求键_空键集不清空
    func test_loadMergesOnlyRequestedKeys_emptyKeySetDoesNotClear() async throws {
        let (state, _) = try make()
        try await state.archive("apt-A")
        await state.load(keys: ["lot-L"])
        XCTAssertEqual(state.itemStates["apt-A"], .archived, "未请求的键不得被整体替换清掉")
        XCTAssertEqual(state.itemStates["lot-L"], .unread)
        await state.load(keys: [])
        XCTAssertEqual(state.itemStates["apt-A"], .archived)
    }

    /// 原名：test_陈旧加载不覆盖更新的本地写
    func test_staleLoadDoesNotOverwriteNewerLocalWrites() async throws {
        let (state, _) = try make()
        let snapshot = state.beginLoad()                 // 加载开始（读到的是归档前的旧值）
        try await state.archive("apt-A")                 // 加载途中用户归档
        state.applyLoaded(["apt-A": .unread, "lot-L": .read], requestedKeys: ["apt-A", "lot-L"], snapshot: snapshot)
        XCTAssertEqual(state.itemStates["apt-A"], .archived, "快照之后的本地写必须赢过陈旧读")
        XCTAssertEqual(state.itemStates["lot-L"], .read)
    }

    /// 原名：test_归档落库失败不改可观察态
    func test_archivePersistenceFailureKeepsObservableState() async throws {
        let (state, db) = try make()
        try db.writer.close()                            // GRDB：关闭后一切访问抛 SQLITE_MISUSE
        do { try await state.archive("apt-A"); XCTFail("关闭的库必须抛错") } catch {}
        XCTAssertNil(state.itemStates["apt-A"], "失败不得假归档（条目继续可见）")
    }

    /// 原名：test_撤销后为已读且持久层archived_at为空
    func test_undoMarksReadAndClearsArchivedAt() async throws {
        let (state, db) = try make()
        try await state.archive("apt-A"); try await state.unarchive("apt-A")
        XCTAssertEqual(state.itemStates["apt-A"], .read)
        let persisted = try await NotificationStateStore(writer: db.writer).states(for: ["apt-A"])
        XCTAssertEqual(persisted["apt-A"], .read)
    }
}
