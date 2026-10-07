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

    @MainActor func testReadBeforeAnyActionIsIdleNotUnavailable() async {
        let state = UpdateAdviceState(provider: nil)
        XCTAssertNil(state.rowState(.asrModels), "读取前应为未读态（nil），不得预设不可用")
        await state.read()
        XCTAssertEqual(state.rowState(.asrModels), .unavailable)
        XCTAssertEqual(state.rowState(.medicalData), .unavailable)
    }

    @MainActor func testReadMapsProviderOutcomeClosedSet() async {
        let expected = UpdateAdviceOutcome(
            rows: [.asrModels: .announced, .medicalData: .notMentioned],
            payloadVersion: 3, generatedAt: "2026-10-07T00:00:00Z")
        let state = UpdateAdviceState(provider: StubProvider(outcome: expected))
        await state.read()
        XCTAssertEqual(state.outcome, expected)
        XCTAssertEqual(state.rowState(.asrModels), .announced)
        XCTAssertEqual(state.rowState(.medicalData), .notMentioned)
    }

    @MainActor func testStaleAndUnavailableOutcomesPassThrough() async {
        let state = UpdateAdviceState(provider: StubProvider(outcome: UpdateAdviceOutcome(
            rows: [.asrModels: .stale, .medicalData: .unavailable])))
        await state.read()
        XCTAssertEqual(state.rowState(.asrModels), .stale)
        XCTAssertEqual(state.rowState(.medicalData), .unavailable)
    }
}
