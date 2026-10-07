import XCTest
import Domain
@testable import Infrastructure
@testable import VitaLiber

// binds: SU-M15-UPDATECENTER
/// 统一更新中心编排（2026-10-07 批）：扇出并行 / 按域自结 / 单飞防抖 /
/// 逐组件取消 / updating 域跳过；通告态永不改变动作面（R2.6）。
final class UpdateCenterStateTests: XCTestCase {
    @MainActor
    private final class StubChain: UpdateChainDriving {
        var chainSummary: UpdateChainRowState = .notChecked
        private(set) var checks = 0
        private(set) var cancels = 0
        func check() { checks += 1; chainSummary = .checking }
        func cancelCheck() { cancels += 1; chainSummary = .notChecked }
    }

    private struct StubProvider: UpdateAdviceProviding {
        let outcome: UpdateAdviceOutcome
        func read() async -> UpdateAdviceOutcome { outcome }
    }

    @MainActor func testCheckAllFansOutSettlesPerDomainAndGuardsBusy() async {
        let asr = StubChain()
        let medical = StubChain()
        let advice = UpdateAdviceState(provider: StubProvider(outcome: UpdateAdviceOutcome(
            rows: [.asrModels: .announced, .medicalData: .notMentioned])))
        let center = UpdateCenterState(advice: advice, chains: [.asrModels: asr, .medicalData: medical])

        center.checkAll()
        XCTAssertEqual(asr.checks, 1)
        XCTAssertEqual(medical.checks, 1)
        XCTAssertTrue(advice.isReading)
        XCTAssertTrue(center.isBusy)

        center.checkAll()   // busy 守卫：不得叠第二路
        XCTAssertEqual(asr.checks, 1)
        XCTAssertEqual(medical.checks, 1)

        await advice.readTask?.value
        XCTAssertTrue(center.isBusy, "域链仍在检查 ⇒ 仍 busy（派生态）")
        asr.chainSummary = .upToDate
        medical.chainSummary = .failed
        XCTAssertFalse(center.isBusy)

        // 按域自结 + 覆盖规则：终态抑制通告；失败域保留通告可见；动作面只认 updateAvailable
        let asrView = center.presentation(for: .asrModels)
        XCTAssertEqual(asrView.status, .upToDate)
        XCTAssertEqual(asrView.advice, .coveredByChainConclusion)
        XCTAssertFalse(asrView.showsVerifiedUpdate)
        let medicalView = center.presentation(for: .medicalData)
        XCTAssertEqual(medicalView.status, .failed)
        XCTAssertEqual(medicalView.advice, .visible(.notMentioned))
        XCTAssertFalse(medicalView.showsVerifiedUpdate)
    }

    @MainActor func testCheckAllSkipsUpdatingDomains() {
        let asr = StubChain()
        asr.chainSummary = .updating
        let medical = StubChain()
        let advice = UpdateAdviceState(provider: nil)
        let center = UpdateCenterState(advice: advice, chains: [.asrModels: asr, .medicalData: medical])

        center.checkAll()
        XCTAssertEqual(asr.checks, 0, "更新/安装进行中的域必须跳过（不发请求）")
        XCTAssertEqual(medical.checks, 1)
    }

    @MainActor func testCancelAllForwardsToEveryComponent() {
        let asr = StubChain()
        let medical = StubChain()
        let advice = UpdateAdviceState(provider: StubProvider(outcome: UpdateAdviceOutcome(
            rows: [.asrModels: .announced, .medicalData: .announced])))
        let center = UpdateCenterState(advice: advice, chains: [.asrModels: asr, .medicalData: medical])

        center.cancelAll()
        XCTAssertEqual(asr.cancels, 1)
        XCTAssertEqual(medical.cancels, 1)
    }

    @MainActor func testUnassembledDomainPresentsUnavailableWithoutAction() {
        let medical = StubChain()
        let center = UpdateCenterState(
            advice: UpdateAdviceState(provider: nil), chains: [.medicalData: medical])
        let view = center.presentation(for: .asrModels)
        XCTAssertEqual(view.status, .unavailable, "无 driver 域 = 不可用（fail-closed）")
        XCTAssertFalse(view.showsVerifiedUpdate)
    }
}
