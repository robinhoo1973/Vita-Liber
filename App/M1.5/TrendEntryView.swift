import SwiftUI
import Domain
import Infrastructure

/// F7 趋势入口（records 模块）：按成员加载血糖序列（demo 指标，M1.5 全量后可选指标）。
@MainActor
@Observable
final class TrendEntryState {
    private(set) var series: TrendSeries?
    private let store: TrendQueryStore
    init(store: TrendQueryStore) { self.store = store }

    func load(patientId: UUID) async {
        do {
            let range = DateInterval(start: Date().addingTimeInterval(-90 * 86400), end: Date())
            series = try await store.series(for: patientId, metric: .glucose, range: range)
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
                ContentUnavailableView("暂无指标数据", systemImage: "chart.xyaxis.line",
                                       description: Text("录入自测指标或导入报告后，趋势图会显示在这里"))
                    .accessibilityIdentifier("SP-13.trend.empty")
            }
        }
        .task { await state.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}
