import SwiftUI
import Domain
import Infrastructure
import Perception

/// SP-29 健康 Tab 根（2026-09-15 业主实测修复批）：本页 = **Apple 健康数据展示面**。
///
/// 原实现是「健康概览占位 + 三个快捷卡 + 假搜索框」：趋势卡 action 是空闭包（点了没反应，
/// 业主第 4 项）、查记录/提醒只切到同名 Tab（与 Tab 栏重复，第 2/5 项）、搜索框与
/// `.searchable` 绑定同一个无人读取的 `@State`（死控件，同 HelpViews 已清除的死搜索条族），
/// 而真实数据面（六类已导入数据 + 详情页）早已存在于 `DeviceConnectionView`，只是藏在
/// 「我的 → 健康设备与数据」两跳之外（第 8 项：本页应当是 Apple 健康数据页）。
///
/// 本页直接承载数据面，三条纪律不变：
/// - **可见性判定走 Domain 纯函数** `HealthImportVisibility`（与 `DeviceConnectionView`
///   同一事实源；rule 4「业务判定不进视图」）——开关关闭即整体不可见，不残留占位与假 CTA；
/// - **单一内容视图**（ADR-021）：类型行复用 `HealthImportedDataView`，不新造第二份导入
///   数据渲染；授权/同步/报告等**写面**仍在 `DeviceConnectionView`（SP-29 唯一宿主），
///   本页只给入口；
/// - **token-only**：不再出现 `.blue/.orange/.green/.red` 硬编码色（改用语义令牌），
///   触点 ≥44pt，四态（空/加载/错误）由 Domain 状态机与各 Section 分支穷尽承载。
struct HealthTabView: View {
    @Environment(F16DeviceState.self) private var deviceState
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppDataChangeCenter.self) private var dataChange

    var body: some View {
        WithPerceptionTracking {
            List {
                dataSection
                entrySection
                if GuidelineSource.thresholdsAwaitMedicalReview {
                    Section { Text(L10n.healthMedicalReviewPending).font(.caption) }
                }
            }
            .navigationTitle(L10n.navHealth)
            // 2026-09-15 审查修复（效率）：设置装载与 metricsVersion 无关——原与指标
            // 版本共用同一 task，设备每次落库都白跑一轮 app_settings 全表读（磁盘往返
            // + 字典重建）。独立 task，页面出现时跑一次即可。
            .task { await settings.load() }
            // 与 SP-29 同款：同步落库后随指标版本刷新仪表盘与三态，不等用户重进页面
            .task(id: dataChange.metricsVersion) {
                _ = await deviceState.currentAuthorization()
            }
        }
    }

    // MARK: - 已导入的 Apple 健康数据

    /// 页面可见性六态（Domain 纯函数；与 SP-29 同一判定，本页不自行推导状态）
    private var pageState: HealthImportPageState { deviceState.pageState(enabled: healthEnabled) }

    /// 开关值经 SettingsRules 解析（缺省 = 键默认值；非法存值按关闭处理，不臆断为开启）
    private var healthEnabled: Bool {
        SettingsRules.resolved(settings.values[.authHealthRead], key: .authHealthRead) == "true"
    }

    @ViewBuilder
    private var dataSection: some View {
        // 加载态（CLAUDE.md：每屏四态齐备）——2026-09-15 审查修复（业主实测同族）：
        // `F16DeviceState.available` 初值 false 表示「**未探测**」而非「不支持」，
        // HealthImportPageState 无加载态，直接落 .unavailable 会在 HealthKit 可用的
        // iPhone 上先渲染「此设备不提供 Apple 健康数据，无法连接。」（假事实），
        // 探测（.task 内 currentAuthorization）回填后才翻到真实分支。
        if !deviceState.availabilityProbed {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("SP-29.health.home.loading")
            }
        } else {
            pageBody
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch pageState {
        case .disabled:
            Section {
                Label(L10n.f16AuthDisabled, systemImage: "heart.slash")
                    .accessibilityIdentifier("SP-29.health.disabled")
            }
        case .unavailable:
            // iPad/模拟器等不提供 HealthKit：如实说明，不给永久禁用的请求按钮
            Section {
                Label(L10n.healthUnavailable, systemImage: "iphone.slash")
                    .accessibilityIdentifier("SP-29.health.unavailable.home")
            }
        case .ownerMissing:
            // Apple 健康只能导入到本人名下（BR-001）：引导建档，不是同步失败
            Section {
                Label(L10n.healthOwnerMissing, systemImage: "person.crop.circle.badge.exclamationmark")
                    .accessibilityIdentifier("SP-29.health.ownerMissing.home")
            }
        case .notConnected:
            Section {
                VLUnavailableView {
                    Label(L10n.healthConnectDevice, systemImage: "heart.text.clipboard")
                } description: {
                    Text(L10n.f16AuthHint)
                } actions: {
                    // SP-29 是授权与同步的唯一宿主（ADR-021）：站内 push 到同一内容视图，
                    // 不切 Tab、不复制第二份授权 UI
                    NavigationLink(value: AppRoute.deviceConnection) {
                        Text(L10n.healthConnectButton)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-29.health.connect")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-29.health.notConnected")
            }
        case .connectedEmpty, .visible:
            importedSection
        }
    }

    /// 六类已导入数据（Domain 仪表盘投影）：行 = 类型名 + 数据点数 + 最近时间；
    /// 点开进详情页（复选全部记录 → 趋势图）。空态用独立文案（非同步报告语句）。
    private var importedSection: some View {
        Section {
            if pageState == .connectedEmpty {
                Text(L10n.healthImportedEmpty).foregroundStyle(.secondary)
                    // 2026-09-15 审查修复：本页是 SP-29 的**同级**宿主（Tab 根），
                    // 标识与 SP-29 展示区同名会让 XCUITest 命中两个元素（掩蔽族同族），
                    // 按本页 .home 前缀族归位。
                    .accessibilityIdentifier("SP-29.health.home.importedEmpty")
            }
            if let dashboard = deviceState.dashboard {
                // 2026-09-15 审查修复（业主实测同族）：空态下不得再列六行「0 个数据点」——
                // `dashboard()` 对每个 HealthDataKind **无条件**产出行，计数 0 的行既与
                // 上方「尚无已导入的数据」自相矛盾，也是六条点进去只有空列表的死入口。
                if pageState == .visible {
                    ForEach(dashboard.types.filter { $0.rowCount > 0 }) { type in
                        // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                        WithPerceptionTracking {
                            // 类型安全路由（§5.45）：身份由 dashboard.patientId（= 本人绑定）
                            // 经载荷下传——绝不回落当前成员（BR-001）；本页不再以闭包目的地
                            // 直连视图（那会让本页不在 healthPath 内，页内 value 推入与
                            // path 绑定栈不一致：点行无反应/目的地插到当前页下方）。
                            NavigationLink(value: AppRoute.healthImportedData(kind: type.kind,
                                                                              patientId: dashboard.patientId)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 10) {
                                        // 审查修复（指标图标）：健康数据行此前纯文本、
                                        // 指标间不可分辨——经 CardKindIcon.spec(metric:)
                                        // 单一出口渲染指标符号（与时间轴/SP-29 同符号）
                                        Image(systemName: CardKindIcon.spec(metric: type.kind.primaryMetric).symbol)
                                            .font(.title3)
                                            .foregroundStyle(CardKindIcon.tint(metric: type.kind.primaryMetric))
                                            .frame(width: 26)
                                        Text(L10n.metricName(type.kind.primaryMetric))
                                        Spacer()
                                        Text(L10n.healthImportedPointCount(type.rowCount))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let latest = type.latestAt {
                                        Text(latest.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    // 2026-09-19 审查修复（业主诉求：类别卡导入进度条）：同步进行中
                                    // 该类别卡显示确定性排空进度（基线 = 本轮同步首见剩余窗口数）。
                                    if deviceState.isSyncing,
                                       let fraction = deviceState.kindProgress[type.kind.rawValue] {
                                        ProgressView(value: fraction)
                                            .accessibilityIdentifier("SP-29.health.home.progress.\(type.kind.rawValue)")
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("SP-29.health.home.data.\(type.kind.rawValue)")
                        }
                    }
                }
                NavigationLink(value: AppRoute.deviceConnection) {
                    Label(L10n.f16Title, systemImage: "arrow.triangle.2.circlepath")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("SP-29.health.home.manage")
            }
        } header: { Text(L10n.healthImportedData) } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // 2026-09-15 审查修复（BR-001 / ui-ux §5.48 V3.64）：本页数据永远是**机主
                // 本人**的设备导入，与当前浏览成员无关——SP-29 连接区同款归属文案。
                // 缺此行时，切到家人再进本页会把本人读数误读成家人的（本页现已升为
                // Apple 健康数据的首要展示面，比两跳之外的 SP-29 更容易被这样读到）。
                Text(L10n.healthImportSubject(deviceState.dashboard?.ownerName ?? L10n.commonMember))
                    .accessibilityIdentifier("SP-29.health.home.importSubject")
                Text(L10n.healthImportedDataHint)
            }
        }
    }

    // MARK: - 检索与总览入口

    /// 真实落点（AppRoute 注册表）：搜索 = SP-20 全库搜索（本 Tab 自有路由，站内 push，
    /// 不切 Tab）；趋势 = SP-13 指标总览。两处都取代了原「查记录/趋势」死卡与假搜索框。
    private var entrySection: some View {
        Section {
            NavigationLink(value: AppRoute.globalSearch) {
                Label(L10n.healthSearchPrompt, systemImage: "magnifyingglass")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("SP-29.health.home.search")
            NavigationLink(value: AppRoute.metricOverview) {
                Label(L10n.metricOverviewTitle, systemImage: "waveform.path.ecg")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("SP-29.health.home.trends")
        }
    }
}
