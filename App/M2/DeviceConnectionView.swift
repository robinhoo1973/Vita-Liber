import SwiftUI
import Domain
import Infrastructure

@MainActor
@Observable
final class F16DeviceState {
    enum Phase: Equatable { case idle, syncing, done(count: Int), degraded(String) }
    private(set) var phase: Phase = .idle
    private(set) var connected = false
    private(set) var report: HealthKitSyncService.SyncReport?
    private let syncService: HealthKitSyncService
    private let dataChange: AppDataChangeCenter
    var isSyncing: Bool { phase == .syncing }

    init(syncService: HealthKitSyncService, dataChange: AppDataChangeCenter) {
        self.syncService = syncService; self.dataChange = dataChange
    }

    func requestAuthorization(authEnabled: Bool) async -> Bool {
        guard authEnabled else { return false }
        do {
            _ = try await syncService.connect()
            connected = true
            return true
        } catch {
            phase = .degraded(L10n.f16AuthFailed)
            return false
        }
    }

    /// FR16.1 撤销即时生效：应用内读取许可关闭时取消在途同步（服务侧在每个
    /// 窗口查询边界与提交事务内再次复核许可，本调用只是尽早停止读取）。
    func permissionRevoked() {
        Task { await syncService.cancelSync() }
        connected = false
        phase = .degraded(L10n.f16AuthDisabled)
    }

    func currentAuthorization() async -> Bool {
        do {
            connected = try await syncService.connection() != nil
            if let latest = await syncService.latestReport { report = latest; phase = .done(count: latest.elevated) }
            return connected
        } catch { phase = .degraded(L10n.f16AuthFailed); return false }
    }

    func sync(authEnabled: Bool = true, quietStart: String = "22:00", quietEnd: String = "07:00") async {
        guard authEnabled else { phase = .degraded(L10n.f16AuthDisabled); return }
        guard !isSyncing else { return }
        phase = .syncing
        do {
            let result = try await syncService.performSync(quietStart: quietStart, quietEnd: quietEnd)
            report = result
            if result.persistedRows > 0 { dataChange.metricsChanged() }
            dataChange.alertsChanged()
            phase = .done(count: result.elevated)
        } catch {
            // Earlier types may have committed before cancellation or a later fatal error.
            dataChange.metricsChanged()
            dataChange.alertsChanged()
            phase = .degraded(L10n.f16SyncFailed)
        }
    }
}

/// SP-29: connection configuration is separate from HealthKit's opaque read permissions.
struct DeviceConnectionView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(F16DeviceState.self) private var deviceState

    var body: some View {
        List {
            Section {
                if !healthEnabled {
                    Label(L10n.f16AuthDisabled, systemImage: "heart.slash")
                } else {
                    if deviceState.connected { Label(L10n.f16AuthGranted, systemImage: "link") }
                    Button(L10n.f16RequestAuth) {
                        Task { _ = await deviceState.requestAuthorization(authEnabled: healthEnabled) }
                    }
                    .accessibilityIdentifier("SP-29.health.requestAuth")
                }
                Text(L10n.healthImportSubject(app.owner?.displayName ?? L10n.commonMember))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text(L10n.f16AuthSection) } footer: { Text(L10n.f16AuthHint) }

            Section {
                switch deviceState.phase {
                case .idle: EmptyView()
                case .syncing: ProgressView(L10n.f16Syncing)
                case .done(let count):
                    Text(L10n.f16SyncDone(count)).accessibilityIdentifier("SP-29.health.syncDone")
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let report = deviceState.report {
                    Text(L10n.f16SyncedRows(report.persistedRows))
                        .accessibilityIdentifier("SP-29.health.syncedRows")
                    // 「无可读变化」只在 HealthKit 未报告任何增删且无类型失败时成立；
                    // 变化已收到但落库 0 行（重放/仅索引更新）不是「无数据」。
                    if report.receivedChanges == 0 && report.failedTypes.isEmpty {
                        Text(L10n.healthNoReadableData).font(.caption)
                    }
                    if !report.failedTypes.isEmpty {
                        Label(L10n.healthImportPartial(report.failedTypes.count), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if report.hasMore { Text(L10n.healthImportMore).font(.caption) }
                    if report.notificationFailures > 0 { Text(L10n.healthNotificationRetry).font(.caption) }
                    Text(L10n.f16LastSync(report.lastSyncAt.formatted(date: .numeric, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if deviceState.connected && healthEnabled {
                    Button(L10n.f16SyncNow) {
                        Task {
                            await deviceState.sync(authEnabled: healthEnabled,
                                quietStart: SettingsRules.resolved(settings.values[.quietHoursStart], key: .quietHoursStart),
                                quietEnd: SettingsRules.resolved(settings.values[.quietHoursEnd], key: .quietHoursEnd))
                        }
                    }
                    .disabled(deviceState.isSyncing)
                    .accessibilityIdentifier("SP-29.health.sync")
                }
            } header: { Text(L10n.f16SyncSection) } footer: { Text(L10n.f16SyncHint) }

            if GuidelineSource.thresholdsAwaitMedicalReview {
                Section { Text(L10n.healthMedicalReviewPending).font(.caption) }
            }
            Section {
                NavigationLink(L10n.metricOverviewTitle) { MetricOverviewView() }
                NavigationLink(L10n.alert_historyEntry) { AlertHistoryView() }
            }
        }
        .navigationTitle(L10n.f16Title)
        .task {
            await settings.load()
            _ = await deviceState.currentAuthorization()
        }
    }

    private var healthEnabled: Bool { settings.values[.authHealthRead] != "false" }
}
