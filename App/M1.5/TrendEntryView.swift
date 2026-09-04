import SwiftUI
import Domain
import Infrastructure

/// F7 趋势入口（records 模块）：按成员加载血糖序列（demo 指标，M1.5 全量后可选指标）。
@MainActor
@Observable
final class TrendEntryState {
    private(set) var series: TrendSeries?
    /// internal：MetricEntryView 扩展（录入/单位记忆/排除接线）跨文件访问
    let store: TrendQueryStore
    /// FR7.2 点回原报告（sourceRef 深链）——视图层持有，气泡五要素由 TrendDetailView 渲染
    var lastOpenedSource: String?
    /// FR7.8 换算留痕（原值+规则）——查询层换算后携带注记
    var conversionNote: String? { nil }
    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?
    init(store: TrendQueryStore) { self.store = store }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            let range = DateInterval(start: Date().addingTimeInterval(-90 * 86400), end: Date())
            let loaded = try await store.series(for: patientId, metric: .glucose, range: range)
            // BR-001 成员隔离：切换成员会取消旧 .task，但已在飞行中的 actor 调用仍会返回。
            // 晚到的旧成员结果绝不能覆盖当前成员状态（否则甲的曲线显示在乙的档案下）。
            guard loadingPatientId == patientId else { return }
            series = loaded
        } catch {
            // 数据为空态经 UI 呈现；错误经调用侧日志
        }
    }

    /// §5.45 深链：按指标加载指定序列（SP-13 趋势详情路由）。
    /// 独立状态槽避免覆盖入口页的血糖默认序列。
    private(set) var detailSeries: TrendSeries?
    private(set) var detailMetric: String?

    func loadDetail(patientId: UUID, metricKey: String) async {
        loadingPatientId = patientId
        do {
            let range = DateInterval(start: Date().addingTimeInterval(-365 * 86400), end: Date())
            let metric = MetricType(rawValue: metricKey) ?? .glucose
            let loaded = try await store.series(for: patientId, metric: metric, range: range)
            guard loadingPatientId == patientId else { return }
            detailSeries = loaded
            detailMetric = metricKey
        } catch {
            detailSeries = nil
        }
    }
}

/// §5.45 路由目的地：指定成员+指标的独立趋势页（SP-13）。
/// 点回原报告/排除恢复/换算注记接线随 F7 录入批（Phase 6）补全。
struct TrendChartRouteView: View {
    let patientId: UUID
    let metricKey: String
    @Environment(TrendEntryState.self) private var state

    var body: some View {
        Group {
            if let series = state.detailSeries, !series.points.isEmpty {
                TrendDetailView(series: series)
            } else {
                ContentUnavailableView(L10n.trendTitle, systemImage: "chart.xyaxis.line",
                                       description: Text(L10n.trendRangeUnavailable))
                    .accessibilityIdentifier("SP-13.trend.detail.empty")
            }
        }
        .task(id: "\(patientId.uuidString)-\(metricKey)") {
            await state.loadDetail(patientId: patientId, metricKey: metricKey)
        }
    }
}

struct TrendEntryView: View {
    @Environment(AppState.self) private var app
    @Environment(TrendEntryState.self) private var state
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if let series = state.series, !series.points.isEmpty {
                // FR7.2 点回原报告（sourceRef 深链）；FR7.4 排除/恢复软删；
                // FR7.8 换算留痕——此前挂载点三参数全 nil，App 内不可达
                TrendDetailView(
                    series: series,
                    conversionNote: state.conversionNote,
                    onOpenSource: { point in
                        if let ref = point.sourceRef {
                            state.lastOpenedSource = ref
                        }
                    },
                    onToggleExcluded: { point in
                        Task { await state.toggleExcluded(point, patientId: currentPatientId) }
                    })
            } else {
                ContentUnavailableView(L10n.trendEmptyTitle, systemImage: "chart.xyaxis.line",
                                       description: Text(L10n.trendEmptyHint))
                    .accessibilityIdentifier("SP-13.trend.empty")
            }
        }
        .toolbar {
            // FR7.5 两步录入入口（SP-13 快速录入）
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.navigate(to: .metricQuickEntry)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("SP-13.metric.add")
            }
        }
        .task(id: currentPatientId) { await state.load(patientId: currentPatientId) }
        // FR20.3 L2 场景首用须知（趋势图表页，一次性确认）
        .sceneDisclosure(scene: "trends")
    }

    private var currentPatientId: UUID { app.currentPatientId }
}
