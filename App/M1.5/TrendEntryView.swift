import SwiftUI
import Domain
import Infrastructure
import Protocols

/// F7 趋势状态（records 模块）：按指标加载指定序列 + 指标总览宫格最新点。
///
/// 审查修复（死代码清除）：原 TrendEntryView 是零实例化死视图——其专属的
/// 90 天血糖默认序列 `series`/`load()`、`lastOpenedSource`（写入无读者）、
/// `detailMetric`（写入无读者）、恒 nil 的 `conversionNote` 连同视图一并删除；
/// 趋势页真实挂载点是 TrendChartRouteView（.trendChart 路由），FR7.4 排除/
/// 恢复与 FR20.3 L2 须知已接线到该视图。
@MainActor
@Observable
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
    /// 最近一次详情请求的指标键（与 loadingPatientId 同款守卫：同一成员下
    /// 快速切指标时，晚到的旧指标结果不得覆写新指标的 detailSeries——
    /// 路由页的 metricType 校验会把被覆写后的序列显示成「不可用」，
    /// 真数据存在却渲染空态）
    private var loadingMetricKey: String?
    init(store: TrendQueryStore, audit: (any AuditLogging)? = nil) {
        self.store = store
        self.audit = audit
    }

    /// §5.45 深链：按指标加载指定序列（SP-13 趋势详情路由）。
    /// 独立状态槽避免覆盖入口页的血糖默认序列。
    private(set) var detailSeries: TrendSeries?
    /// SP-13 未连接空态判定（ui-ux §5.45 V3.53）：成员名下是否存在任何
    /// origin='device' 读数——空态分流「未连接 Apple 健康」vs 通用无数据
    private(set) var hasDeviceSamples = false

    func loadDetail(patientId: UUID, metricKey: String) async {
        loadingPatientId = patientId
        loadingMetricKey = metricKey
        do {
            // DST 纪律（同日 load 修复）：日历日窗口，切换日不漂移
            let range = DateInterval(start: DayArithmetic.offset(days: -365, from: Date()), end: Date())
            // 第八轮全仓审查修复（错误指标静默替代）：未知/拼错的 metricKey
            // 此前 ?? .glucose——深链打开错误的血糖图表冒充目标指标（张冠
            // 李戴，与 TimelineViews 已修同族）。注册表必须覆盖全部 metricKey，
            // 未知即拒绝：detailSeries 置 nil → 路由页呈现不可用空态，绝不
            // 用真实指标顶替。
            guard let metric = MetricType(rawValue: metricKey) else {
                detailSeries = nil
                return
            }
            // 加载期间即清槽（审查修复）：切指标/切成员时旧指标的曲线
            // 不得在新指标名下继续渲染（路由页另有 metricKey 一致校验兜底）
            detailSeries = nil
            let loaded = try await store.series(for: patientId, metric: metric, range: range)
            guard loadingPatientId == patientId, loadingMetricKey == metricKey else { return }
            detailSeries = loaded
            // 空态分流的设备存在性判定（与序列同请求同守卫）
            hasDeviceSamples = (try? await store.hasDeviceSamples(patientId: patientId)) ?? true   // try?-ok: 判定失败按「已连接」保守处理——通用空态优于误报未连接
        } catch {
            // 过期请求（已切成员/切指标）的失败不触碰当前数据；当前请求
            // 失败才清槽（空态渲染，不残留旧曲线）
            guard loadingPatientId == patientId, loadingMetricKey == metricKey else { return }
            detailSeries = nil
        }
    }
}

/// §5.45 路由目的地：指定成员+指标的独立趋势页（SP-13）。
/// FR7.2 点回原报告深链待 F7 录入批（Phase 6）接线——在无真实导航前
/// 不渲染「回原报告」按钮（onOpenSource 传 nil，杜绝点了没反应的假入口）。
struct TrendChartRouteView: View {
    let patientId: UUID
    let metricKey: String
    @Environment(TrendEntryState.self) private var state
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            // 审查修复：detailSeries 必须与当前 metricKey 同指标——加载
            // 在途/失败期间旧指标曲线不得顶替渲染（张冠李戴同族）
            if let series = state.detailSeries,
               series.metricType.rawValue == metricKey, !series.points.isEmpty {
                // FR7.4 排除/恢复软删（此前唯一接线点在已删除的死视图
                // TrendEntryView 上，App 内不可达）
                TrendDetailView(
                    series: series,
                    onToggleExcluded: { point in
                        Task { await state.toggleExcluded(point, patientId: patientId, metricKey: metricKey) }
                    })
            } else if !state.hasDeviceSamples {
                // SP-13 未连接空态（ui-ux §5.45 V3.53）：成员从未连接/同步
                // 过 Apple 健康（无任何 origin='device' 读数）——分流为
                // 「未连接」+ [去连接] 深链（SP-29），不渲染设备来源占位；
                // 有设备数据但该指标空 → 下方通用空态
                ContentUnavailableView {
                    Label(L10n.trendNotConnectedHealth, systemImage: "heart.slash")
                } description: {
                    Text(L10n.trendNotConnectedHint)
                } actions: {
                    Button(L10n.trendGoConnect) {
                        router.navigate(to: .deviceConnection)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-13.trend.connectHealth")
                }
                .accessibilityIdentifier("SP-13.trend.detail.notConnected")
            } else {
                ContentUnavailableView(L10n.trendTitle, systemImage: "chart.xyaxis.line",
                                       description: Text(L10n.trendRangeUnavailable))
                    .accessibilityIdentifier("SP-13.trend.detail.empty")
            }
        }
        .task(id: "\(patientId.uuidString)-\(metricKey)") {
            await state.loadDetail(patientId: patientId, metricKey: metricKey)
        }
        // FR20.3 L2 场景首用须知（趋势图表页，一次性确认——此前挂在
        // 零实例化死视图上，须知从未展示）
        .sceneDisclosure(scene: "trends")
    }
}

// MARK: - §5.45 指标总览宫格数据（V3.72）

extension TrendEntryState {
    /// 宫格最新点加载（try?-ok: 读取失败按空态渲染，不阻断总览页）
    func loadLatest(patientId: UUID) async {
        // 第六轮全仓审查修复（BR-001 残留）：与 loadDetail 同款
        // loadingPatientId 守卫——原实现无守卫，A 成员的慢查询在切换到
        // B 成员后返回并覆写 latestMetrics，A 的最新值挂在 B 名下展示
        loadingPatientId = patientId
        if let rows = try? await store.latestPerMetric(patientId: patientId) {   // try?-ok: 读取失败按空态渲染，不阻断总览页
            guard loadingPatientId == patientId else { return }
            // 只保留有趋势详情页的指标（MetricType 注册表覆盖）——设备入库
            // 的 steps/sleep_total 等无详情页键不产瓷片（否则 raw 键瓷片 +
            // 点入详情被 MetricType(rawValue:) 守卫拒载，L10n 单出口被破坏）
            latestMetrics = rows.filter { MetricType(rawValue: $0.metricKey) != nil }
        } else {
            // 审查修复：当前请求失败时清空——否则上一成员的宫格数据
            // 在新成员名下持续渲染（BR-001）；过期请求的失败不触碰新数据
            guard loadingPatientId == patientId else { return }
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

    /// 写后详情刷新（排除/恢复动作；不重盖标记，同 refreshLatestIfCurrent 纪律）
    func refreshDetailIfCurrent(patientId: UUID, metricKey: String) async {
        guard loadingPatientId == patientId, loadingMetricKey == metricKey,
              let metric = MetricType(rawValue: metricKey) else { return }
        do {
            let range = DateInterval(start: DayArithmetic.offset(days: -365, from: Date()), end: Date())
            let loaded = try await store.series(for: patientId, metric: metric, range: range)
            guard loadingPatientId == patientId, loadingMetricKey == metricKey else { return }
            detailSeries = loaded
        } catch {
            // 刷新失败保留原状（软删失败无数据损失；错误经日志）
        }
    }
}
