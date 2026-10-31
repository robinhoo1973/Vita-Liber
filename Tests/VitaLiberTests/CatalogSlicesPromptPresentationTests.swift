import XCTest
@testable import VitaLiber
import Domain
import Infrastructure

/// 首启卡 descriptor = autoEnter 单真源（U-批 B7，2026-10-28）。
/// 钉死：minApp 未达态（appUpdateRequired）绝不自动进入；全最新态自动进入。
/// 模型侧 `shouldAutoEnter` 重算已删除，视图仅在 descriptor.autoEnter 为真时调度。
@MainActor
final class CatalogSlicesPromptPresentationTests: XCTestCase {

    private final class StubResolver: CatalogSliceReleaseResolving, @unchecked Sendable {
        private let state: CatalogSliceRemoteState
        init(state: CatalogSliceRemoteState) { self.state = state }

        func check() async throws -> CatalogSliceCheckEnvelope {
            CatalogSliceCheckEnvelope(
                outcome: CatalogSliceCheckOutcome(results: CatalogSliceKind.allCases.map {
                    CatalogSliceCheckResult(kind: $0, state: state, localCatalogVersion: nil)
                }),
                verified: [:])
        }
    }

    private func stateAfterCheck(_ remote: CatalogSliceRemoteState) async throws -> CatalogSlicesState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("descriptor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // try?-ok: 测试目录
        let state = CatalogSlicesState(facade: CatalogSliceReadFacade(),
                                       checker: StubResolver(state: remote),
                                       updater: nil, receiptDirectory: dir)
        state.check()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, state.aggregate == .checking {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return state
    }

    func testAppUpdateRequiredNeverAutoEnters() async throws {
        let state = try await stateAfterCheck(
            .appUpdateRequired(minAppBuild: 999, minAppMarketingVersion: "9.9.9"))
        let descriptor = CatalogSlicesPromptPresentation.descriptor(for: state)
        XCTAssertFalse(descriptor.autoEnter, "minApp 未达态绝不得自动进入")
        XCTAssertEqual(descriptor.primary, .enter, "minApp 未达只给 [进入 App]")
    }

    /// 2026-10-29 业主两条原则 + 审查席 C：强制下载矩阵——
    /// firstLaunch ∧ 无本机片 = 无旁路；离线给「先进入」；非首启维持普通旁路。
    func testMandatoryMatrixFirstLaunchNoSlices() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("descriptor-matrix-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // try?-ok: 测试目录
        let state = CatalogSlicesState(facade: CatalogSliceReadFacade(),
                                       checker: StubResolver(state: .upToDate(catalogVersion: 1)),
                                       updater: nil, receiptDirectory: dir)
        // 未检查：强制模式无次动作；离线强制模式给「先进入」。
        if state.aggregate == .notChecked, state.installedCount == 0 {
            let strict = CatalogSlicesPromptPresentation.descriptor(for: state, firstLaunch: true)
            XCTAssertEqual(strict.primary, .check)
            XCTAssertNil(strict.secondary, "强制首启不得给「暂不下载」旁路")
            let offline = CatalogSlicesPromptPresentation.descriptor(
                for: state, firstLaunch: true, networkAvailable: false)
            XCTAssertEqual(offline.primary, .recheck)
            XCTAssertEqual(offline.secondary, .continueWithout, "离线豁免：给先进入")
            let normal = CatalogSlicesPromptPresentation.descriptor(for: state, firstLaunch: false)
            XCTAssertEqual(normal.secondary, .continueWithout, "非首启维持普通旁路")
        }
    }

    /// 2026-10-31 业主（mock 1:1 回归）：强制首启下载一旦开始，逐片完成
    /// 不得把 mandatory 翻成 false（下载中途长出第二个按钮的直接根因）。
    func testMandatoryDownloadFreezesAtUpdateStart() {
        XCTAssertTrue(CatalogSlicesPromptPresentation.mandatoryDownload(
            firstLaunch: true, installedCount: 1, installedCountAtUpdateStart: 0),
            "安装会话从 0 片开始：中途已装 1 片仍须保持强制，与 mock 一致")
        XCTAssertFalse(CatalogSlicesPromptPresentation.mandatoryDownload(
            firstLaunch: true, installedCount: 4, installedCountAtUpdateStart: 4),
            "更新会话开始时就已有目录：属于常规更新，不设强制门")
        XCTAssertTrue(CatalogSlicesPromptPresentation.mandatoryDownload(
            firstLaunch: true, installedCount: 0, installedCountAtUpdateStart: nil))
        XCTAssertFalse(CatalogSlicesPromptPresentation.mandatoryDownload(
            firstLaunch: false, installedCount: 1, installedCountAtUpdateStart: 0),
            "非首启永不强制")
    }

    func testAllCurrentAutoEnters() async throws {
        let state = try await stateAfterCheck(.upToDate(catalogVersion: 1))
        let descriptor = CatalogSlicesPromptPresentation.descriptor(for: state)
        XCTAssertTrue(descriptor.autoEnter, "全部最新应自动进入")
    }
}
