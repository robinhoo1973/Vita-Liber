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
    /// 最近一次**宫格**请求的成员（BR-001 成员隔离：只允许最新请求写回状态）。
    /// 详情轨不写本字段：两条轨共用一个成员标记时，趋势详情页为成员甲挂起会把
    /// 宫格为成员乙的在途加载判为过期而静默丢弃（宫格停在上一成员或空态，无错误
    /// 也无重试）；详情轨的隔离由 `detailRequest` 代次 + `detailIdentity` 身份双校验独立承担。
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
    /// 睡眠整合槽（FR7.11，业主 2026-09-16 第 3 项）：与 `detailSeries` **互斥**
    /// （同一页要么点族要么睡眠族，载入时清另一槽），身份凭据同为 `detailIdentity`。
    private(set) var sleepSeries: SleepTrendSeries?
    /// round2 H2：最近一次详情请求的查询身份（patientId, metric, origin, range）。
    /// 渲染层以 `series.identity == detailIdentity` 双校验，切成员/切指标/切窗口/
    /// 切周期时晚到的旧身份结果不得落槽（张冠李戴同族）。
    private(set) var detailIdentity: TrendQueryIdentity?
    /// SP-13 未连接空态判定（ui-ux §5.45 V3.53）：成员名下是否存在任何
    /// origin='device' 读数——空态分流「未连接 Apple 健康」vs 通用无数据
    private(set) var hasDeviceSamples = false
    /// 任意窗口最近读数（诊断性空态，2026-09-16 业主实测）：周期空时告知「数据在更早」，
    /// 并可一键跳到该读数所在周期。口径 = `latestMeasuredAt`（excluded = 0）。
    private(set) var latestAnyDate: Date?

    /// - Parameters:
    ///   - window: 时间窗（日历日，DayArithmetic 出口——切换日不漂移）
    ///   - periodEnd: 周期末（业主 2026-09-16 第 4 项翻页；nil = 自动锚定**今天**）
    ///   - origin: 来源过滤（nil = 全部；`.device` 由查询层强制本人绑定，BR-001）
    func loadDetail(patientId: UUID, metricKey: String, window: TrendTimeWindow = .year,
                    periodEnd: Date? = nil, origin: MetricOrigin? = nil) async {
        let request = UUID()
        detailRequest = request
        detailLoading = true
        detailFailed = false
        // 诊断态按次重置：不重置时上一成员/上一周期的诊断会挂到本次空态上
        // （B 成员读写失败 → 页面显示甲成员的「最近读数」）
        latestAnyDate = nil
        hasDeviceSamples = false
        defer { if detailRequest == request { detailLoading = false } }
        // 第八轮全仓审查修复（错误指标静默替代）：未知/拼错的 metricKey
        // 此前 ?? .glucose——深链打开错误的血糖图表冒充目标指标（张冠
        // 李戴，与 TimelineViews 已修同族）。注册表必须覆盖全部 metricKey，
        // 未知即拒绝：detailSeries/detailIdentity 置 nil → 路由页呈现不可用空态，
        // 绝不用真实指标顶替。
        guard let metric = MetricType(rawValue: metricKey) else {
            detailSeries = nil
            sleepSeries = nil
            detailIdentity = nil
            return
        }
        // 周期锚点 = **今天**（业主 2026-09-16 第 1 项：「数据显示的起点应该是当前日期，
        // 而不是最近的那条记录」）。为什么不能锚在最新读数：读数天然稀疏（设备投影按
        // 窗口由旧到新物化、医院读数成批且常常是几个月前），锚在最新读数时「7 天」
        // 显示的是半年前的 7 天——页面没有「今天」这个参照点，用户读不出「距上次读数
        // 多久」，且 `›` 恒不可用（自动锚定态 = canPageForward false），今天**不在可达
        // 状态空间里**（2026-09-16 评审实证）。周期为空是合法状态：空态给事实
        // （「最近读数：X」）+ 出口（[跳到最近读数所在周期]）。
        let range = window.period(endingAt: periodEnd ?? Date())
        // 身份/槽位写在同一代次守卫内（2026-09-16 评审修复）：锚点与序列读取之间
        // 隔了 await（同一 `Task` 之外还有并发请求），未守卫的写会让晚到的旧请求
        // 覆写身份 → 渲染守卫对已加载的序列恒 false → 空态且无错误（静默空白页）。
        let query = TrendQueryIdentity(patientId: patientId, metric: metric, origin: origin, range: range)
        guard detailRequest == request else { return }
        detailIdentity = query
        detailSeries = nil
        sleepSeries = nil
        // 三查询并行：曲线（点族或睡眠族）/ 设备探测 / 最近读数诊断互不依赖，
        // 且锚点不再取自诊断查询——诊断自此不在曲线关键路径上（此前每次翻页
        // 串行多付一趟「ownerPatient + MAX(measured_at)」）。
        async let probeTask = store.hasDeviceSamples(patientId: patientId)
        // 诊断口径：睡眠族按**总量键**（总时长存在 ⟺ 该夜有入睡段；逐阶段键会把
        // 「只有核心睡眠的夜」误报成「本指标无读数」，出口按钮随之落空）
        let diagnosticMetric: MetricType = metric.isSleep ? .sleepTotal : metric
        async let latestTask = store.latestMeasuredAt(patientId: patientId, metric: diagnosticMetric, origin: origin)
        var loaded: TrendSeries?
        var loadedSleep: SleepTrendSeries?
        var seriesFailed = false
        do {
            if metric.isSleep {
                loadedSleep = try await store.sleepSeries(query)
            } else {
                loaded = try await store.series(query)
            }
        } catch {
            seriesFailed = true
        }
        var hasDevice = false
        do { hasDevice = try await probeTask } catch { hasDevice = false }
        var latest: Date?
        do { latest = try await latestTask } catch { latest = nil }
        // H4 过期守卫：请求代次 + 查询身份双校验，晚到的旧身份结果丢弃
        // （诊断态同样只在本次请求仍是最新时落槽——否则旧请求的失败会挂到新页面上）
        guard detailRequest == request, !Task.isCancelled, detailIdentity == query else { return }
        latestAnyDate = latest
        if seriesFailed {
            detailSeries = nil
            sleepSeries = nil
            detailFailed = true
        } else if let loadedSleep, loadedSleep.identity == query {
            sleepSeries = loadedSleep
            hasDeviceSamples = hasDevice
        } else if let loaded, loaded.identity == query {
            detailSeries = loaded
            hasDeviceSamples = hasDevice
        } else {
            detailFailed = true
        }
    }

    /// F19 事实播报专用读取（VoiceSessionView「最近血糖」）：直接走查询层，
    /// **不写任何 detail 槽位**（原实现调用 loadDetail 覆写趋势页共用的
    /// detailSeries/detailIdentity——语音一问就把正在看的趋势页清成空态，
    /// 且回读时不做身份校验，快速连问会播报上一请求甚至另一成员的序列）。
    /// 2026-09-16 第 1 项批：改 `latestPoints`（`ORDER BY measured_at DESC LIMIT ?`
    /// 单条索引语句、N 行）——原实现先解析锚点再取整个年窗，为了 3 个值取回
    /// 最多 8760 行；且「最近」被窗口绑死（读数早于窗口时播报「暂无记录」）。
    func recentValues(patientId: UUID, metric: MetricType, limit: Int = 3) async -> [TrendPoint] {
        let points = (try? await store.latestPoints(patientId: patientId, metric: metric, limit: limit)) ?? []   // try?-ok: 播报失败按「暂无记录」呈现（与既有行为一致）
        return points
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
    /// round2 H4：时间窗四档（默认 1 年）——周期**长度**（进入查询身份）
    @State private var window: TrendTimeWindow = .year
    /// 周期末（业主 2026-09-16 第 4 项翻页）：nil = 自动锚定**今天**（第 1 项），
    /// 非 nil = 用户翻页/跳到最近读数周期后的显式周期末。换窗只改长度、不动周期末
    /// （同一段数据不跳走）。成员/指标切换时重置（见 `.task`）——否则甲的翻页游标
    /// 会被乙的页面继承。
    @State private var periodEnd: Date?
    /// 已装载的路由键（成员+指标）：变化即重置游标与长度档
    @State private var loadedRouteKey: String?

    /// 本页指标类型（未知键 = nil，页面呈不可用空态）
    private var metricType: MetricType? { MetricType(rawValue: metricKey) }
    /// 本页成员是否本人绑定（BR-001：设备读数只可能归属本人；非本人不得出现设备引导）
    private var isSelf: Bool { app.owner?.selfPatientId == patientId }
    /// 路由键：成员/指标变化即重置视图级游标状态（@State 不随 let 输入变化重建）
    private var routeKey: String { "\(patientId.uuidString)-\(metricKey)" }
    private var taskID: String {
        "\(routeKey)-\(window.rawValue)-\(periodEnd?.timeIntervalSince1970 ?? -1)-\(dataChange.metricsVersion)"
    }

    /// 本页当前请求的查询身份（只在与本页成员/指标一致时采用槽内身份——
    /// 切成员/切指标的过渡帧不得显示别人/别的指标的周期标签）。
    /// 周期标签与诊断行同源本值，不再各读一次共享槽。
    private var currentIdentity: TrendQueryIdentity? {
        guard let identity = state.detailIdentity,
              identity.patientId == patientId, identity.metric.rawValue == metricKey else { return nil }
        return identity
    }

    /// 本页请求的周期末：用户翻页值优先，否则取身份里的 range.end
    /// （**不重算 `Date()`**：状态层锚定时取的是那一瞬的 `Date()`，渲染层再取一次
    /// 会差几微秒，已加载的曲线会被判成过期 → 空白页；身份里的 range 就是权威值）。
    private var requestedEnd: Date { periodEnd ?? currentIdentity?.range.end ?? Date() }

    /// round2 H2 渲染前身份守卫：槽内序列必须携带与「当前请求身份」完全一致的身份，
    /// 该身份指向本路由的成员/指标，且**周期就是本页当前请求的那一段**。
    /// 为什么连周期一起校验：`TrendEntryState` 是全 App 单实例（其它调用方也写同一
    /// 槽位），只校验成员/指标时，一个「窗口 = 1 年」的序列可以挂在「7 天」档位下
    /// 渲染——可见域长度（60.5 万秒）对 1 年域（3153 万秒），图表停在最旧一段，
    /// 观感正是「数据没有渲染」；同长度但不同周期（上周挂在本周名下）同属此类。
    /// 周期由 `requestedEnd` 与档位共同决定，与状态层的 `window.period(endingAt:)` 逐位同构。
    private var identityMatches: Bool {
        guard let expected = currentIdentity else { return false }
        if let periodEnd, expected.range.end != periodEnd { return false }
        return expected.range == window.period(endingAt: expected.range.end)
    }
    private var matchedSeries: TrendSeries? {
        guard identityMatches, let series = state.detailSeries else { return nil }
        return series
    }
    private var matchedSleep: SleepTrendSeries? {
        guard identityMatches, metricType?.isSleep == true, let sleep = state.sleepSeries else { return nil }
        return sleep
    }

    /// 当前周期（查询身份里的 range；身份写入与本页请求同步，标签与图表同源）
    private var period: DateInterval? { currentIdentity?.range }

    /// 空态分流（BR-001）：本人且从未有设备读数 = 「未连接 Apple 健康」+ 去连接；
    /// 其余（含非本人成员——其设备读数永不可见）一律通用无数据。
    /// **读失败时不引导连接**（2026-09-16 评审修复）：探测量每次载入按次重置，
    /// 曲线读取失败时它停在 false，会把「有设备数据但本次读失败」显示成
    /// 「未连接 Apple 健康」+ [去连接]，而正文写着「加载失败」——自相矛盾且是假引导。
    private var showsConnectGuidance: Bool { isSelf && !state.hasDeviceSamples && !state.detailFailed }
    private var emptyTitle: String { showsConnectGuidance ? L10n.trendNotConnectedHealth : L10n.trendEmptyTitle }
    private var emptyHint: String { showsConnectGuidance ? L10n.trendNotConnectedHint : L10n.trendEmptyHint }

    /// 最近读数是否落在本周期之外（空态诊断行与出口按钮的**同一判据**，
    /// 不再写成条件不同的两处）
    private var latestOutsidePeriod: Bool {
        guard let latest = state.latestAnyDate, let range = period else { return false }
        return latest < range.start || latest > range.end
    }

    /// 更近方向：已翻页离开当前周期即可前进；自动锚定（今天）态没有更近的周期。
    /// 边界判定走 Domain（`TrendTimeWindow.paged(by:from:cappedAt:)`），
    /// 视图不再自行比较两个日期。
    private var canPageForward: Bool { periodEnd != nil }

    /// 翻页（ui-ux §4.17 PagingStepper 语义）：长度不变，整体前后移动一个周期。
    /// 越过「今天」即回落自动锚定（periodEnd = nil）。
    private func page(_ step: Int) {
        periodEnd = window.paged(by: step, from: requestedEnd, cappedAt: Date())
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if state.detailLoading {
                    ProgressView()
                } else if let sleep = matchedSleep,
                          !sleep.nights.isEmpty || !sleep.excludedNights.isEmpty {
                    // FR7.11 睡眠整合（业主 2026-09-16 第 3 项）：一晚一根堆叠柱，
                    // 段色区分阶段 + 图例；不再让六个时长键各占一张图
                    SleepTrendDetailView(
                        series: sleep,
                        window: window,
                        onToggleExcluded: { night, excluded in
                            Task { await state.setExcluded(night: night, excluded: excluded,
                                                           patientId: patientId, metricKey: metricKey) }
                        })
                } else if let series = matchedSeries,
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
                        Label(emptyTitle, systemImage: "chart.xyaxis.line")
                    } description: {
                        VStack(spacing: 6) {
                            Text(state.detailFailed ? L10n.trendLoadFailed : emptyHint)
                            // 诊断行（2026-09-16）：本周期空但该指标有读数——如实告知位置。
                            // 判据「最近读数不在本周期内」（翻页后最新读数可能晚于当前周期，
                            // 用户在往回翻时同样要告知）。
                            if let latest = state.latestAnyDate, latestOutsidePeriod {
                                Text(L10n.trendEmptyOutOfWindow(L10n.trendDate(latest)))
                                    .font(.caption)
                                    .accessibilityIdentifier("SP-13.trend.latestOutOfWindow")
                            }
                        }
                    } actions: {
                        // 审查修复（V3.53 空态分流）：仅在成员名下无任何设备读数时
                        // 给 [去连接] 引导；已有设备数据但该指标空 = 通用无数据，
                        // 不给假连接引导。BR-001 追加修复（2026-09-16）：设备读数
                        // 只可能归属本人绑定，非本人成员的设备读数恒不可见。
                        if showsConnectGuidance {
                            Button(L10n.trendGoConnect) {
                                router.navigate(to: .deviceConnection)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("SP-13.trend.connectHealth")
                        }
                        // 出口（业主 2026-09-16 第 1 项后）：自动锚定今天时空周期是
                        // 常见状态（读数稀疏），此处的唯一可靠落点是「该指标最近读数
                        // 所在周期」——用最近读数本身当周期末（含该读数的最后一个周期），
                        // 判据与上面的诊断行同源（latestOutsidePeriod）。
                        if let latest = state.latestAnyDate, latestOutsidePeriod {
                            Button(L10n.trendPeriodJumpToLatest) { periodEnd = latest }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("SP-13.trend.period.jumpToLatest")
                        }
                    }
                    // 容器标识必须配 children: .contain——否则 SwiftUI 把容器标识压到
                    // 每个子元素上，子按钮的 SP-13.trend.connectHealth 在 XCUITest 里
                    // 查不到（CI 34021989599 同族）。L0 掩蔽门禁看不到跨文件容器类型。
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SP-13.trend.detail.empty")
                }
            }
            // SP-13 周期长度 / 周期翻页控件：固定于顶部安全区（图表与列表在其下滚动）
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Picker(L10n.trendWindowLabel, selection: $window) {
                        ForEach(TrendTimeWindow.allCases) { item in
                            Text(L10n.trendWindow(item)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SP-13.trend.window")
                    // 周期翻页（业主 2026-09-16 第 4 项；第 2 项要求按钮更大）：
                    // 长度由上面的分段控件决定，这里只平移周期 → 可回答
                    // 「上一个周期比这个周期怎么样」。控件形态走 DesignSystem
                    // PagingStepper（ui-ux §4.17）：触点 = CareModeMetrics（44/64pt）、
                    // 图标 24pt、整块 contentShape——此前是 18pt 图标画在 44pt 框里。
                    // 来源筛选控件退役（业主同批第 1 项）：由 Apple 健康数据触发的
                    // 趋势页不应有来源选择，而「来源」本身已由每点的实心/空心 + 图例
                    // + 逐行来源标注（FR7.6）完整呈现；查询身份仍保留 origin 维度
                    // （BR-001 设备守卫与后续按来源浏览共用）。
                    PagingStepper(
                        canGoPrevious: true,
                        canGoNext: canPageForward,
                        previousLabel: L10n.trendPeriodPrevious,
                        nextLabel: L10n.trendPeriodNext,
                        previousIdentifier: "SP-13.trend.period.prev",
                        nextIdentifier: "SP-13.trend.period.next",
                        onPrevious: { page(1) },
                        onNext: { page(-1) }
                    ) {
                        TrendPeriodLabel(range: period)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SP-13.trend.period")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-13.trend.controls")
            }
            // 成员/指标/周期长度/周期末任一变化，或指标投影版本变化即重载
            .task(id: taskID) {
                // 路由身份变化（切成员/切指标）即重置视图级游标：@State 不随
                // `let` 输入重建，甲的翻页游标/长度档会被乙的页面继承
                // （切成员后仍显示甲的周期——同一 stale-@State 家族）。
                if loadedRouteKey != routeKey {
                    loadedRouteKey = routeKey
                    window = .year
                    periodEnd = nil
                }
                await state.loadDetail(patientId: patientId, metricKey: metricKey,
                                       window: window, periodEnd: periodEnd)
            }
            // FR20.3 L2 场景首用须知（趋势图表页，一次性确认——此前挂在
            // 零实例化死视图上，须知从未展示）
            .sceneDisclosure(scene: "trends")
        }
    }
}

/// SP-13 周期标签（翻页控件的当前周期；`nil` = 首次加载尚未写入身份）。
/// 独立小视图：日期区间格式化只随 range 变化求值，不随图表拖动选点每帧重算。
private struct TrendPeriodLabel: View {
    let range: DateInterval?

    var body: some View {
        Text(text)
            .font(.footnote)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.trendPeriodAccessibility(text))
            .accessibilityIdentifier("SP-13.trend.period.label")
    }

    private var text: String {
        guard let range else { return L10n.trendPeriodLocating }
        return L10n.trendPeriodRange(range.start, range.end)
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
            latestMetrics = Self.gridRows(rows)
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
            latestMetrics = Self.gridRows(rows)
        }
    }

    /// 宫格行的成员过滤 + 睡眠族折叠（单一出口，两条读取路径共用）：
    /// ① 只保留有趋势详情页的指标（MetricType 注册表覆盖）——设备入库的
    ///    raw 键（如未映射的 snake_case）不产瓷片，否则点入详情被
    ///    `MetricType(rawValue:)` 守卫拒载、宫格出现未本地化瓷片；
    /// ② 睡眠族六键折叠为**一块**瓦片（FR7.11 整合，Domain 规则
    ///    `SleepTrendRules.gridRows`）——六个投影键同属一晚，分列六块会把
    ///    半屏宫格用来重复表示同一夜的读数。
    private static func gridRows(_ rows: [TrendQueryStore.LatestMetric]) -> [TrendQueryStore.LatestMetric] {
        let known = rows.filter { MetricType(rawValue: $0.metricKey) != nil }
        return SleepTrendRules.gridRows(known,
                                        metric: { MetricType(rawValue: $0.metricKey) },
                                        value: \.value)
    }

    /// 写后详情刷新（排除/恢复动作；不重盖身份，同 refreshLatestIfCurrent 纪律）。
    /// 沿用当前 detailIdentity 整体（含原时间范围与来源过滤）重查，只在身份仍是当前时落槽。
    /// 睡眠族走 `sleepSeries`（点族的 `series` 会把整合页换回单键折线图）。
    func refreshDetailIfCurrent(patientId: UUID, metricKey: String) async {
        guard let query = detailIdentity, query.patientId == patientId,
              query.metric.rawValue == metricKey else { return }
        do {
            if query.metric.isSleep {
                let loaded = try await store.sleepSeries(query)
                guard detailIdentity == query, loaded.identity == query else { return }
                sleepSeries = loaded
            } else {
                let loaded = try await store.series(query)
                guard detailIdentity == query, loaded.identity == query else { return }
                detailSeries = loaded
            }
        } catch {
            // 刷新失败保留原状（软删失败无数据损失；错误经日志）
        }
    }

    /// FR7.4 睡眠夜排除/恢复：一晚的多段行同属一个动作（柱是一晚，不是一段），
    /// 逐行写软删后记**一条**审计（动作对象 = 该夜；逐行记审计会让一次点击
    /// 在审计里变成六条）。行集为空即无动作。
    func setExcluded(night: SleepTrendNight, excluded: Bool, patientId: UUID, metricKey: String) async {
        let ids = night.pointIds
        guard !ids.isEmpty else { return }
        do {
            // 单事务写整夜（含 sleep_total 行）——逐行各写会在中途失败时留下
            // 「半排除」的夜（图上仍有部分柱、已排除分段里也有它）
            try await store.setExcluded(ids, patientId: patientId, excluded: excluded)
            try? await audit?.record(   // try?-ok: 审计失败不阻断排除动作本身（与既有审计纪律一致）
                action: "update", entityType: "metric_sample",
                entityId: ids[0].uuidString, actorLocal: "owner",
                meta: excluded ? "exclude-night" : "restore-night")
            await refreshDetailIfCurrent(patientId: patientId, metricKey: metricKey)
        } catch {
            // 失败保留原状可重试；软删失败无数据损失
        }
    }
}
