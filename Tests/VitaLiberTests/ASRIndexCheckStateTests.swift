import XCTest
import Domain
@testable import Infrastructure
@testable import VitaLiber

// binds: SU-M15-UPDATECENTER
/// ASR 检查状态机（2026-10-07 自 `ASREngineSettingsSection` 上提）：
/// 单飞 / 真取消（迟到结果丢弃）/ 看门狗（时长可注入）/ 安装互斥的诚实归态
/// （`.installInProgress` 不渲染为失败——2026-09-16 评审事故的对偶）。
final class ASRIndexCheckStateTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    @MainActor func testSuccessPathMapsToUpToDateAndBumpsDerivation() async {
        let state = ASRIndexCheckState(
            fetchIndex: { _ in ASRModelReleaseIndex(models: []) },
            isInstallActive: { false })
        state.check()
        XCTAssertEqual(state.state, .checking)
        await state.refreshTask?.value
        XCTAssertEqual(state.state, .upToDate)
        XCTAssertEqual(state.derivationEpoch, 1)
        XCTAssertNotNil(state.index)
    }

    @MainActor func testFailureMapsToFailed() async {
        enum StubError: Error { case boom }
        let state = ASRIndexCheckState(
            fetchIndex: { _ in throw StubError.boom },
            isInstallActive: { false })
        state.check()
        await state.refreshTask?.value
        XCTAssertEqual(state.state, .failed)
        XCTAssertNil(state.index)
    }

    @MainActor func testInstallInProgressMapsToIdleNotFailed() async {
        let state = ASRIndexCheckState(
            fetchIndex: { _ in throw ASRDownloadFailure.installInProgress },
            isInstallActive: { false })
        state.check()
        await state.refreshTask?.value
        XCTAssertEqual(state.state, .idle, "「正在下载」不得渲染为「功能坏了」（2026-09-16 事故对偶）")
    }

    @MainActor func testCancelTrulyInterruptsAndDiscardsLateResult() async {
        let state = ASRIndexCheckState(
            fetchIndex: { _ in
                try await Task.sleep(nanoseconds: 300_000_000)
                return ASRModelReleaseIndex(models: [])
            },
            isInstallActive: { false })
        state.check()
        XCTAssertEqual(state.state, .checking)
        state.cancel()
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.index)
        // 迟到窗口内确认无回写（取消的 fetch 抛出，外层守卫丢弃）
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.index, "取消后不得落定任何结果")
    }

    @MainActor func testWatchdogTimeoutMapsToFailedAndInterrupts() async {
        let state = ASRIndexCheckState(
            fetchIndex: { _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return ASRModelReleaseIndex(models: [])
            },
            checkTimeout: .milliseconds(50),
            isInstallActive: { false })
        state.check()
        await state.refreshTask?.value
        XCTAssertEqual(state.state, .failed, "看门狗超时应回「失败可重试」并真中断在途请求")
    }

    @MainActor func testSingleFlightIgnoresSecondCheckWhileRunning() async {
        let counter = Counter()
        let state = ASRIndexCheckState(
            fetchIndex: { _ in
                await counter.bump()
                try await Task.sleep(nanoseconds: 150_000_000)
                return ASRModelReleaseIndex(models: [])
            },
            isInstallActive: { false })
        state.check()
        state.check()
        await state.refreshTask?.value
        let total = await counter.value
        XCTAssertEqual(total, 1, "单飞：连点不得叠第二个拉取任务")
    }

    @MainActor func testChainSummaryMapsStatesAndInstallBusy() {
        let idle = ASRIndexCheckState(
            fetchIndex: { _ in ASRModelReleaseIndex(models: []) },
            isInstallActive: { false })
        XCTAssertEqual(idle.chainSummary, .notChecked)
        let busy = ASRIndexCheckState(
            fetchIndex: { _ in ASRModelReleaseIndex(models: []) },
            isInstallActive: { true })
        XCTAssertEqual(busy.chainSummary, .updating, "安装进行中优先呈 updating（域跳过语义）")
    }
}
