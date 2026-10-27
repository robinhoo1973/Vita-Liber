import XCTest
import Domain
import Infrastructure
@testable import VitaLiber

/// 首启医疗目录卡：唯一状态→动作映射表（2026-10-27 方案 B）。
final class MedicalCatalogPromptPresentationTests: XCTestCase {
    private func input(
        _ state: MedicalCatalogRemoteState,
        progress: MedicalCatalogDownloadProgress? = nil,
        error: MedicalCatalogDownloadError? = nil,
        completedVersion: Int64? = nil,
        completedData: String? = nil,
        canUpdate: Bool = true,
        canCancelUpdate: Bool = true,
        hasLocal: Bool = true
    ) -> MedicalCatalogPromptInput {
        .init(remoteState: state, progress: progress, error: error,
              completedCatalogVersion: completedVersion, completedDataVersion: completedData,
              canUpdate: canUpdate, canCancelUpdate: canCancelUpdate,
              hasLocalCatalog: hasLocal)
    }

    private let candidate = MedicalCatalogUpdateCandidate(
        catalogVersion: 42, dataVersion: "d1", schemaVersion: 7,
        packageSize: 258_502_839, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))

    func testIdleWithoutLocalOffersCheckOnly() {
        let d = MedicalCatalogPromptPresentation.descriptor(input(.idle, hasLocal: false))
        XCTAssertEqual(d.primary, .check)
        XCTAssertEqual(d.secondary, .continueWithout)
        XCTAssertFalse(d.autoEnter)
        XCTAssertEqual(d.status, .idleNoLocal)
    }

    func testIdleWithLocalSaysNotCheckedYet() {
        let d = MedicalCatalogPromptPresentation.descriptor(input(.idle, hasLocal: true))
        XCTAssertEqual(d.status, .idleLocal)
        XCTAssertEqual(d.primary, .check)
    }

    func testCheckingIsBusyWithCancelSecondary() {
        let d = MedicalCatalogPromptPresentation.descriptor(input(.checking))
        XCTAssertEqual(d.primary, .busy)
        XCTAssertEqual(d.secondary, .cancelCheckAndContinue)
        XCTAssertFalse(d.autoEnter)
    }

    func testCandidateRequiresSecondTapToInstall() {
        let d = MedicalCatalogPromptPresentation.descriptor(input(.updateAvailable(candidate)))
        XCTAssertEqual(d.primary, .install, "检查落定后仍需第二次显式点击才下载")
        XCTAssertEqual(d.secondary, .continueWithout)
        XCTAssertFalse(d.autoEnter)
        XCTAssertEqual(d.status, .candidate(candidate))
    }

    func testCandidateWithoutUpdaterCannotInstall() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.updateAvailable(candidate), canUpdate: false))
        XCTAssertEqual(d.primary, .none)
        XCTAssertEqual(d.secondary, .continueWithout)
    }

    func testDownloadFailureRetries() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.updateAvailable(candidate), error: .downloadFailed))
        XCTAssertEqual(d.primary, .retryInstall)
        XCTAssertEqual(d.status, .failure(.downloadFailed, hasLocal: true))
    }

    func testStorageFailureRetries() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.updateAvailable(candidate), error: .insufficientStorage))
        XCTAssertEqual(d.primary, .retryInstall)
    }

    func testExpiredOrVerificationFailureRechecks() {
        for error: MedicalCatalogDownloadError in
            [.catalogNotInstallable, .catalogRolledBack, .checksumMismatch, .packageInvalid] {
            let d = MedicalCatalogPromptPresentation.descriptor(
                input(.updateAvailable(candidate), error: error))
            XCTAssertEqual(d.primary, .recheck, "\(error) 只能重新检查")
        }
    }

    func testNoLocalFailureSaysOtherFeaturesUnaffected() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.updateAvailable(candidate), error: .downloadFailed, hasLocal: false))
        XCTAssertEqual(d.status, .failure(.downloadFailed, hasLocal: false))
        XCTAssertEqual(MedicalCatalogPromptCopy.errorText(.downloadFailed, hasLocal: false),
                       L10n.resourceCatalogUpdateFailedNoLocal)
    }

    func testDownloadingKeepsUpdateAndAllowsLeaving() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.updateAvailable(candidate),
                  progress: .downloading(receivedBytes: 10, totalBytes: 100)))
        XCTAssertEqual(d.primary, .enterKeepingUpdate, "下载中主按钮不得静默取消下载")
        XCTAssertEqual(d.secondary, .cancelUpdateAndContinue)
        XCTAssertFalse(d.autoEnter)
    }

    func testActivatingHasNoCancel() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.updateAvailable(candidate), progress: .activating))
        XCTAssertEqual(d.primary, .busy)
        XCTAssertNil(d.secondary)
        XCTAssertFalse(d.autoEnter)
    }

    func testUpToDateAndNoInstallableAutoEnter() {
        for state: MedicalCatalogRemoteState in [.upToDate, .noInstallableAvailable] {
            let d = MedicalCatalogPromptPresentation.descriptor(input(state))
            XCTAssertEqual(d.primary, .enter)
            XCTAssertNil(d.secondary)
            XCTAssertTrue(d.autoEnter)
        }
    }

    func testCompletedAutoEnters() {
        let d = MedicalCatalogPromptPresentation.descriptor(
            input(.upToDate, completedVersion: 42, completedData: "d1"))
        XCTAssertEqual(d.primary, .enter)
        XCTAssertTrue(d.autoEnter)
        XCTAssertEqual(d.status, .completed(42))
    }

    func testRemoteFailuresOfferRecheck() {
        for state: MedicalCatalogRemoteState in
            [.unavailable, .networkUnavailable, .verificationFailed, .rateLimited(retryAfter: nil)] {
            let d = MedicalCatalogPromptPresentation.descriptor(input(state))
            XCTAssertEqual(d.primary, .recheck, "\(state)")
            XCTAssertEqual(d.secondary, .continueWithout)
            XCTAssertFalse(d.autoEnter)
        }
    }

    func testAtMostOnePrimaryAndSecondaryDiffers() {
        let states: [MedicalCatalogRemoteState] = [
            .idle, .checking, .updateAvailable(candidate), .upToDate,
            .noInstallableAvailable, .unavailable, .networkUnavailable,
            .verificationFailed, .rateLimited(retryAfter: nil)]
        for state in states {
            let d = MedicalCatalogPromptPresentation.descriptor(input(state))
            XCTAssertFalse(d.primary == .busy && d.secondary == .busy)
            if let secondary = d.secondary { XCTAssertNotEqual(secondary, d.primary) }
        }
    }
}
