#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols
#if os(iOS)
import BackgroundTasks
import HealthKit
#endif

/// One coordinator for foreground, manual and background import. Actor reentrancy is explicitly coalesced.
public actor HealthKitSyncService {
    public struct SyncReport: Sendable, Equatable, Codable {
        public var elevated: Int = 0 // Scheduled, not delivered.
        public var noRangeCount: Int = 0
        public var persistedRows: Int = 0 // Includes updates and removals.
        public var preservedRows: Int = 0 // Unowned recovered facts left unchanged.
        public var deferredWindows: Int = 0 // Incomplete visibility; pending work is retained.
        /// Added + deleted references HealthKit reported this round. Zero with no failures means
        /// "nothing readable changed" — not "denied" and not "no history" (read authorization is opaque).
        public var receivedChanges: Int = 0
        public var rejectedSamples: Int = 0
        public var failedTypes: [HealthDataKind] = []
        public var hasMore = false
        public var notificationFailures = 0
        public var lastSyncAt: Date
        public var bindingId: UUID? = nil
        public var patientId: UUID? = nil
    }

    private let provider: any HealthReadingProvider
    private let imports: HealthImportStore
    private let guidelines: GuidelineStore
    private let scheduler: any ReminderScheduling
    private static let windowsPerRound = 32
    private var inFlight: Task<SyncReport, Error>?
    private var inFlightID: UUID?
    public private(set) var latestReport: SyncReport?

    public init(provider: any HealthReadingProvider, imports: HealthImportStore,
                guidelines: GuidelineStore, scheduler: any ReminderScheduling) {
        self.provider = provider; self.imports = imports
        self.guidelines = guidelines; self.scheduler = scheduler
    }

    public func connect() async throws -> HealthImportStore.Binding {
        guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
        try await provider.requestAuthorization()
        // A completed request says nothing about individual read permissions.
        let binding = try await imports.connect()
        #if os(iOS)
        await startBackgroundObservation()
        _ = scheduleBackgroundRefresh()
        #endif
        return binding
    }

    public func connection() async throws -> HealthImportStore.Binding? { try await imports.connection() }
    public func dashboard() async throws -> HealthImportStore.Dashboard { try await imports.dashboard() }
    public func importedRows(kind: HealthDataKind, before: HealthImportStore.ImportedRow? = nil) async throws -> [HealthImportStore.ImportedRow] {
        try await imports.importedRows(kind: kind, before: before)
    }
    public func isAvailable() async -> Bool { await provider.isAvailable() }
    public func canAutomaticallySync() async throws -> Bool {
        guard try await imports.automaticImportEnabled() else { return false }
        return try await canSync()
    }

    public func canSync() async throws -> Bool {
        guard await provider.isAvailable(), try await imports.isEnabled() else { return false }
        return try await imports.connection() != nil
    }

    public func cancelSync() { inFlight?.cancel() }

    public func performSync(quietStart: String, quietEnd: String) async throws -> SyncReport {
        try Task.checkCancellation()
        if let inFlight {
            let report = try await inFlight.value
            try Task.checkCancellation()
            return report
        }
        let id = UUID()
        inFlightID = id
        let task = Task { try await self.runAndRecord(id: id, quietStart: quietStart, quietEnd: quietEnd) }
        inFlight = task
        // Only the creator owns cancellation of shared work. Registration also closes the startup race.
        let report = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let report = try await task.value
            try Task.checkCancellation()
            return report
        } onCancel: {
            task.cancel()
        }
        return report
    }

    /// 合并调用者共享整个轮次，含状态落盘；完成后才释放flight，避免反复加入已完成任务。
    private func runAndRecord(id: UUID, quietStart: String, quietEnd: String) async throws -> SyncReport {
        defer { if inFlightID == id { inFlight = nil; inFlightID = nil } }
        let report = try await run(quietStart: quietStart, quietEnd: quietEnd)
        try Task.checkCancellation()
        try await imports.saveReport(report)
        latestReport = report
        return report
    }

    private func run(quietStart: String, quietEnd: String) async throws -> SyncReport {
        try Task.checkCancellation()
        guard try await canSync(), let binding = try await imports.connection() else {
            throw HealthImportStore.ImportError.missingOwner
        }
        var report = SyncReport(lastSyncAt: Date(), bindingId: binding.id, patientId: binding.patientId)
        // Fetch one page per type/round. Drained work resumes by window without losing the old checkpoint.
        for kind in HealthDataKind.allCases {
            var hasPending = false
            do {
                try Task.checkCancellation()
                guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                let existing = try await imports.pendingBatch(binding: binding, kind: kind)
                hasPending = existing != nil
                let previous: Data?
                if let existing { previous = existing.batch.anchor }
                else { previous = try await imports.anchor(binding: binding, kind: kind) }
                // Even a previously drained but incomplete batch can discover later tombstones on this page.
                let page = try await provider.changes(for: kind, anchor: previous, limit: 500)
                report.receivedChanges += page.added.count + page.deleted.count
                let pending = try await imports.stage(binding: binding, kind: kind, previousAnchor: previous, page: page)
                hasPending = true
                do {
                    var remaining = try await imports.affectedWindows(binding: binding, kind: kind, batch: pending.batch)
                        .filter { !pending.completedWindows.contains($0) }
                    if let after = pending.reconcileAfter {
                        remaining = remaining.filter { $0.start > after } + remaining.filter { $0.start <= after }
                    }
                    let attempted = Array(remaining.prefix(Self.windowsPerRound))
                    var snapshots: [HealthWindowSnapshot] = []
                    var queryFailed = false
                    for window in attempted {
                        try Task.checkCancellation()
                        guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                        do { snapshots.append(try await provider.snapshot(for: window, calendar: binding.calendar)) }
                        catch is CancellationError { throw CancellationError() }
                        catch { queryFailed = true }
                    }
                    let committed = try await imports.commit(binding: binding, kind: kind, pending: pending,
                        snapshots: snapshots, attemptedWindows: attempted)
                    report.persistedRows += committed.persistedRows
                    report.preservedRows += committed.preservedRows
                    report.deferredWindows += committed.deferredWindows
                    report.rejectedSamples += snapshots.reduce(0) { $0 + $1.rejected }
                    hasPending = committed.hasMore
                    if queryFailed || committed.deferredWindows > 0 { report.failedTypes.append(kind) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch HealthImportStore.ImportError.disabled {
                throw HealthImportStore.ImportError.disabled
            } catch HealthImportStore.ImportError.bindingChanged {
                throw HealthImportStore.ImportError.bindingChanged
            } catch {
                report.failedTypes.append(kind) // Its staged work and old checkpoint survive; other types can progress.
            }
            report.hasMore = report.hasMore || hasPending
            // 审查修复（共享轮次取消不丢进度）：每类页处理完即落盘报告——
            // 创建方被取消（视图拆除 / permissionRevoked → cancelSync）时共享
            // 轮次随之中止，旧实现只在全部完成后经 runAndRecord 落盘，取消
            // 路径跳过 saveReport，已提交行数/最后同步时间永不更新（仪表盘
            // 滞后、失败提示却照常——两处状态分裂）。逐类落盘为有界小写
            // （hk_import_status 单行 upsert），最终保存保持幂等。
            do { try await imports.saveReport(report); latestReport = report }
            catch { /* 落盘失败不阻断本轮其余类型；runAndRecord 终态仍会重试 */ }
        }

        // Retry pending qualified events even when there are no new HealthKit samples.
        // The medical review gate also prevents dispatch of old unreviewed engineering examples.
        if !GuidelineSource.thresholdsAwaitMedicalReview {
            do {
                let pending = try await guidelines.history(patientId: binding.patientId,
                    qualifiedOnly: true, pendingOnly: true, activeOnly: true)
                for event in pending {
                    try Task.checkCancellation()
                    guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                    if event.severity == .L1 && QuietHoursRules.isActive(start: quietStart, end: quietEnd) { continue }
                    do {
                        let when = Date().addingTimeInterval(5)
                        try await scheduler.schedule(dose: "alert-\(event.id.uuidString)", at: when,
                            route: .alertEvidence(patientId: binding.patientId, eventId: event.id, severity: event.severity))
                        try await guidelines.markScheduled(id: event.id, patientId: binding.patientId, at: when)
                        report.elevated += 1
                    } catch { report.notificationFailures += 1 }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.notificationFailures += 1 }
        }
        report.lastSyncAt = Date()
        return report
    }

    #if os(iOS)
    public static let bgTaskIdentifier = "com.vitaliber.healthkit-sync"
    public private(set) var backgroundRegistrationFailed = false
    nonisolated(unsafe) public static var backgroundSyncHandler: (@Sendable () async -> Bool)?
    nonisolated(unsafe) public static var backgroundCancelHandler: (@Sendable () async -> Void)?

    public func startBackgroundObservation() async {
        guard let reader = provider as? HealthKitReader else { return }
        do {
            let enabled = try await canAutomaticallySync()
            backgroundRegistrationFailed = !(await reader.observeChanges(handler: {
                (await Self.backgroundSyncHandler?()) ?? false
            }, enableDelivery: enabled))
        } catch { backgroundRegistrationFailed = true }
    }

    @discardableResult
    public func scheduleBackgroundRefresh() -> Bool {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request); return true }
        catch { backgroundRegistrationFailed = true; return false }
    }

    public nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task {
                let success = (await Self.backgroundSyncHandler?()) ?? false
                refresh.setTaskCompleted(success: success && !Task.isCancelled)
            }
            refresh.expirationHandler = {
                // Do not cancel a foreground owner's flight merely because this callback joined it.
                work.cancel()
            }
        }
    }
    #endif
}
#endif
