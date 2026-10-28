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

    func testAllCurrentAutoEnters() async throws {
        let state = try await stateAfterCheck(.upToDate(catalogVersion: 1))
        let descriptor = CatalogSlicesPromptPresentation.descriptor(for: state)
        XCTAssertTrue(descriptor.autoEnter, "全部最新应自动进入")
    }
}
