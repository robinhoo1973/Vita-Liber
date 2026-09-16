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
    /// 详情轨不写本字段（2026-09-16 审查修复）：两条轨共用一个成员标记时，
    /// 趋势详情页为成员甲挂起会把宫格为成员乙的在途加载判为过期而静默丢弃
    /// （宫格停在上一成员或空态，无错误也无重试）；详情轨的隔离由
    /// `detailRequest` 代次 + `detailIdentity` 身份双校验独立承担。
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
    /// 任意窗口最近读数（诊断性空态，2026-09-16 业主实测）：空窗时告知「数据在更早」，
    /// 可一键切一年窗——此前空态只有一句同步报告文案，用户无从判断是真空还是窗口未覆盖。
    private(set) var latestAnyDate: Date?
    /// 诊断查询失败标记（2026-09-16 委员会评审）：该查询失败被吞为 nil，调用方无从
    /// 区分「真无数据」与「读失败」；此标记让空态的**逃生出口**（跳到最近读数所在周期）
    /// 在失败时仍保留——否则恰在用户最需要出口时它静默消失。
    private(set) var latestDiagnosticFailed = false
    /// 本次请求实际使用的周期末（渲染层据此与查询身份逐位比对，判定槽内序列是否
    /// 就是本页当前请求的那一段）。与 `latestAnyDate` 分开：后者是「最新读数」
    /// （可为 nil 且是翻页上限的来源），前者是**请求的周期末**（恒非 nil，
    /// 锚点解析失败时回落 `Date()`——此时渲染层若自行取 `Date()` 会与请求相差
    /// 几微秒而被判成过期，已加载的曲线会被误判为空态）。
    private(set) var periodAnchor: Date?

    /// - Parameters:
    ///   - window: 时间窗（日历日，DayArithmetic 出口——切换日不漂移）
    ///   - periodEnd: 周期末（业主 2026-09-16 第 4 项翻页；nil = 自动锚定到最新读数所在日）
    ///   - origin: 来源过滤（nil = 全部；`.device` 由查询层强制本人绑定，BR-001）
    func loadDetail(patientId: UUID, metricKey: String, window: TrendTimeWindow = .year,
                    periodEnd: Date? = nil, origin: MetricOrigin? = nil) async {
        let request = UUID()
        detailRequest = request
        detailLoading = true
        detailFailed = false
        // 诊断态按次重置：三项只在成功路径写入，不重置时上一成员/上一周期的
        // 诊断会挂到本次空态上（B 成员读写失败 → 页面显示甲成员的「最近读数」）
        latestAnyDate = nil
        latestDiagnosticFailed = false
        hasDeviceSamples = false
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
        // 周期锚点 = 该指标最新读数所在日（任意窗口；无读数回落今天）。
        // 为什么锚点不是「现在」：读数天然稀疏（设备投影按窗口由旧到新物化，
        // 近期窗口最后到达、医院读数成批且常常是几个月前），锚在「现在」时
        // 7/30/90 天窗只能渲染空态而 1 年窗有数据（业主 2026-09-16 实测第 3 项）。
        // 锚定后：首屏必落在有数据的周期；‹ › 在同长度下前后翻阅（第 4 项）。
        let latest: Date?
        do { latest = try await store.latestMeasuredAt(patientId: patientId, metric: metric, origin: origin) }
        catch { latest = nil; latestDiagnosticFailed = true }
        let range = window.period(endingAt: periodEnd ?? latest ?? Date())
        // 锚点随请求发布（晚到的旧请求不得覆写：进页首帧可能连发两次请求）
        if detailRequest == request { periodAnchor = range.end }
        let query = TrendQueryIdentity(patientId: patientId, metric: metric, origin: origin, range: range)
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
            latestAnyDate = latest
        } catch {
            // 过期请求（已切成员/切指标）的失败不触碰当前数据；当前请求
            // 失败才清槽（空态渲染，不残留旧曲线）。含 QueryError.deviceRequiresSelfBinding
            // （视图对非本人不提供设备过滤项，此处仅兜底）。
            guard detailRequest == request, !Task.isCancelled else { return }
            detailSeries = nil
            detailFailed = true
        }
    }

    /// F19 事实播报专用读取（VoiceSessionView「最近血糖」）：直接走查询层，
    /// **不写任何 detail 槽位**（原实现调用 loadDetail 覆写趋势页共用的
    /// detailSeries/detailIdentity——语音一问就把正在看的趋势页清成空态，
    /// 且回读时不做身份校验，快速连问会播报上一请求甚至另一成员的序列）。
    /// 窗口锚定最新读数（读数稀疏时 1 年窗也可能不含最近读数）。
    func recentValues(patientId: UUID, metric: MetricType, limit: Int = 3) async -> [TrendPoint] {
        let latest = try? await store.latestMeasuredAt(patientId: patientId, metric: metric, origin: nil)   // try?-ok: 播报失败按「暂无记录」呈现（与既有行为一致）
        let anchor = latest ?? Date()
        let query = TrendQueryIdentity(patientId: patientId, metric: metric, origin: nil,
                                       range: TrendTimeWindow.year.period(endingAt: anchor))
        guard let series = try? await store.series(query), series.identity == query else { return [] }   // try?-ok: 同上
        return Array(series.points.suffix(limit))
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
    /// 周期末（业主 2026-09-16 第 4 项翻页）：nil = 自动锚定到「最新读数所在日」，
    /// 非 nil = 用户翻页后的显式周期末。换窗只改长度、不动周期末（同一段数据不跳走）。
    @State private var periodEnd: Date?

    /// 本页成员是否本人绑定（BR-001：设备读数只可能归属本人；非本人不得出现设备引导）
    private var isSelf: Bool { app.owner?.selfPatientId == patientId }

    /// 最新读数所在日（自动锚点；未加载完成前按今天——首屏只会是「最近一个周期」）
    private var newestEnd: Date { state.latestAnyDate ?? Date() }

    /// 本页请求的周期末：用户翻页值优先，其次取状态层本次请求实际使用的锚点
    /// （`periodAnchor`——锚点解析失败时它回落请求时刻的 `Date()`，渲染层自行
    /// 取 `Date()` 会差几微秒，已加载曲线会被误判成过期）。
    private var requestedEnd: Date { periodEnd ?? state.periodAnchor ?? newestEnd }

    /// round2 H2 渲染前身份守卫：槽内序列必须携带与「当前请求身份」完全一致的身份，
    /// 该身份指向本路由的成员/指标，且**周期就是本页当前请求的那一段**。
    /// 为什么连周期一起校验：`TrendEntryState` 是全 App 单实例（其它调用方也写同一
    /// 槽位），只校验成员/指标时，一个「窗口 = 1 年」的序列可以挂在「7 天」档位下
    /// 渲染——可见域长度（60.5 万秒）对 1 年域（3153 万秒），图表停在最旧一段，
    /// 观感正是「数据没有渲染」；同长度但不同周期（上周挂在本周名下）同属此类。
    /// 周期由 `requestedEnd`（= 显式周期末或最新读数所在日）与档位共同决定，与状态层
    /// 的 `window.period(endingAt: periodEnd ?? latest ?? Date())` 逐位同构。
    private var identityMatches: Bool {
        guard let expected = state.detailIdentity, let series = state.detailSeries else { return false }
        guard series.identity == expected, expected.patientId == patientId,
              expected.metric.rawValue == metricKey else { return false }
        return expected.range == window.period(endingAt: requestedEnd)
    }

    /// 当前周期（查询身份里的 range；加载开始时即写入，周期标签与图表同源）
    private var period: DateInterval? { state.detailIdentity?.range }

    /// 空态标题/说明分态：本人且从未有设备读数 = 「未连接 Apple 健康」+ 去连接；
    /// 其余（含非本人成员——其设备读数永不可见，连接与否与本人无关）一律通用无数据。
    private var emptyTitle: String {
        isSelf && !state.hasDeviceSamples ? L10n.trendNotConnectedHealth : L10n.trendEmptyTitle
    }
    private var emptyHint: String {
        isSelf && !state.hasDeviceSamples ? L10n.trendNotConnectedHint : L10n.trendEmptyHint
    }

    /// 更早方向不设界（数据可能很远）；更近方向以「最新读数所在周期」为界——
    /// 未来周期不存在，也不会把用户推到一段必然为空的窗口。
    private var canPageForward: Bool {
        guard let periodEnd else { return false }
        return periodEnd < newestEnd
    }

    /// 翻页（ui-ux §4.17 PagingStepper 语义）：长度不变，整体前后移动一个周期。
    /// 回到（或越过）最新读数周期即恢复自动锚定（periodEnd = nil）。
    private func page(_ step: Int) {
        let next = window.paged(by: step, from: requestedEnd)
        periodEnd = next >= newestEnd ? nil : next
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
                    // 文案分态（2026-09-16 委员会评审）：此前一律用页面名 + SP-29
                    // 同步场景句（「本次同步未读取到…」在趋势页上下文不成立）；专写的
                    // trendEmptyTitle/Hint 与 trendNotConnectedHealth/Hint 此前零调用。
                    VLUnavailableView {
                        Label(emptyTitle, systemImage: "chart.xyaxis.line")
                    } description: {
                        VStack(spacing: 6) {
                            Text(state.detailFailed ? L10n.trendLoadFailed : emptyHint)
                            // 诊断行（2026-09-16）：本周期空但该指标有读数——如实告知位置。
                            // 判据从「最新读数早于本周期」放宽为「不在本周期内」：翻页后
                            // 最新读数可能晚于当前周期（用户在往回翻），同样要告知。
                            if let latest = state.latestAnyDate,
                               let range = state.detailIdentity?.range,
                               latest < range.start || latest > range.end {
                                Text(L10n.trendEmptyOutOfWindow(latest.formatted(date: .abbreviated, time: .omitted)))
                                    .font(.caption)
                                    .accessibilityIdentifier("SP-13.trend.latestOutOfWindow")
                            }
                        }
                    } actions: {
                        // 审查修复（V3.53 空态分流）：仅在成员名下无任何设备读数时
                        // 给 [去连接] 引导；已有设备数据但该指标空 = 通用无数据，
                        // 不给假连接引导。BR-001 追加修复（2026-09-16）：设备读数
                        // 只可能归属本人绑定，非本人成员的设备读数恒不可见——此前
                        // 非本人趋势页恒定在这一支，家属成员被引导去「连接 Apple 健康」，
                        // 点了却是给业主本人连接，成员页永远等不到数据（不可恢复的假引导）。
                        if isSelf, !state.hasDeviceSamples {
                            Button(L10n.trendGoConnect) {
                                router.navigate(to: .deviceConnection)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("SP-13.trend.connectHealth")
                        }
                        // 翻页出口：跳到「最新读数所在周期」——自动锚定周期恒含最近读数，
                        // 是数据不在当前周期时唯一可靠的落点（原 [查看最近一年] 在最新
                        // 读数早于一年时同样落空：换到年窗仍然空，点了没有出路）。
                        // 诊断失败时同样给出（失败被吞成 nil 时出口不得静默消失）。
                        if periodEnd != nil, state.latestAnyDate != nil || state.latestDiagnosticFailed {
                            Button(L10n.trendPeriodJumpToLatest) { periodEnd = nil }
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
                    // 周期翻页（业主 2026-09-16 第 4 项）：长度由上面的分段控件决定，
                    // 这里只平移周期 → 可回答「上一个周期比这个周期怎么样」。
                    // 来源筛选控件退役（业主同批第 1 项）：由 Apple 健康数据触发的
                    // 趋势页不应有来源选择，而「来源」本身已由每点的实心/空心 + 图例
                    // + 逐行来源标注（FR7.6）完整呈现；查询身份仍保留 origin 维度
                    // （BR-001 设备守卫与后续按来源浏览共用）。
                    HStack(spacing: 12) {
                        Button { page(1) } label: {
                            VLIcon.chevronLeft
                                .resizable().frame(width: 18, height: 18)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.trendPeriodPrevious)
                        .accessibilityIdentifier("SP-13.trend.period.prev")
                        TrendPeriodLabel(range: period)
                        Button { page(-1) } label: {
                            VLIcon.chevronRight
                                .resizable().frame(width: 18, height: 18)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPageForward)
                        .accessibilityLabel(L10n.trendPeriodNext)
                        .accessibilityIdentifier("SP-13.trend.period.next")
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
            .task(id: "\(patientId.uuidString)-\(metricKey)-\(window.rawValue)-\(periodEnd?.timeIntervalSince1970 ?? -1)-\(dataChange.metricsVersion)") {
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
