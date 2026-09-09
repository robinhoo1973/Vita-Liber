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
    public struct SyncReport: Sendable, Equatable {
        public var elevated: Int = 0 // Scheduled, not delivered.
        public var noRangeCount: Int = 0
        public var persistedRows: Int = 0 // Includes updates and removals.
        /// Added + deleted references HealthKit reported this round. Zero with no failures means
        /// "nothing readable changed" — not "denied" and not "no history" (read authorization is opaque).
        public var receivedChanges: Int = 0
        public var rejectedSamples: Int = 0
        public var failedTypes: [HealthDataKind] = []
        public var hasMore = false
        public var notificationFailures = 0
        public var lastSyncAt: Date
    }

    private let provider: any HealthReadingProvider
    private let imports: HealthImportStore
    private let guidelines: GuidelineStore
    private let scheduler: any ReminderScheduling
    private var inFlight: Task<SyncReport, Error>?
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

    public func canSync() async throws -> Bool {
        guard await provider.isAvailable(), try await imports.isEnabled() else { return false }
        return try await imports.connection() != nil
    }

    public func cancelSync() { inFlight?.cancel() }

    public func performSync(quietStart: String, quietEnd: String) async throws -> SyncReport {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.run(quietStart: quietStart, quietEnd: quietEnd) }
        inFlight = task
        defer { inFlight = nil }
        let report = try await task.value
        latestReport = report
        return report
    }

    private func run(quietStart: String, quietEnd: String) async throws -> SyncReport {
        guard try await canSync(), let binding = try await imports.connection() else {
            throw HealthImportStore.ImportError.missingOwner
        }
        var report = SyncReport(lastSyncAt: Date())
        // Bounded work, not bounded history. The next call resumes each committed cursor.
        for kind in HealthDataKind.allCases {
            do {
                try Task.checkCancellation()
                guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                let previous = try await imports.anchor(binding: binding, kind: kind)
                let batch = try await provider.changes(for: kind, anchor: previous, limit: 500)
                report.receivedChanges += batch.added.count + batch.deleted.count
                let windows = try await imports.affectedWindows(binding: binding, kind: kind, batch: batch)
                var snapshots: [HealthWindowSnapshot] = []
                for window in windows {
                    // Revocation must stop reading at the next query boundary, not only at the commit.
                    try Task.checkCancellation()
                    guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                    snapshots.append(try await provider.snapshot(for: window, calendar: binding.calendar))
                }
                report.persistedRows += try await imports.commit(binding: binding, kind: kind,
                    previousAnchor: previous, batch: batch, snapshots: snapshots)
                report.rejectedSamples += snapshots.reduce(0) { $0 + $1.rejected }
                report.hasMore = report.hasMore || batch.hasMore
            } catch is CancellationError {
                throw CancellationError()
            } catch HealthImportStore.ImportError.disabled {
                throw HealthImportStore.ImportError.disabled
            } catch HealthImportStore.ImportError.bindingChanged {
                throw HealthImportStore.ImportError.bindingChanged
            } catch {
                report.failedTypes.append(kind) // Its cursor remains unchanged; other types can still import.
            }
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
            let enabled = try await canSync()
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
                work.cancel()
                Task { await Self.backgroundCancelHandler?() }
            }
        }
    }
    #endif
}
#endif
