import XCTest
import Domain
@testable import Infrastructure
@testable import VitaLiber

// binds: SU-M15-MEDCATALOG（通告面）
/// SP-64 通告区状态机（委员会 P3，2026-10-07；R2.x 类型面）：
/// 读取前=未读态（nil，不与「不可用」混淆）；provider 缺省 → 读取后全域不可用；
/// 读取映射 provider 封闭四态——**不存在「已最新」态**。
final class UpdateAdviceStateTests: XCTestCase {
    private struct StubProvider: UpdateAdviceProviding {
        let outcome: UpdateAdviceOutcome
        func read() async -> UpdateAdviceOutcome { outcome }
    }

    /// 迟到结果用：读体可被取消（Task.sleep 响应取消）。
    private struct SlowProvider: UpdateAdviceProviding {
        let outcome: UpdateAdviceOutcome
        func read() async -> UpdateAdviceOutcome {
            try? await Task.sleep(nanoseconds: 200_000_000)   // try?-ok: 测试用可取消休眠（取消即返回，属预期）
            return outcome
        }
    }

    @MainActor func testReadBeforeAnyActionIsIdleNotUnavailable() async {
        let state = UpdateAdviceState(provider: nil)
        XCTAssertNil(state.rowState(.asrModels), "读取前应为未读态（nil），不得预设不可用")
        state.read()
        XCTAssertEqual(state.rowState(.asrModels), .unavailable)
        XCTAssertEqual(state.rowState(.medicalData), .unavailable)
    }

    @MainActor func testReadMapsProviderOutcomeClosedSet() async {
        let expected = UpdateAdviceOutcome(
            rows: [.asrModels: .announced, .medicalData: .notMentioned],
            payloadVersion: 3, generatedAt: "2026-10-07T00:00:00Z")
        let state = UpdateAdviceState(provider: StubProvider(outcome: expected))
        state.read()
        await state.readTask?.value
        XCTAssertEqual(state.outcome, expected)
        XCTAssertEqual(state.rowState(.asrModels), .announced)
        XCTAssertEqual(state.rowState(.medicalData), .notMentioned)
    }

    @MainActor func testStaleAndUnavailableOutcomesPassThrough() async {
        let state = UpdateAdviceState(provider: StubProvider(outcome: UpdateAdviceOutcome(
            rows: [.asrModels: .stale, .medicalData: .unavailable])))
        state.read()
        await state.readTask?.value
        XCTAssertEqual(state.rowState(.asrModels), .stale)
        XCTAssertEqual(state.rowState(.medicalData), .unavailable)
    }

    /// 统一更新中心批（架构席 §1.2）：取消 = 真中断 + 迟到结果丢弃，不产「暂不可用」假象。
    @MainActor func testCancelDiscardsLateResult() async {
        let state = UpdateAdviceState(provider: SlowProvider(outcome: UpdateAdviceOutcome(
            rows: [.asrModels: .announced, .medicalData: .announced])))
        state.read()
        XCTAssertTrue(state.isReading)
        let task = state.readTask
        state.cancel()
        XCTAssertFalse(state.isReading)
        await task?.value
        XCTAssertNil(state.outcome, "取消后不得落定任何结果（含 provider 归约出的不可用态）")
        XCTAssertNil(state.rowState(.asrModels), "首读取消后应保持未读态")
    }

    /// R11（测试席先行发现）：outcome 已落定但域缺行 = 不可用，不得回退成「尚未读取」。
    @MainActor func testOutcomeWithMissingDomainRowIsUnavailableNotIdle() async {
        let state = UpdateAdviceState(provider: StubProvider(outcome: UpdateAdviceOutcome(
            rows: [.asrModels: .announced])))
        state.read()
        await state.readTask?.value
        XCTAssertEqual(state.rowState(.medicalData), .unavailable)
        XCTAssertEqual(state.rowState(.asrModels), .announced)
    }
}
