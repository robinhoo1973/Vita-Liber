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
    private(set) var dashboard: HealthImportStore.Dashboard?
    private(set) var available = false
    private let syncService: HealthKitSyncService
    private let dataChange: AppDataChangeCenter
    /// 同步谓词由 phase 派生（单一事实源）——旧实现维护并行 syncRunning 布尔，
    /// 两条状态线与 phase 脱钩时会显示「同步中却可再次发起」或反之。
    var isSyncing: Bool { phase == .syncing }

    init(syncService: HealthKitSyncService, dataChange: AppDataChangeCenter) {
        self.syncService = syncService; self.dataChange = dataChange
    }

    func requestAuthorization(authEnabled: Bool) async -> Bool {
        guard authEnabled else { return false }
        do {
            _ = try await syncService.connect()
            connected = true
            await refreshDashboard()
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
        available = await syncService.isAvailable()
        await refreshDashboard()
        if !isSyncing, let latest = dashboard?.lastReport {
            report = latest; phase = .done(count: latest.persistedRows)
        }
        return connected
    }

    func sync(authEnabled: Bool = true, quietStart: String = "22:00", quietEnd: String = "07:00", maxRounds: Int = 20) async {
        guard authEnabled else { phase = .degraded(L10n.f16AuthDisabled); return }
        guard !isSyncing else { return }
        phase = .syncing
        do {
            // I2 审查修复：轮询与聚合下沉 HealthKitSyncService.performSyncAll
            // （服务语义不进视图状态对象），本层只消费一次终态报告。
            let total = try await syncService.performSyncAll(quietStart: quietStart, quietEnd: quietEnd, maxRounds: maxRounds)
            report = total
            if total.persistedRows > 0 { dataChange.metricsChanged() }
            dataChange.alertsChanged()
            // 审查修复（效率）：仪表盘六查询聚合只在轮次结束后算一次——
            // 旧实现每轮都全量重算（历史排空最长 20 轮 × 6 查询，纯浪费）。
            await refreshDashboard()
            if total.bindingId == dashboard?.bindingId, total.patientId == dashboard?.patientId {
                phase = .done(count: total.persistedRows)
            } else { report = dashboard?.lastReport; phase = .idle }
        } catch {
            // Earlier types may have committed before cancellation or a later fatal error.
            dataChange.metricsChanged()
            dataChange.alertsChanged()
            phase = .degraded(L10n.f16SyncFailed)
            await refreshDashboard()
        }
    }

    func refreshDashboard() async {
        do {
            let result = try await syncService.dashboard()
            guard !Task.isCancelled else { return }
            dashboard = result
            connected = result.connected
        } catch {
            dashboard = nil; connected = false
            phase = .degraded(L10n.f16SyncFailed)
        }
    }

    func updateAutomation() async { await syncService.startBackgroundObservation() }
    func importedRows(kind: HealthDataKind, before: HealthImportStore.ImportedRow?) async throws -> [HealthImportStore.ImportedRow] {
        try await syncService.importedRows(kind: kind, before: before)
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
                Toggle(L10n.authHealthLabel, isOn: preference(.authHealthRead))
                Toggle(L10n.healthAutoImport, isOn: preference(.healthAutoImport))
                    .disabled(!healthEnabled)
            } header: { Text(L10n.healthImportSettingsTitle) } footer: { Text(L10n.healthReadPermissionHint) }
            Section {
                if !healthEnabled {
                    Label(L10n.f16AuthDisabled, systemImage: "heart.slash")
                } else {
                    if deviceState.connected { Label(L10n.f16AuthGranted, systemImage: "link") }
                    Button(L10n.f16RequestAuth) {
                        Task {
                            if await deviceState.requestAuthorization(authEnabled: healthEnabled) { await sync() }
                        }
                    }
                    .disabled(!deviceState.available || deviceState.isSyncing)
                    .accessibilityIdentifier("SP-29.health.requestAuth")
                }
                Text(L10n.healthImportSubject(deviceState.dashboard?.ownerName ?? app.owner?.displayName ?? L10n.commonMember))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text(L10n.f16AuthSection) } footer: { Text(L10n.f16AuthHint) }

            Section {
                switch deviceState.phase {
                case .idle: EmptyView()
                case .syncing: ProgressView(L10n.f16Syncing)
                case .done(let count):
                    // report 存在时已同步行数由下方报告块渲染——这里只在
                    // 无报告兜底显示，避免「已同步 N 行」重复两行（round10 实测）。
                    if deviceState.report == nil {
                        Text(L10n.f16SyncedRows(count)).accessibilityIdentifier("SP-29.health.syncDone")
                    }
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let report = deviceState.report {
                    Text(L10n.f16SyncedRows(report.persistedRows))
                        .accessibilityIdentifier("SP-29.health.syncedRows")
                    // 「无可读变化」只在 HealthKit 未报告任何增删且无类型失败时成立；
                    // 变化已收到但落库 0 行（重放/仅索引更新）不是「无数据」。
                    if report.receivedChanges == 0 && report.failedTypes.isEmpty && !report.hasMore {
                        Text(L10n.healthNoReadableData).font(.caption)
                    }
                    if !report.failedTypes.isEmpty {
                        Label(L10n.healthImportPartial(report.failedTypes.count), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if report.hasMore { Text(L10n.healthImportMore).font(.caption) }
                    if report.preservedRows > 0 {
                        Text(L10n.healthPreservedAggregates(report.preservedRows)).font(.caption)
                    }
                    if report.deferredWindows > 0 {
                        Text(L10n.healthDeferredWindows(report.deferredWindows)).font(.caption)
                    }
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

            if let dashboard = deviceState.dashboard {
                Section {
                    ForEach(dashboard.types) { type in
                        NavigationLink {
                            HealthImportedDataView(kind: type.kind)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.metricName(type.kind.primaryMetric))
                                    Spacer()
                                    Text(L10n.healthImportedPointCount(type.rowCount)).foregroundStyle(.secondary)
                                }
                                if let latest = type.latestAt {
                                    Text(latest.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("SP-29.health.data.\(type.kind.rawValue)")
                    }
                } header: { Text(L10n.healthImportedData) } footer: { Text(L10n.healthImportedDataHint) }
            }

            if GuidelineSource.thresholdsAwaitMedicalReview {
                Section { Text(L10n.healthMedicalReviewPending).font(.caption) }
            }
            Section {
                NavigationLink(L10n.metricOverviewTitle) { MetricOverviewView() }
                NavigationLink(L10n.alert_historyEntry) { AlertHistoryView() }
            }
        }
        .navigationTitle(L10n.healthImportSettingsTitle)
        .task {
            await settings.load()
            _ = await deviceState.currentAuthorization()
        }
    }

    private var healthEnabled: Bool { settings.values[.authHealthRead] != "false" }
    private func preference(_ key: AppSettingKey) -> Binding<Bool> {
        Binding(get: { SettingsRules.resolved(settings.values[key], key: key) == "true" }, set: { value in
            if key == .authHealthRead && !value { deviceState.permissionRevoked() }
            Task {
                await settings.set(value ? "true" : "false", for: key)
                await deviceState.updateAutomation()
                await deviceState.refreshDashboard()
            }
        })
    }
    private func sync() async {
        await deviceState.sync(authEnabled: healthEnabled,
            quietStart: SettingsRules.resolved(settings.values[.quietHoursStart], key: .quietHoursStart),
            quietEnd: SettingsRules.resolved(settings.values[.quietHoursEnd], key: .quietHoursEnd))
    }
}

struct HealthImportedDataView: View {
    let kind: HealthDataKind
    @Environment(AppState.self) private var app
    @Environment(F16DeviceState.self) private var state
    @State private var rows: [HealthImportStore.ImportedRow] = []
    @State private var loading = false
    @State private var hasMore = true
    @State private var failed = false
    var body: some View {
        List {
            Section {
                let targetPatient = rows.first?.patientId ?? app.currentPatientId
                NavigationLink(value: AppRoute.trendChart(patientId: targetPatient, metric: kind.primaryMetric.rawValue)) {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title3)
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.healthViewTrendChart)
                                .font(.headline)
                            Text(L10n.healthViewTrendChartHint)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("SP-29.health.trendButton.\(kind.rawValue)")
            }

            Section(L10n.healthImportedRecordsSection) {
                if rows.isEmpty && !loading && !failed { Text(L10n.healthNoReadableData).foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    NavigationLink(value: AppRoute.trendChart(patientId: row.patientId, metric: row.metricKey)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MetricType(rawValue: row.metricKey).map { L10n.metricName($0) } ?? L10n.healthImportedData)
                            Text(row.value.formatted() + " " + row.unit).font(.headline)
                            Text(row.measuredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            Text(row.sourceName ?? L10n.healthAppleSource).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if loading { ProgressView() }
                else if hasMore { Button(failed ? L10n.retry : L10n.healthLoadMore) { Task { await load() } } }
                if failed { Text(L10n.f16SyncFailed).foregroundStyle(.orange) }
            }
        }
        .navigationTitle(L10n.metricName(kind.primaryMetric))
        .task { if rows.isEmpty { await load() } }
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await state.importedRows(kind: kind, before: rows.last)
            guard !Task.isCancelled else { return }
            rows.append(contentsOf: next); hasMore = next.count == 100; failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }
}
