import XCTest
@testable import VitaLiber

/// 启动门会话持有者：终态/取消/超时必须有界（2026-10-27 审查 P1）。
/// install 路径需要真实 AppSession（依赖 AppContainer），由 UI 测试覆盖。
@MainActor
final class AppSessionHolderTests: XCTestCase {
    override func tearDown() async throws {
        AppSessionHolder.shared.resetForRetry()   // 清 sticky failed，避免污染后续用例
    }

    func testWaiterResumesNilWhenBootFails() async {
        let holder = AppSessionHolder.shared
        let waiter = Task { await holder.wait(timeout: .seconds(10)) }
        await Task.yield()
        holder.fail()
        let session = await waiter.value
        XCTAssertNil(session)
    }

    func testFailureIsStickyForNewWaiters() async {
        AppSessionHolder.shared.fail()
        let started = Date()
        let session = await AppSessionHolder.shared.wait(timeout: .seconds(10))
        XCTAssertNil(session)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testResetForRetryAllowsWaitingAgain() async {
        let holder = AppSessionHolder.shared
        holder.fail()
        holder.resetForRetry()
        let session = await holder.wait(timeout: .milliseconds(50))
        XCTAssertNil(session)   // 超时路径：有界返回，不挂起
    }

    func testTimeoutResumesNil() async {
        let started = Date()
        let session = await AppSessionHolder.shared.wait(timeout: .milliseconds(50))
        XCTAssertNil(session)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.04)
    }

    func testCancellationResumesNil() async {
        let holder = AppSessionHolder.shared
        let waiter = Task { await holder.wait(timeout: .seconds(10)) }
        try? await Task.sleep(nanoseconds: 30_000_000) // try?-ok: 测试内等待注册
        waiter.cancel()
        let session = await waiter.value
        XCTAssertNil(session)
    }
}
