import SwiftUI
import Domain
import Infrastructure
import Protocols
import Perception

/// F7 趋势状态（records 模块）：按指标加载指定序列 + 指标总览宫格最新点。
///
/// 审查修复（死代码清除）：原 TrendEntryView 是零实例化死视图——其专属的
/// 90 天血糖默认序列 `series`/`load()`、`lastOpenedSource`（写入无读者）、
/// `detailMetric`（写入无读者）、恒 nil 的 `conversionNote` 连同视图一并删除；
/// 趋势页真实挂载点是 TrendChartRouteView（.trendChart 路由），FR7.4 排除/
/// 恢复与 FR20.3 L2 须知已接线到该视图。
@MainActor
@Perceptible
final class TrendEntryState {
    /// §5.45 指标总览宫格最新点（V3.72）
    private(set) var latestMetrics: [TrendQueryStore.LatestMetric] = []
    /// internal：MetricEntryView 扩展（录入/单位记忆/排除接线）跨文件访问
    let store: TrendQueryStore
    /// FR7.4 排除/恢复审计（§5.29「动作记审计」；查询层把义务推给调用方，
    /// 调用方此前只接线了刷新——审计落空。未注入时（预览/测试）跳过）
    /// internal：与 store 同理，MetricEntryView 扩展（排除接线）跨文件访问；
    /// private 时跨文件 extension 不可见，裸名解析到 Darwin audit(2) 系统
    /// 调用函数指针（L1 34292282776 实证，Linux parse 无法暴露）
    let audit: (any AuditLogging)?
    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?
    private var detailRequest = UUID()
    private var latestRequest = UUID()
    private(set) var detailLoading = false
    private(set) var detailFailed = false
    init(store: TrendQueryStore, audit: (any AuditLogging)? = nil) {
        self.store = store
        self.audit = audit
    }

    /// §5.45 深链：按指标加载指定序列（SP-13 趋势详情路由）。
    /// 独立状态槽避免覆盖入口页的血糖默认序列。
    private(set) var detailSeries: TrendSeries?
    /// round2 H2：最近一次详情请求的查询身份（patientId, metric, origin, range）。
    /// 取代旧 loadingMetricKey 单键守卫——渲染层以 `series.identity == detailIdentity`
    /// 双校验，切成员/切指标/切窗口/切来源时晚到的旧身份结果不得落槽（张冠李戴同族）。
    private(set) var detailIdentity: TrendQueryIdentity?
    /// SP-13 未连接空态判定（ui-ux §5.45 V3.53）：成员名下是否存在任何
    /// origin='device' 读数——空态分流「未连接 Apple 健康」vs 通用无数据
    private(set) var hasDeviceSamples = false

    /// - Parameters:
    ///   - window: 时间窗（日历日，DayArithmetic 出口——切换日不漂移）
    ///   - origin: 来源过滤（nil = 全部；`.device` 由查询层强制本人绑定，BR-001）
    func loadDetail(patientId: UUID, metricKey: String, window: TrendTimeWindow = .year, origin: MetricOrigin? = nil) async {
        let request = UUID()
        detailRequest = request
        loadingPatientId = patientId
        detailLoading = true
        detailFailed = false
        defer { if detailRequest == request { detailLoading = false } }
        // 第八轮全仓审查修复（错误指标静默替代）：未知/拼错的 metricKey
        // 此前 ?? .glucose——深链打开错误的血糖图表冒充目标指标（张冠
        // 李戴，与 TimelineViews 已修同族）。注册表必须覆盖全部 metricKey，
        // 未知即拒绝：detailSeries/detailIdentity 置 nil → 路由页呈现不可用空态，
        // 绝不用真实指标顶替。
        guard let metric = MetricType(rawValue: metricKey) else {
            detailSeries = nil
            detailIdentity = nil
            return
        }
        let query = TrendQueryIdentity(patientId: patientId, metric: metric, origin: origin, range: window.interval())
        // 加载期间即写身份、清槽（审查修复）：切指标/切成员时旧指标的曲线
        // 不得在新指标名下继续渲染（路由页另有身份一致校验兜底）
        detailIdentity = query
        detailSeries = nil
        do {
            // 曲线与设备样本探测互不依赖——并行读取（此前串行两轮 store
            // 往返，探测只门控空态按钮却挡在曲线渲染之前）
            async let seriesTask = store.series(query)
            async let probeTask = store.hasDeviceSamples(patientId: patientId)
            let loaded = try await seriesTask
            // 审查修复：hasDeviceSamples 从未被写入（声明即弃用）——空态分流
            // 恒走「未连接 Apple 健康」+ [去连接] 引导，有设备数据但该指标
            // 无读数的用户被假引导（V3.53 契约空态分流失效）。探测失败不
            // 阻断曲线加载（按无设备数据渲染连接引导，与旧行为一致）。
            let hasDevice: Bool
            do { hasDevice = try await probeTask }
            catch { hasDevice = false }
            // H4 过期守卫：请求代次 + 查询身份双校验，晚到的旧身份结果丢弃
            guard detailRequest == request, !Task.isCancelled, loaded.identity == query else { return }
            detailSeries = loaded
            hasDeviceSamples = hasDevice
        } catch {
            // 过期请求（已切成员/切指标）的失败不触碰当前数据；当前请求
            // 失败才清槽（空态渲染，不残留旧曲线）。含 QueryError.deviceRequiresSelfBinding
            // （视图对非本人不提供设备过滤项，此处仅兜底）。
            guard detailRequest == request, !Task.isCancelled else { return }
            detailSeries = nil
            detailFailed = true
        }
    }
}

/// §5.45 路由目的地：指定成员+指标的独立趋势页（SP-13）。
/// FR7.2 点回原报告深链待 F7 录入批（Phase 6）接线——在无真实导航前
/// 不渲染「回原报告」按钮（onOpenSource 传 nil，杜绝点了没反应的假入口）。
struct TrendChartRouteView: View {
    let patientId: UUID
    let metricKey: String
    @Environment(AppState.self) private var app
    @Environment(TrendEntryState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(AppDataChangeCenter.self) private var dataChange
    /// round2 H4：时间窗四档（默认 1 年）与来源过滤（默认全部）——两者进入查询身份
    @State private var window: TrendTimeWindow = .year
    @State private var origin: MetricOrigin? = nil

    /// round2 H2 渲染前身份守卫：槽内序列必须携带与「当前请求身份」完全一致的身份，
    /// 且该身份指向本路由的成员/指标/来源——旧 metricType 单键校验挡不住同指标跨成员
    /// 或同指标不同来源过滤的串图。
    private var identityMatches: Bool {
        guard let expected = state.detailIdentity, let series = state.detailSeries else { return false }
        return series.identity == expected && expected.patientId == patientId
            && expected.metric.rawValue == metricKey && expected.origin == origin
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if state.detailLoading {
                    ProgressView()
                } else if identityMatches, let series = state.detailSeries,
                          !series.points.isEmpty || !series.excludedPoints.isEmpty {
                    // FR7.4 排除/恢复软删（此前唯一接线点在已删除的死视图
                    // TrendEntryView 上，App 内不可达）
                    TrendDetailView(
                        series: series,
                        window: window,
                        onToggleExcluded: { point in
                            Task { await state.toggleExcluded(point, patientId: patientId, metricKey: metricKey) }
                        })
                } else {
                    // SP-13 未连接空态（ui-ux §5.45 V3.53）：成员从未连接/同步
                    // 过 Apple 健康（无任何 origin='device' 读数）——分流为
                    // 「未连接」+ [去连接] 深链（SP-29），不渲染设备来源占位；
                    // 有设备数据但该指标空 → 下方通用空态
                    VLUnavailableView {
                        Label(L10n.trendTitle, systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(state.detailFailed ? L10n.f16SyncFailed : L10n.healthNoReadableData)
                    } actions: {
                        // 审查修复（V3.53 空态分流）：仅在成员名下无任何设备读数时
                        // 给 [去连接] 引导；已有设备数据但该指标空 = 通用无数据，
                        // 不给假连接引导
                        if !state.hasDeviceSamples {
                            Button(L10n.trendGoConnect) {
                                router.navigate(to: .deviceConnection)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("SP-13.trend.connectHealth")
                        }
                    }
                    // 容器标识必须配 children: .contain——否则 SwiftUI 把容器标识压到
                    // 每个子元素上，子按钮的 SP-13.trend.connectHealth 在 XCUITest 里
                    // 查不到（CI 34021989599 同族）。L0 掩蔽门禁看不到跨文件容器类型。
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SP-13.trend.detail.empty")
                }
            }
            // SP-13 时间窗 / 来源过滤控件：固定于顶部安全区（图表与列表在其下滚动）
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Picker(L10n.trendWindowLabel, selection: $window) {
                        ForEach(TrendTimeWindow.allCases) { item in
                            Text(L10n.trendWindow(item)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SP-13.trend.window")
                    Picker(L10n.trendFilterOrigin, selection: $origin) {
                        Text(L10n.trendOriginAll).tag(MetricOrigin?.none)
                        Text(L10n.trendOriginHospital).tag(MetricOrigin?.some(.hospital))
                        Text(L10n.trendSelfMeasured).tag(MetricOrigin?.some(.manual))
                        // BR-001：设备来源只可能归属本人绑定——非本人成员不提供设备过滤项
                        // （查询层对非本人显式设备过滤抛 deviceRequiresSelfBinding，此处不给入口）
                        if app.owner?.selfPatientId == patientId {
                            Text(L10n.trendOriginDevice).tag(MetricOrigin?.some(.device))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("SP-13.trend.originFilter")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-13.trend.controls")
            }
            // 身份四元任一变化（成员/指标/时间窗/来源）或指标投影版本变化即重载
            .task(id: "\(patientId.uuidString)-\(metricKey)-\(window.rawValue)-\(origin?.rawValue ?? "all")-\(dataChange.metricsVersion)") {
                await state.loadDetail(patientId: patientId, metricKey: metricKey, window: window, origin: origin)
            }
            // FR20.3 L2 场景首用须知（趋势图表页，一次性确认——此前挂在
            // 零实例化死视图上，须知从未展示）
            .sceneDisclosure(scene: "trends")
        }
    }
}

// MARK: - §5.45 指标总览宫格数据（V3.72）

extension TrendEntryState {
    /// 宫格最新点加载（try?-ok: 读取失败按空态渲染，不阻断总览页）
    func loadLatest(patientId: UUID) async {
        let request = UUID()
        latestRequest = request
        // 第六轮全仓审查修复（BR-001 残留）：与 loadDetail 同款
        // loadingPatientId 守卫——原实现无守卫，A 成员的慢查询在切换到
        // B 成员后返回并覆写 latestMetrics，A 的最新值挂在 B 名下展示
        loadingPatientId = patientId
        if let rows = try? await store.latestPerMetric(patientId: patientId) {   // try?-ok: 读取失败按空态渲染，不阻断总览页
            guard loadingPatientId == patientId, latestRequest == request, !Task.isCancelled else { return }
            // 只保留有趋势详情页的指标（MetricType 注册表覆盖）——设备入库
            // 的 steps/sleep_total 等无详情页键不产瓷片（否则 raw 键瓷片 +
            // 点入详情被 MetricType(rawValue:) 守卫拒载，L10n 单出口被破坏）
            latestMetrics = rows.filter { MetricType(rawValue: $0.metricKey) != nil }
        } else {
            // 审查修复：当前请求失败时清空——否则上一成员的宫格数据
            // 在新成员名下持续渲染（BR-001）；过期请求的失败不触碰新数据
            guard loadingPatientId == patientId, latestRequest == request, !Task.isCancelled else { return }
            latestMetrics = []
        }
    }

    /// 写路径刷新（不重盖 loadingPatientId 标记）：写后刷新若经 loadLatest
    /// 会把标记改回旧成员，导致新成员已在途的加载结果被守卫误弃、旧成员
    /// 数据挂到新成员名下（BR-001）。只在本请求仍是最新时应用结果。
    func refreshLatestIfCurrent(patientId: UUID) async {
        guard loadingPatientId == patientId else { return }
        if let rows = try? await store.latestPerMetric(patientId: patientId) {   // try?-ok: 读取失败按空态渲染，不阻断总览页
            guard loadingPatientId == patientId else { return }
            latestMetrics = rows.filter { MetricType(rawValue: $0.metricKey) != nil }   // 与 loadLatest 同款过滤
        }
    }

    /// 写后详情刷新（排除/恢复动作；不重盖身份，同 refreshLatestIfCurrent 纪律）。
    /// 沿用当前 detailIdentity 整体（含原时间范围与来源过滤）重查，只在身份仍是当前时落槽。
    func refreshDetailIfCurrent(patientId: UUID, metricKey: String) async {
        guard let query = detailIdentity, query.patientId == patientId,
              query.metric.rawValue == metricKey else { return }
        do {
            let loaded = try await store.series(query)
            guard detailIdentity == query, loaded.identity == query else { return }
            detailSeries = loaded
        } catch {
            // 刷新失败保留原状（软删失败无数据损失；错误经日志）
        }
    }
}
