import SwiftUI
import Domain
import Infrastructure
import Perception

@MainActor
@Perceptible
final class F16DeviceState {
    enum Phase: Equatable { case idle, syncing, done(count: Int), degraded(String) }
    private(set) var phase: Phase = .idle
    private(set) var connected = false
    private(set) var report: SyncReport?
    private(set) var dashboard: HealthImportDashboard?
    private(set) var available = false
    /// round2 H-N3：缺本人档案是独立可观察事实（Apple 健康只能导入到本人名下，BR-001），
    /// 不是「同步失败」——旧实现把 missingOwner 与真实读库失败同路降级，用户看到的是错误提示
    /// 而非「先建本人档案」的引导。
    private(set) var ownerMissing = false
    private let syncService: HealthKitSyncService
    private let dataChange: AppDataChangeCenter
    /// 同步谓词由 phase 派生（单一事实源）——旧实现维护并行 syncRunning 布尔，
    /// 两条状态线与 phase 脱钩时会显示「同步中却可再次发起」或反之。
    var isSyncing: Bool { phase == .syncing }

    init(syncService: HealthKitSyncService, dataChange: AppDataChangeCenter) {
        self.syncService = syncService; self.dataChange = dataChange
    }

    /// FR16.1 可见性三态（round2 H1/H3）：开关 > 设备能力 > 本人档案 > 绑定 > 已导入行。
    /// 「授权完成」不是输入——读取权限对 App 不可观察；判定纯函数在 Domain（HealthImportVisibility）。
    func pageState(enabled: Bool) -> HealthImportPageState {
        HealthImportVisibility.state(enabled: enabled, available: available, ownerPresent: !ownerMissing,
                                     connected: connected, importedRows: importedRowCount)
    }

    /// 仪表盘六类型已导入行合计（无仪表盘 = 0）
    private var importedRowCount: Int {
        guard let types = dashboard?.types else { return 0 }
        return types.reduce(0) { $0 + $1.rowCount }
    }

    func requestAuthorization(authEnabled: Bool) async -> Bool {
        guard authEnabled else { return false }
        do {
            _ = try await syncService.connect()
            connected = true
            ownerMissing = false
            await refreshDashboard()
            return true
        } catch HealthKitReader.ReaderError.unavailable {
            // H-N4：设备不提供 HealthKit——如实说明，不归入通用「授权失败」
            phase = .degraded(L10n.healthUnavailable)
            return false
        } catch HealthKitReader.ReaderError.requestIncomplete {
            // H3：系统流程未完成 ≠ 拒绝；完成也 ≠ 获准——只如实转述「未完成，请重试」
            phase = .degraded(L10n.healthRequestIncomplete)
            return false
        } catch HealthImportStore.ImportError.disabled {
            phase = .degraded(L10n.f16AuthDisabled)
            return false
        } catch HealthImportStore.ImportError.missingOwner {
            // H-N3：缺本人档案走独立三态文案（页面按 pageState 引导建档），phase 不降级
            ownerMissing = true
            phase = .idle
            return false
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
        } catch HealthImportStore.ImportError.disabled {
            // H3/H-N4：开关关闭是独立失败态（服务侧在每类边界复核许可，前几类可能已落库），
            // 呈现「已关闭」而非通用「同步失败」
            dataChange.metricsChanged()
            dataChange.alertsChanged()
            phase = .degraded(L10n.f16AuthDisabled)
            await refreshDashboard()
        } catch is CancellationError {
            // 2026-09-15 审查修复：取消不是同步失败。撤销许可/关闭开关（permissionRevoked）
            // 与外壳卸载都会取消在途同步，`performSyncAll` 里 `Task.checkCancellation()` 抛出的
            // CancellationError 此前落进通用 catch，把「已关闭」覆盖成「同步失败」（橙色告警）。
            // 撤销态由 permissionRevoked 先写入，这里不覆盖；也不调 refreshDashboard——
            // 撤销不删绑定行，dashboard() 会把 connected 读回 true。
            // 已提交的类型仍要发变更信号（与通用分支同口径）。
            dataChange.metricsChanged()
            dataChange.alertsChanged()
            if phase == .syncing { phase = .idle }
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
            ownerMissing = false
        } catch HealthImportStore.ImportError.missingOwner {
            // H-N3：缺本人档案不是「同步失败」——独立三态文案，phase 不降级
            dashboard = nil; connected = false; ownerMissing = true
        } catch {
            dashboard = nil; connected = false
            phase = .degraded(L10n.f16SyncFailed)
        }
    }

    func updateAutomation() async { await syncService.startBackgroundObservation() }
    func importedRows(kind: HealthDataKind, before: HealthImportRow?) async throws -> [HealthImportRow] {
        try await syncService.importedRows(kind: kind, before: before)
    }
}

/// SP-29: connection configuration is separate from HealthKit's opaque read permissions.
/// ADR-021：设置与展示的唯一宿主（iPhone/iPad 同一自适应视图，无平行页面）。
struct DeviceConnectionView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(F16DeviceState.self) private var deviceState
    @Environment(AppDataChangeCenter.self) private var dataChange

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    Toggle(L10n.authHealthLabel, isOn: preference(.authHealthRead))
                    Toggle(L10n.healthAutoImport, isOn: preference(.healthAutoImport))
                        .disabled(!healthEnabled)
                } header: { Text(L10n.healthImportSettingsTitle) } footer: { Text(L10n.healthReadPermissionHint) }
                Section {
                    // round2 H1/H3/H-N3/H-N4：授权区按可见性三态分支（关闭 > 不可用 > 缺本人 > 未连接/已连接）
                    switch pageState {
                    case .disabled:
                        Label(L10n.f16AuthDisabled, systemImage: "heart.slash")
                    case .unavailable:
                        // H-N4：设备不提供 HealthKit（iPad/模拟器）——如实说明，不再渲染永久禁用的请求按钮
                        Label(L10n.healthUnavailable, systemImage: "iphone.slash")
                            .accessibilityIdentifier("SP-29.health.unavailable")
                    case .ownerMissing:
                        // H-N3：Apple 健康只能导入到本人名下（BR-001）——引导建档，不是同步失败
                        Label(L10n.healthOwnerMissing, systemImage: "person.crop.circle.badge.exclamationmark")
                            .accessibilityIdentifier("SP-29.health.ownerMissing")
                    case .notConnected, .connectedEmpty, .visible:
                        if pageState != .notConnected { Label(L10n.f16AuthGranted, systemImage: "link") }
                        Button(L10n.f16RequestAuth) {
                            Task {
                                if await deviceState.requestAuthorization(authEnabled: healthEnabled) { await sync() }
                            }
                        }
                        .disabled(deviceState.isSyncing)
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
                        // token-only（审查修复）：语义令牌替代硬编码 .orange
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
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
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
                        }
                        if report.hasMore { Text(L10n.healthImportMore).font(.caption) }
                        // H-N1：排空进度——当前道（近一年 / 更早历史）与剩余统计窗口数（纯进度事实）
                        if report.hasMore, let remaining = report.remainingWindows, let lane = report.backfillLane {
                            Text(L10n.healthBackfillProgress(L10n.healthBackfillLane(lane), remaining)).font(.caption)
                                .accessibilityIdentifier("SP-29.health.backfillProgress")
                        }
                        // H-N2：<3 样本的小时桶计数提示，不静默丢弃（统计事实，非阈值判定）
                        if let sparse = report.sparseWindows, sparse > 0 {
                            Text(L10n.healthSparseWindows(sparse)).font(.caption)
                                .accessibilityIdentifier("SP-29.health.sparse")
                        }
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
                    // 手动同步只在「开关开启 ∧ 已连接」（= 展示区存在）时提供
                    if HealthImportVisibility.showsImportedData(pageState) {
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

                // round2 H1/H2：展示区只在「开关开启 ∧ 已连接」时存在（关闭即整体不可见）；
                // 详情页身份由 dashboard.patientId（= local_owner.self_patient_id）父级下传，
                // 趋势链接需「有数据 ∧ 身份已知」——绝不回落 currentPatientId（BR-001）
                if HealthImportVisibility.showsImportedData(pageState), let dashboard = deviceState.dashboard {
                    Section {
                        if pageState == .connectedEmpty {
                            // H-N5：空态独立文案（不是同步报告的「无可读变化」语句）
                            Text(L10n.healthImportedEmpty).foregroundStyle(.secondary)
                                .accessibilityIdentifier("SP-29.health.importedEmpty")
                        }
                        ForEach(dashboard.types) { type in
                            // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                            WithPerceptionTracking {
                                NavigationLink {
                                    // 趋势链接可用性由详情页按当前状态实时判定（2026-09-15 修复：
                                    // 不再由父级传快照）——此处只下传身份（BR-001）
                                    HealthImportedDataView(kind: type.kind, patientId: dashboard.patientId)
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
                        }
                    } header: { Text(L10n.healthImportedData) } footer: { Text(L10n.healthImportedDataHint) }
                }

                if GuidelineSource.thresholdsAwaitMedicalReview {
                    Section { Text(L10n.healthMedicalReviewPending).font(.caption) }
                }
                Section {
                    // §5.45 注册表纪律（审查修复）：两处原以闭包目的地直连视图，绕开
                    // AppRoute 注册表——通知深链/跨启动路径恢复无法寻址同一 SP。改类型安全路由。
                    NavigationLink(value: AppRoute.metricOverview) { Text(L10n.metricOverviewTitle) }
                    NavigationLink(value: AppRoute.alertHistory) { Text(L10n.alert_historyEntry) }
                }
            }
            .navigationTitle(L10n.healthImportSettingsTitle)
            // H3：观察 metricsVersion——后台/自动同步落库后仪表盘与三态同步刷新，不等用户重进页面
            .task(id: dataChange.metricsVersion) {
                await settings.load()
                _ = await deviceState.currentAuthorization()
            }
        }
    }

    /// 开关值经 SettingsRules 解析（缺省 = 键默认值；非法存值按关闭处理，不臆断为开启）
    private var healthEnabled: Bool {
        SettingsRules.resolved(settings.values[.authHealthRead], key: .authHealthRead) == "true"
    }
    /// 页面可见性三态（Domain 纯函数；设置区/授权区/报告区/展示区共用同一判定）
    private var pageState: HealthImportPageState { deviceState.pageState(enabled: healthEnabled) }
    private func preference(_ key: AppSettingKey) -> Binding<Bool> {
        Binding(get: { SettingsRules.resolved(settings.values[key], key: key) == "true" }, set: { value in
            if key == .authHealthRead && !value { deviceState.permissionRevoked() }
            Task {
                await settings.set(value ? "true" : "false", for: key)
                await deviceState.updateAutomation()
                // 效率修复（2026-09-15）：仪表盘六查询只在**可见性输入**变化时重算——
                // `HealthImportVisibility.state` 只吃读取许可（authHealthRead），
                // 「自动导入」开关不影响判定，此前每翻一次都白跑一轮 6 类 COUNT/MAX
                // 加绑定/档案读取；后台观察注册（updateAutomation）与开关确实相关，保留。
                if key == .authHealthRead { await deviceState.refreshDashboard() }
            }
        })
    }
    private func sync() async {
        await deviceState.sync(authEnabled: healthEnabled,
            quietStart: SettingsRules.resolved(settings.values[.quietHoursStart], key: .quietHoursStart),
            quietEnd: SettingsRules.resolved(settings.values[.quietHoursEnd], key: .quietHoursEnd))
    }
}

/// SP-29 已导入数据详情（ADR-021：同一自适应视图，宿主 DeviceConnectionView 内导航）。
struct HealthImportedDataView: View {
    let kind: HealthDataKind
    /// round2 H2：身份由父级下传 dashboard.patientId（= 本人绑定）——旧实现
    /// `rows.first?.patientId ?? app.currentPatientId` 在空列表时回落当前成员，
    /// 趋势深链可能挂到非本人名下（BR-001）。
    let patientId: UUID
    @Environment(AppSettingsStore.self) private var settings
    @Environment(F16DeviceState.self) private var state
    @Environment(AppDataChangeCenter.self) private var dataChange
    @State private var rows: [HealthImportRow] = []
    @State private var loading = false
    @State private var hasMore = true
    @State private var failed = false
    /// 重载代次：metricsVersion 触发的整页重载在途时，旧加载的迟到结果不得落槽/复位 loading
    @State private var generation = 0

    private var healthEnabled: Bool {
        SettingsRules.resolved(settings.values[.authHealthRead], key: .authHealthRead) == "true"
    }
    /// H1：与宿主同一判定——开关关闭或断连后（含已打开页/直达路由）呈现「已关闭」态，不残留数据
    private var gateOpen: Bool { HealthImportVisibility.showsImportedData(state.pageState(enabled: healthEnabled)) }
    /// 2026-09-15 审查修复：趋势链接可用性（有数据 ∧ 身份已知）改为**实时判定**——
    /// 旧实现是 push 时的快照（父级算一次传进来），后台同步落库后卡片仍停在停用态，
    /// 与同页 `gateOpen` 的实时判定口径不一致（页内两条链路口径打架）。
    private var trendAllowed: Bool {
        HealthImportVisibility.allowsTrendLink(state.pageState(enabled: healthEnabled), patientId: patientId)
    }

    /// 设备统计行（FR7.9：界面明确「单条读数/小时平均值/每日累计/睡眠时段内时长」+ 来源 +
    /// 极值/样本数）。与 SP-13 趋势行 `statisticsLine` 同款构成——同一数据两页不得两说
    /// （`.sample` 不重复标注，它就是默认语义）。
    private func statisticsLine(_ row: HealthImportRow) -> String? {
        var parts: [String] = []
        if let aggregation = row.aggregation, aggregation != .sample {
            parts.append(L10n.healthAggregation(aggregation))
        }
        if let low = row.valueMin, let high = row.valueMax, let count = row.sampleCount {
            parts.append(L10n.healthWindowStatistics(MedicalNumberFormat.quantity(low),
                                                     MedicalNumberFormat.quantity(high), count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if !gateOpen {
                    VLUnavailableView(L10n.f16AuthDisabled, systemImage: "heart.slash")
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("SP-29.health.data.disabled")
                } else {
                    List {
                        Section {
                            NavigationLink(value: AppRoute.trendChart(patientId: patientId, metric: kind.primaryMetric.rawValue)) {
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
                            .disabled(!trendAllowed)
                            .accessibilityIdentifier("SP-29.health.trendButton.\(kind.rawValue)")
                        }

                        Section(L10n.healthImportedRecordsSection) {
                            if rows.isEmpty && !loading && !failed {
                                // H-N5：空态独立文案；H-N2：心率空态附稀疏窗计数提示（统计事实）
                                Text(L10n.healthImportedEmpty).foregroundStyle(.secondary)
                                if kind == .heartRate, let sparse = state.report?.sparseWindows, sparse > 0 {
                                    Text(L10n.healthSparseWindows(sparse)).font(.caption)
                                        .accessibilityIdentifier("SP-29.health.sparse")
                                }
                            }
                            ForEach(rows) { row in
                                NavigationLink(value: AppRoute.trendChart(patientId: patientId, metric: row.metricKey)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(MetricType(rawValue: row.metricKey).map { L10n.metricName($0) } ?? L10n.healthImportedData)
                                        // 医学数值走唯一格式化出口（审查修复：原 Double.formatted()
                                        // 与趋势页 MedicalNumberFormat 两套数字规则，同一读数两处显示不同）
                                        Text(MedicalNumberFormat.quantity(row.value) + " " + row.unit).font(.headline)
                                        Text(row.measuredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                        // FR7.9：本行是单条读数还是统计窗口（小时均值/日累计/睡眠时长），
                                        // 窗口结束时间与极值/样本数——与 SP-13 趋势行同口径（statisticsLine）
                                        if let end = row.windowEnd, row.aggregation != .sample {
                                            Text(L10n.healthWindowEnd(end.formatted(date: .abbreviated, time: .shortened)))
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if let statistics = statisticsLine(row) {
                                            Text(statistics).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(row.sourceName ?? L10n.healthAppleSource).font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 4)
                                }
                            }
                            if loading { ProgressView() }
                            else if hasMore { Button(failed ? L10n.retry : L10n.healthLoadMore) { Task { await load() } } }
                            if failed {
                                Text(L10n.f16SyncFailed)
                                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.metricName(kind.primaryMetric))
            // H3：观察 metricsVersion——同步落库后整页重载（旧行清空、游标复位）
            .task(id: dataChange.metricsVersion) { await reload() }
        }
    }

    private func reload() async {
        generation &+= 1
        rows = []; hasMore = true; failed = false
        // 代次作废 = 在途加载不再是 loading 的归属者（它的 defer 因代次不符不会复位），
        // 必须在这里复位，否则新一圈 load() 被重入守卫挡下、loading 永远为真 → 列表卡在
        // ProgressView（审查自省：守卫与代次复位必须成对）
        loading = false
        await load()
    }

    private func load() async {
        // 2026-09-15 审查修复：并发重入守卫——两次同代次调用会在同一个 `rows.last` 游标上
        // 取回同一页并各追加一次，`ForEach(rows)` 出现重复 id（行点击错乱）。
        // `TimelineViewState.loadMore` 同款 `!isLoadingMore` 守卫。
        guard !loading else { return }
        let current = generation
        loading = true
        defer { if generation == current { loading = false } }
        do {
            let next = try await state.importedRows(kind: kind, before: rows.last)
            guard !Task.isCancelled, generation == current else { return }
            // 查询层已按本人绑定过滤；此处再按下传身份过滤是 BR-001 的最后一道守卫
            rows.append(contentsOf: next.filter { $0.patientId == patientId })
            hasMore = next.count == 100; failed = false
        } catch {
            if !Task.isCancelled, generation == current { failed = true }
        }
    }
}
