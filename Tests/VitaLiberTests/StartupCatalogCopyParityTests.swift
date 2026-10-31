import XCTest
import Foundation
@testable import VitaLiber
import Domain

/// mock parity 契约（owner rule 2026-10-31）：逐状态断言启动目录卡的动作与文案，
/// 防止规则层/渲染层再次各写一份。断言 L10n 值而非中文字面量。
@MainActor
final class StartupCatalogCopyParityTests: XCTestCase {
    func testPhaseActionsMatchMock() {
        let downloading = MedicalCatalogDownloadProgress.downloading(receivedBytes: 1, totalBytes: 2)
        XCTAssertEqual(
            CatalogSlicesPromptPresentation.phaseActions(progress: downloading, mandatory: true).primary,
            .busy)
        XCTAssertNil(
            CatalogSlicesPromptPresentation.phaseActions(progress: downloading, mandatory: true).secondary,
            "强制首启下载中不得出现第二个按钮")
        XCTAssertEqual(
            CatalogSlicesPromptPresentation.phaseActions(progress: downloading, mandatory: false).secondary,
            .cancelUpdateAndContinue)
        XCTAssertNil(
            CatalogSlicesPromptPresentation.phaseActions(progress: .activating, mandatory: false).secondary,
            "activating 不可取消（journal 契约）")
    }

    func testBusyTitleUsesMockPhaseCopy() {
        let downloading = CatalogSlicesPromptStatus.phase(
            kind: .drug, progress: .downloading(receivedBytes: 1, totalBytes: 2))
        XCTAssertEqual(StartupCatalogCopy.primaryTitle(.busy, status: downloading, sizeText: nil),
                       L10n.startupCatalogDownloading)
        let activating = CatalogSlicesPromptStatus.phase(kind: .drug, progress: .activating)
        XCTAssertEqual(StartupCatalogCopy.primaryTitle(.busy, status: activating, sizeText: nil),
                       L10n.startupCatalogActivating)
        XCTAssertEqual(StartupCatalogCopy.primaryTitle(.busy, status: .checking, sizeText: nil),
                       L10n.resourceCatalogChecking)
    }

    func testIdleStatusCopyMatchesMock() {
        XCTAssertEqual(
            StartupCatalogCopy.statusText(.idleNoLocal(installed: 2), mandatory: false),
            L10n.startupCatalogStatusIdleLocalFmt(2, CatalogSliceKind.allCases.count))
        XCTAssertEqual(StartupCatalogCopy.statusText(.idleNoLocal(installed: 0), mandatory: true),
                       L10n.startupCatalogStatusIdleNoLocalRequired)
        XCTAssertEqual(StartupCatalogCopy.statusText(.idleNoLocal(installed: 0), mandatory: false),
                       L10n.startupCatalogStatusIdleNoLocal)
    }

    func testSecondaryTitlesMatchMock() {
        XCTAssertEqual(StartupCatalogCopy.secondaryTitle(.cancelUpdateAndContinue),
                       L10n.startupCatalogCancelUpdateContinue)
        XCTAssertEqual(StartupCatalogCopy.secondaryTitle(.continueWithout, networkBlocked: true),
                       L10n.startupCatalogEnterFirst)
        XCTAssertEqual(StartupCatalogCopy.secondaryTitle(.continueWithout, networkBlocked: false),
                       L10n.startupCatalogContinue)
    }

    func testCandidateStatusUsesMockKey() {
        let size: Int64 = 1_000_000
        XCTAssertEqual(
            StartupCatalogCopy.statusText(.candidate(count: 2, totalSize: size), mandatory: false),
            L10n.startupCatalogCandidateFmt(
                ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
    }
}
