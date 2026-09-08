import SwiftUI
import Domain
import Infrastructure
import Protocols   // ReminderScheduling（F16 预警通知调度端口）

// MARK: - F16 健康设备数据接入（SP-29 · FR16.1-16.10 交付半场）

/// F16 设备接入状态仓：只读授权 + 同步读数 → 信源库比对评估 →
/// 24h 去重 + 夜间静默（仅 L0/L1）→ L1+ 通知（正文只含类别，FR16.7）。
/// 授权被拒 → 整体降级为手动自测模式（FR16.1 边界），不在功能页反复弹索权。
@MainActor
@Observable
final class F16DeviceState {
    enum Phase: Equatable {
        case idle
        case syncing
        case done(count: Int)
        case degraded(String)
    }

    private(set) var phase: Phase = .idle
    /// 同步中判定（视图据以禁用按钮；sync 据以拒绝重入）
    var isSyncing: Bool { if case .syncing = phase { return true }; return false }
    /// FR16.4：无信源阈值的读数计数——「范围不可用」是独立呈现态，
    /// 不静默跳过（审查修复：原 catch continue 让用户以为同步正常）
    private(set) var noRangeCount = 0
    /// FR7.9（V3.86）：设备读数落库行数（入库流；与手输同表同趋势）
    private(set) var persistedRows = 0
    /// 上次成功同步时刻（FR16.1 V3.49 同步时间沟通契约：最近同步时间可见）
    private(set) var lastSyncAt: Date?
    private let reader: HealthKitReader
    private let guidelines: GuidelineStore
    private let scheduler: any ReminderScheduling
    /// V3.86 自动化同步服务（评估+入库双流主路径；未注入时（测试/预览）
    /// 回落下方既有评估回路——口径保持，双路径同语义）
    private let syncService: HealthKitSyncService?
    private let trends: TrendQueryStore?
    private let dataChange: AppDataChangeCenter?
    private var lastAlertKey: [String: Date] = [:]

    init(reader: HealthKitReader, guidelines: GuidelineStore,
         scheduler: any ReminderScheduling,
         syncService: HealthKitSyncService? = nil,
         trends: TrendQueryStore? = nil,
         dataChange: AppDataChangeCenter? = nil) {
        self.reader = reader
        self.guidelines = guidelines
        self.scheduler = scheduler
        self.syncService = syncService
        self.trends = trends
        self.dataChange = dataChange
    }

    /// FR16.1 只读授权请求（一次性；F14.1 authHealthRead 开关关闭时直接拒绝执行）
    /// 审查修复：请求后显式查授权状态——用户拒绝时 requestAuthorization
    /// 不抛错，原实现恒返 true，「拒绝→降级手测」路径（FR16.1）失效
    func requestAuthorization(authEnabled: Bool) async -> Bool {
        guard authEnabled else { return false }
        do {
            try await reader.requestAuthorization()
            if let status = await reader.authorizationStatus(), status == .sharingAuthorized {
                return true
            }
            phase = .degraded(L10n.f16AuthDenied)   // 拒绝/未定：呈现降级手测引导
            return false
        } catch {
            phase = .degraded(L10n.f16AuthFailed)
            return false
        }
    }

    /// 进入页面时恢复授权状态（审查修复：原 authorized 为会话级 @State，
    /// 离开再进入恒回「请求授权」——FR16.1 不得误导性呈现、不得重复索权）
    func currentAuthorization() async -> Bool {
        guard let status = await reader.authorizationStatus() else { return false }
        return status == .sharingAuthorized
    }

    /// 同步并评估：读数 → evaluateAndRecord → 24h 去重 → 夜间静默 → L1+ 通知。
    /// authEnabled：FR14.1 authHealthRead 开关实时值——关闭即拒绝执行
    /// （撤回即时生效，与 requestAuthorization 同一纪律）。
    /// quietStart/quietEnd：用户配置的安静时段（AppSettings 单一事实源，
    /// 缺省 22:00/07:00）——此前视图内硬编码 22-7，忽略用户设置。
    func sync(patientId: UUID, authEnabled: Bool = true,
              quietStart: String = "22:00", quietEnd: String = "07:00") async {
        guard authEnabled else {
            phase = .degraded(L10n.f16AuthDisabled)
            return
        }
        // 重入守卫：同步按钮在 syncing 期间仍可点——双击并发两次 sync
        // 会双写 evaluateAndRecord 并互相覆盖 phase/count，进行中直接忽略
        guard !isSyncing else { return }
        phase = .syncing
        noRangeCount = 0
        persistedRows = 0
        defer { if case .syncing = phase { phase = .done(count: 0) } }
        // FR7.9（V3.86）主路径：评估+入库双流经同步服务（观察者/后台/前台
        // 三路径共用同一实现——防止两处独立演化）；入库成功后按类型化
        // 版本计数触发趋势/指标宫格失效刷新（数据经 Store 观察 DB）
        if let syncService {
            do {
                let report = try await syncService.performSync(
                    patientId: patientId, quietStart: quietStart, quietEnd: quietEnd)
                noRangeCount = report.noRangeCount
                persistedRows = report.persistedRows
                lastSyncAt = report.lastSyncAt
                if report.persistedRows > 0 { dataChange?.metricsChanged() }
                phase = .done(count: report.elevated)
            } catch {
                phase = .degraded(L10n.f16SyncFailed)
            }
            return
        }
        // 兜底回路（未注入服务：测试/预览）——既有评估逻辑原样保留
        do {
            let readings = try await reader.recentReadings(within: 24)
            // 评审修正第二轮：跨重启 24h 去重需要送达清单——session 级 lastAlertKey
            // 重启即失忆，同一读数（去重键命中既有行、event.id 稳定）会重新弹窗。
            // delivered 守卫与稳定 event.id 配合：重启后同读数不再通知。
            let delivered = try await scheduler.delivered()
            var elevated = 0
            for reading in readings {
                do {
                    let event = try await guidelines.evaluateAndRecord(
                        reading: reading, patientId: patientId, ruleId: "f16.healthkit")
                    guard event.severity != .L0 else { continue }
                    // FR16.2 同一事件 24 小时去重（按成员+指标+级别；落库侧另有
                    // 同日级别去重）。此前键缺 patientId：成员 A 的 L1 命中会
                    // 抑制 24h 内成员 B 的同读数预警（BR-001 成员隔离）。
                    let key = "\(patientId.uuidString)-\(reading.metricKey)-\(event.severity.rawValue)"
                    if let last = lastAlertKey[key],
                       Date() < DayArithmetic.offset(days: 1, from: last) { continue }
                    let alertId = "alert-\(event.id.uuidString)"
                    guard !delivered.contains(alertId) else { continue }
                    // 夜间静默仅对 L0/L1 生效（L2/L3 不静默）。去重键必须在本
                    // 门之后写——此前先写键再静默丢弃：夜间被静默的 L1 在
                    // 24h 窗口内白天重同步时被键永久抑制，预警永远不送达。
                    if event.severity == .L1 && isQuietHours(start: quietStart, end: quietEnd) { continue }
                    // FR16.7 预警通知：正文只含类别，不含数值与病名
                    try await scheduler.schedule(
                        dose: alertId, at: Date().addingTimeInterval(5),
                        route: .alertHistory)
                    // 审查修复：去重键与计数必须在 schedule 成功之后写入——
                    // 此前先写键再调度，调度抛错被外层 catch 吞掉时，未送达的
                    // 预警已被计为「已送达」（elevated 计数含它）且 24h 去重键
                    // 抑制重试，用户收不到通知也看不到任何失败迹象。
                    lastAlertKey[key] = Date()
                    elevated += 1
                } catch GuidelineStore.StoreError.noApplicableRange {
                    // FR16.4「范围不可用」独立呈现态：计数并如实展示，不静默
                    noRangeCount += 1
                } catch {
                    continue
                }
            }
            phase = .done(count: elevated)
        } catch {
            phase = .degraded(L10n.f16SyncFailed)
        }
    }

    /// 安静时段判定（支持跨午夜区间：start > end 时按「晚 22 → 早 7」跨日）。
    /// start == end 是非法窗口（s >= e 分支恒真 → 全天静默，所有 L1 预警
    /// 无声丢失）——按失败开放处理（不静默），绝不静默吞掉全部预警。
    private func isQuietHours(start: String, end: String) -> Bool {
        guard let s = Self.hourOf(start), let e = Self.hourOf(end), s != e else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        return s < e ? (hour >= s && hour < e) : (hour >= s || hour < e)
    }

    /// "HH:mm" → 小时（仅小时粒度；AppSettings 缺省即整点）。
    /// 时/分双段校验：非法值（"22:99"/"garbage"）返回 nil → 判定失败开放
    private static func hourOf(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h
    }
}

/// SP-29 设备连接与数据权限：授权状态 + 手动同步 + 降级说明。
struct DeviceConnectionView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(F16DeviceState.self) private var deviceState
    @State private var authorized = false

    var body: some View {
        List {
            Section {
                // FR14.1 authHealthRead 开关联动（关闭即停）
                if settings.values[.authHealthRead] == "false" {
                    Label(L10n.f16AuthDisabled, systemImage: "heart.slash")
                        .foregroundStyle(.orange)
                } else if authorized {
                    Label(L10n.f16AuthGranted, systemImage: "checkmark.circle")
                        .foregroundStyle(Color("semantic-success", bundle: .main))
                } else {
                    Button(L10n.f16RequestAuth) {
                        Task {
                            // FR20.1 价值先行：说明卡（此处列表文案）+ 用户主动点击才触发系统权限框
                            authorized = await deviceState.requestAuthorization(authEnabled: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-29.health.requestAuth")
                }
            } header: {
                Text(L10n.f16AuthSection)
            } footer: {
                Text(L10n.f16AuthHint)
            }

            Section {
                switch deviceState.phase {
                case .idle:
                    EmptyView()
                case .syncing:
                    ProgressView(L10n.f16Syncing)
                case .done(let count):
                    Text(L10n.f16SyncDone(count))
                        .accessibilityIdentifier("SP-29.health.syncDone")
                    if deviceState.noRangeCount > 0 {
                        // FR16.4：范围不可用是独立呈现态——如实告知，不假装全量评估
                        Text(L10n.f16NoRange(deviceState.noRangeCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // FR7.9（V3.86）入库流呈现：设备读数与手输同趋势
                    if deviceState.persistedRows > 0 {
                        Text(L10n.f16SyncedRows(deviceState.persistedRows))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-29.health.syncedRows")
                    }
                    // FR16.1 V3.49 同步时间沟通契约：最近同步时间可见
                    if let last = deviceState.lastSyncAt {
                        Text(L10n.f16LastSync(Self.timeString(last)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                // FR14.1 authHealthRead 开关联动（关闭即停）：同步入口同样受
                // 开关门控——此前只隐藏请求区，撤回后系统授权仍可继续读 HealthKit。
                // 开关值求值一次；安静时段缺省经 SettingsRules 读 Domain 默认
                // （单一事实源），不再视图内硬编码第二份 22:00/07:00
                let healthAuthOn = settings.values[.authHealthRead] != "false"
                if authorized && healthAuthOn {
                    Button(L10n.f16SyncNow) {
                        Task {
                            await deviceState.sync(
                                patientId: app.currentPatientId,
                                authEnabled: healthAuthOn,
                                quietStart: SettingsRules.resolved(
                                    settings.values[.quietHoursStart], key: .quietHoursStart),
                                quietEnd: SettingsRules.resolved(
                                    settings.values[.quietHoursEnd], key: .quietHoursEnd))
                        }
                    }
                    // 同步进行中禁用——双击并发两次 sync 会双写评估并互覆状态
                    .disabled(deviceState.isSyncing)
                    .accessibilityIdentifier("SP-29.health.sync")
                }
            } header: {
                Text(L10n.f16SyncSection)
            } footer: {
                Text(L10n.f16SyncHint)
            }

            // FR16.9 过渡方案：预警历史入就诊准备包 + 系统急救卡引导联动
            Section {
                NavigationLink(L10n.prepTitle) {
                    VisitPrepView()
                }
                NavigationLink(L10n.alert_historyEntry) {
                    AlertHistoryView()
                }
            }
        }
        .navigationTitle(L10n.f16Title)
        .task {
            await settings.load()
            // 审查修复：进入即按系统真实授权状态回显（FR16.1 不得重复索权/误导状态）
            authorized = await deviceState.currentAuthorization()
        }
    }

    /// "HH:mm" 时刻呈现（上次同步时间）
    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
