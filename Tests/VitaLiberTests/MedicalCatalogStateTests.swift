import XCTest
import Foundation
import Domain
import Infrastructure
@testable import Infrastructure
@testable import VitaLiber

// binds: SU-M15-MEDCATALOG
/// SU-M15-MEDCATALOG · SP-64 状态机行为钉（2026-09-27 测试席评审 C10 落地）：
/// `MedicalCatalogState` 检查/更新状态机——显式检查→九态、取消回 idle、单飞守卫、
/// expiry 前置、失败词汇映射。applyUpdate 成功路径（下载→校验→原子替换→复开）的
/// 安装链由 CoreKit 验收套件端到端覆盖（复开需真 catalog SQLite）；本套件钉
/// 状态包装层的全部非复开分支。候选经 DEBUG 门控 `testing` 工厂构造（Release 密封不变）。
@MainActor
final class MedicalCatalogStateTests: XCTestCase {

    private struct StubError: Error, Sendable {}

    /// 协议桩 checker：可配置结果/错误。
    private actor StubChecker: MedicalCatalogReleaseResolving {
        private var outcome: MedicalCatalogCheckOutcome = MedicalCatalogCheckOutcome(state: .upToDate)
        private var error: (any Error & Sendable)?

        func set(_ outcome: MedicalCatalogCheckOutcome) { self.outcome = outcome }
        func setError(_ error: any Error & Sendable) { self.error = error }
        func check() async throws -> MedicalCatalogCheckOutcome {
            if let error { throw error }
            return outcome
        }
    }

    /// 挂起式 checker：检查悬停直到显式 resume。`cancellationAware` = 响应任务取消
    /// （生产 resolver 形态）；否则即使任务已取消也照常返回（迟到结果守卫测试用）。
    private actor GatedChecker: MedicalCatalogReleaseResolving {
        private let cancellationAware: Bool
        private var continuation: CheckedContinuation<MedicalCatalogCheckOutcome, any Error>?

        init(cancellationAware: Bool = true) {
            self.cancellationAware = cancellationAware
        }

        func check() async throws -> MedicalCatalogCheckOutcome {
            if cancellationAware {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation = $0 }
                } onCancel: {
                    Task { [weak self] in await self?.fail(CancellationError()) }
                }
            }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func resume(_ outcome: MedicalCatalogCheckOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func fail(_ error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    /// 立即失败 fetcher（下载失败路径钉）。
    private struct FailingFetcher: MedicalCatalogPackageFetching {
        let error: MedicalCatalogUpdateError
        func fetch(assetName: String, expectedSize: Int64, to destination: URL,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
            throw error
        }
    }

    /// 无操作 opener：让取消用例的链路到达挂起 fetcher（无 opener 会被状态机
    /// 前置短路为 packageInvalid，1-vote 验证发现的接线遗漏）。
    private struct NoopOpener: MedicalCatalogPackageOpening {
        func open(packageURL: URL, sqliteURL: URL, maxSQLiteBytes: Int64) async throws {}
    }

    /// 挂起式 fetcher：取消响应经 withTaskCancellationHandler 还原（生产 URLSession
    /// 取消形态的桩等价）。
    private actor GatedFetcher: MedicalCatalogPackageFetching {
        private var continuation: CheckedContinuation<Void, any Error>?
        func fetch(assetName: String, expectedSize: Int64, to destination: URL,
                   progress: @escaping @Sendable (Int64) -> Void) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation = $0 }
            } onCancel: {
                Task { [weak self] in await self?.fail(CancellationError()) }
            }
        }
        func fail(_ error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private final class StubJournal: MedicalCatalogActivationJournaling, @unchecked Sendable {
        func begin(_ pending: PendingActivation) throws {}
        func complete(_ pending: PendingActivation) throws {}
    }

    // MARK: - 组装

    /// 通过 DEBUG 门控工厂构造验签候选（走真实 pointer decode 合法性校验）。
    private func makeCandidate(expiresIn: TimeInterval = 3600) throws -> VerifiedMedicalCatalogCandidate {
        let sqliteSHA = String(repeating: "a", count: 64)
        let packageSHA = String(repeating: "b", count: 64)
        return try VerifiedMedicalCatalogCandidate.testing(
            catalogVersion: 42,
            dataVersion: String(repeating: "c", count: 64),
            schemaVersion: 5,
            packageAssetName: MedicalCatalogReleaseProtocol.packageAssetName(
                sqliteSHA256: sqliteSHA, packageSHA256: packageSHA),
            packageSize: 1024,
            packageSHA256: packageSHA,
            sqliteSHA256: sqliteSHA,
            installable: true,
            issuedAt: Date().addingTimeInterval(-3600),
            expiresAt: Date().addingTimeInterval(expiresIn),
            signedPointerDigest: String(repeating: "d", count: 64))
    }

    /// 返回 (updater, destination)——state 需要 path（applyUpdate guard 要求非 nil）。
    private func makeUpdater(fetcher: any MedicalCatalogPackageFetching,
                             now: @escaping @Sendable () -> Date = { Date() })
        throws -> (MedicalCatalogUpdateService, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("medical-catalog.sqlite")
        let service = MedicalCatalogUpdateService(destination: destination,
                                                  fetcher: fetcher, journal: StubJournal(),
                                                  limits: MedicalCatalogUpdateLimits(maxPackageBytes: 1 << 20,
                                                                                     maxSQLiteBytes: 1 << 22),
                                                  activeCheck: { _ in }, now: now)
        return (service, destination)
    }

    private func updateAvailableOutcome() throws -> MedicalCatalogCheckOutcome {
        let candidate = try makeCandidate()
        return MedicalCatalogCheckOutcome(
            state: .updateAvailable(MedicalCatalogUpdateCandidate(
                catalogVersion: candidate.catalogVersion, dataVersion: candidate.dataVersion,
                schemaVersion: candidate.schemaVersion, packageSize: candidate.packageSize,
                expiresAt: candidate.expiresAt)),
            candidate: candidate)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 2,
                           _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(20)) // try?-ok: 测试轮询等待，睡眠失败即下一轮
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - 检查态

    func testCheck_noChecker_setsUnavailable() async {
        let state = MedicalCatalogState(store: nil)
        state.check()
        await waitUntil("无 checker 应呈 unavailable") { state.remoteState == .unavailable }
    }

    func testCheck_success_setsRemoteState() async {
        let checker = StubChecker()
        await checker.set(MedicalCatalogCheckOutcome(state: .upToDate))
        let state = MedicalCatalogState(store: nil, checker: checker)
        state.check()
        await waitUntil("检查成功应呈 upToDate") { state.remoteState == .upToDate }
    }

    func testCheck_updateAvailable_holdsCandidate() async throws {
        let checker = StubChecker()
        await checker.set(try updateAvailableOutcome())
        let (updater, destination) = try makeUpdater(fetcher: FailingFetcher(error: .downloadFailed))
        let state = MedicalCatalogState(store: nil, updater: updater, path: destination, checker: checker)
        state.check()
        await waitUntil("检查应发现可安装更新") {
            if case .updateAvailable = state.remoteState { return true }
            return false
        }
        // 状态持有验签候选：applyUpdate 能拿到（无 opener → packageInvalid，
        // 证明候选已在手、走的是状态机内路径而非空操作）
        state.applyUpdate()
        await waitUntil("无 opener 应呈 packageInvalid") { state.updateError == .packageInvalid }
        XCTAssertFalse(state.isUpdating)
    }

    func testCheck_throwsNonCancellation_setsNetworkUnavailable() async {
        let checker = StubChecker()
        await checker.setError(StubError())
        let state = MedicalCatalogState(store: nil, checker: checker)
        state.check()
        await waitUntil("非取消异常应呈 networkUnavailable") { state.remoteState == .networkUnavailable }
    }

    func testCheck_cancelledTask_returnsToIdle() async {
        let checker = GatedChecker()
        let state = MedicalCatalogState(store: nil, checker: checker)
        state.check()
        await waitUntil("检查应进入 checking 悬停") { state.remoteState == .checking }
        state.cancelCheck()
        await waitUntil("取消检查应回 idle") { state.remoteState == .idle }
    }

    func testCheck_lateOutcomeAfterCancel_isIgnored() async {
        // 不响应取消的 checker：resume 后结果才到达——`guard !Task.isCancelled`
        // 必须挡下迟到结果，状态保持 idle 而非被覆写。
        let checker = GatedChecker(cancellationAware: false)
        let state = MedicalCatalogState(store: nil, checker: checker)
        state.check()
        await waitUntil("检查应进入 checking 悬停") { state.remoteState == .checking }
        state.cancelCheck()
        await checker.resume(MedicalCatalogCheckOutcome(state: .upToDate))
        await waitUntil("迟到结果不得覆写取消后的 idle") { state.remoteState == .idle }
    }

    func testCheck_whileChecking_isIgnored() async {
        let checker = GatedChecker()
        let state = MedicalCatalogState(store: nil, checker: checker)
        state.check()
        await waitUntil("检查应进入 checking 悬停") { state.remoteState == .checking }
        // 单飞：进行中重复 check 被守卫吞掉，状态仍 checking
        state.check()
        await waitUntil("单飞守卫应保持 checking") { state.remoteState == .checking }
        await checker.resume(MedicalCatalogCheckOutcome(state: .upToDate))
        await waitUntil("首个检查完成后应呈 upToDate") { state.remoteState == .upToDate }
    }

    // MARK: - 更新态

    func testApplyUpdate_noCandidate_isNoOp() async {
        let state = MedicalCatalogState(store: nil)
        state.applyUpdate()
        XCTAssertNil(state.updateError)
        XCTAssertFalse(state.isUpdating)
    }

    func testApplyUpdate_expiredCandidate_setsNotInstallable() async throws {
        let checker = StubChecker()
        let expired = try makeCandidate(expiresIn: -60)
        await checker.set(MedicalCatalogCheckOutcome(
            state: .updateAvailable(MedicalCatalogUpdateCandidate(
                catalogVersion: expired.catalogVersion, dataVersion: expired.dataVersion,
                schemaVersion: expired.schemaVersion, packageSize: expired.packageSize,
                expiresAt: expired.expiresAt)),
            candidate: expired))
        let (updater, destination) = try makeUpdater(fetcher: FailingFetcher(error: .downloadFailed))
        let state = MedicalCatalogState(store: nil, updater: updater, path: destination, checker: checker)
        state.check()
        await waitUntil("检查应发现更新") {
            if case .updateAvailable = state.remoteState { return true }
            return false
        }
        state.applyUpdate()
        await waitUntil("过期候选应呈 catalogNotInstallable") {
            state.updateError == .catalogNotInstallable
        }
        XCTAssertFalse(state.isUpdating)
    }

    func testApplyUpdate_fetchFailure_setsErrorAndKeepsCandidate() async throws {
        let checker = StubChecker()
        await checker.set(try updateAvailableOutcome())
        let (updater, destination) = try makeUpdater(fetcher: FailingFetcher(error: .downloadFailed))
        let state = MedicalCatalogState(store: nil, updater: updater, path: destination, checker: checker)
        state.check()
        await waitUntil("检查应发现更新") {
            if case .updateAvailable = state.remoteState { return true }
            return false
        }
        state.applyUpdate()
        await waitUntil("下载失败应呈 downloadFailed") { state.updateError == .downloadFailed }
        XCTAssertFalse(state.isUpdating)
        XCTAssertNil(state.updateProgress, "失败后进度应清空")
        // 候选保留：仍呈可安装更新（可重试）
        if case .updateAvailable = state.remoteState {} else {
            XCTFail("失败后候选应保留、状态仍呈可安装更新")
        }
    }

    func testApplyUpdate_cancelled_setsCancelledError() async throws {
        let checker = StubChecker()
        await checker.set(try updateAvailableOutcome())
        let (updater, destination) = try makeUpdater(fetcher: GatedFetcher())
        let state = MedicalCatalogState(store: nil, updater: updater, path: destination,
                                        checker: checker, opener: NoopOpener())
        state.check()
        await waitUntil("检查应发现更新") {
            if case .updateAvailable = state.remoteState { return true }
            return false
        }
        state.applyUpdate()
        await waitUntil("占位进度应立即可见（取消按钮可用）") {
            state.updateProgress != nil && state.canCancelUpdate
        }
        state.cancelUpdate()
        await waitUntil("取消应呈 cancelled") { state.updateError == .cancelled }
        XCTAssertNil(state.updateProgress)
        XCTAssertFalse(state.isUpdating)
    }

    // MARK: - 派生与初始化

    func testCanCancelUpdate_nilProgress_false() {
        let state = MedicalCatalogState(store: nil)
        XCTAssertFalse(state.canCancelUpdate)
    }

    func testInit_readsLocalStateFromPath() {
        let missing = URL(fileURLWithPath: "/nonexistent/medical-catalog.sqlite")
        let state = MedicalCatalogState(store: nil, path: missing)
        XCTAssertNil(state.localVersion, "目录缺失时本地版本应为 nil（目录功能降级纪律）")
        XCTAssertNil(state.localUpdatedAt)
        XCTAssertFalse(state.isAvailable, "无 store 即不可用")
    }
}
