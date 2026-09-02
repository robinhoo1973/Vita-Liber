import SwiftUI
import Domain
import Infrastructure

/// F7 趋势入口（records 模块）：按成员加载血糖序列（demo 指标，M1.5 全量后可选指标）。
@MainActor
@Observable
final class TrendEntryState {
    private(set) var series: TrendSeries?
    private let store: TrendQueryStore
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
}

struct TrendEntryView: View {
    @Environment(AppState.self) private var app
    @Environment(TrendEntryState.self) private var state

    var body: some View {
        Group {
            if let series = state.series, !series.points.isEmpty {
                TrendDetailView(series: series)
            } else {
                ContentUnavailableView(L10n.trendEmptyTitle, systemImage: "chart.xyaxis.line",
                                       description: Text(L10n.trendEmptyHint))
                    .accessibilityIdentifier("SP-13.trend.empty")
            }
        }
        .task(id: currentPatientId) { await state.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}
