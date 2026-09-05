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
    /// FR16.4：无信源阈值的读数计数——「范围不可用」是独立呈现态，
    /// 不静默跳过（审查修复：原 catch continue 让用户以为同步正常）
    private(set) var noRangeCount = 0
    private let reader: HealthKitReader
    private let guidelines: GuidelineStore
    private let scheduler: any ReminderScheduling
    private var lastAlertKey: [String: Date] = [:]

    init(reader: HealthKitReader, guidelines: GuidelineStore,
         scheduler: any ReminderScheduling) {
        self.reader = reader
        self.guidelines = guidelines
        self.scheduler = scheduler
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

    /// 同步并评估：读数 → evaluateAndRecord → 24h 去重 → 夜间静默 → L1+ 通知
    func sync(patientId: UUID) async {
        phase = .syncing
        noRangeCount = 0
        defer { if case .syncing = phase { phase = .done(count: 0) } }
        do {
            let readings = try await reader.recentReadings(within: 24)
            var elevated = 0
            for reading in readings {
                do {
                    let event = try await guidelines.evaluateAndRecord(
                        reading: reading, patientId: patientId, ruleId: "f16.healthkit")
                    guard event.severity != .L0 else { continue }
                    // FR16.2 同一事件 24 小时去重（按指标+级别；落库侧另有同日级别去重）
                    let key = "\(reading.metricKey)-\(event.severity.rawValue)"
                    if let last = lastAlertKey[key],
                       Date().timeIntervalSince(last) < 24 * 3600 { continue }
                    lastAlertKey[key] = Date()
                    // 夜间静默仅对 L0/L1 生效（L2/L3 不静默）
                    if event.severity == .L1 && isQuietHours { continue }
                    elevated += 1
                    // FR16.7 预警通知：正文只含类别，不含数值与病名
                    try await scheduler.schedule(
                        dose: "alert-\(event.id.uuidString)", at: Date().addingTimeInterval(5),
                        route: .alertHistory)
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

    private var isQuietHours: Bool {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: Date())
        return hour >= 22 || hour < 7
    }
}

/// SP-29 设备连接与数据权限：授权状态 + 手动同步 + 降级说明。
struct DeviceConnectionView: View {
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(F16DeviceState.self) private var deviceState
    @State private var authorized = false
    @State private var requested = false

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
                            requested = true
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
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if authorized {
                    Button(L10n.f16SyncNow) {
                        Task { await deviceState.sync(patientId: app.currentPatientId) }
                    }
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
            // 审查修复：进入即按系统真实授权状态回显（此前依赖会话内 requested
            // 标志，重进恒显示「请求授权」；FR16.1 不得重复索权/误导状态）
            authorized = await deviceState.currentAuthorization()
            if authorized { requested = true }
        }
    }
}
