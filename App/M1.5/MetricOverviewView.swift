import SwiftUI
import Charts
import Domain
import Infrastructure

/// §5.45 指标总览（F7 · SP-13 · V3.72 点亮）：双列 MetricTile 宫格——
/// 大数字当前值（mono-numeric）+ 单位 + 来源点（医院实心/自测·设备空心，
/// FR7.6 一眼可辨）+ 30 天迷你趋势线；点击 tile 进趋势详情。
/// 顶部常驻 [快速录入] 与 [按住说话]（F17 入口，转写经 FR17.13 统一确认）。
/// 此前 records 模块无任何指标总览入口——指标只能从时间轴间接到达。
struct MetricOverviewView: View {
    @Environment(AppState.self) private var app
    @Environment(TrendEntryState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if state.latestMetrics.isEmpty {
                ContentUnavailableView(L10n.metricOverviewEmpty, systemImage: "waveform.path.ecg",
                                       description: Text(L10n.metricOverviewEmptyHint))
                    .accessibilityIdentifier("SP-13.overview.empty")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(state.latestMetrics) { item in
                            MetricTile(item: item, sparkLoader: { key in
                                guard let m = MetricType(rawValue: key) else { return nil }
                                let end = Date()
                                let start = DayArithmetic.offset(days: -30, from: end)
                                return try? await state.store.series(for: app.currentPatientId,   // try?-ok: tile 迷你趋势读取失败只不画线，不阻断宫格
                                                                     metric: m,
                                                                     range: DateInterval(start: start, end: end))
                            })
                                .onTapGesture {
                                    router.navigate(to: .trendChart(patientId: app.currentPatientId,
                                                                    metric: item.metricKey))
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(L10n.metricOverviewTitle)
        .toolbar {
            // §5.13 [按住说话] 顶部常驻（老年模式默认路径）——转写→确认→预填录入
            ToolbarItem(placement: .topBarTrailing) {
                VoiceDictationButton { text, confidence in
                    let drafts = VoiceStructuringEngine.extractMetric(
                        text, rules: VoiceGrammarDefaults.metricRules)
                    confirmSet = VoiceInputTemplate.confirmationSet(
                        drafts: drafts.isEmpty
                            ? [FieldDraft(key: "note", value: text, unit: nil, confidence: confidence)]
                            : drafts)
                }
                .frame(width: 96)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.navigate(to: .metricQuickEntry)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityIdentifier("SP-13.overview.quickEntry")
            }
        }
        .onAppear {
            routeMonitor.start()
            Task { await state.loadLatest(patientId: app.currentPatientId) }
        }
        .onDisappear { routeMonitor.stop() }
        // FR17.13-entry: 指标总览语音入口 —— 统一确认模板，不自建确认逻辑
        .sheet(item: $confirmSet) { set in
            VoiceConfirmSheet(
                set: set,
                decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                preference: app.readbackPreference,
                                                careMode: app.careMode),
                onSpeak: { app.speak($0) },
                onConfirm: { confirmed in
                    confirmSet = nil
                    let map = Dictionary(uniqueKeysWithValues: confirmed.confirmedFields.map { ($0.key, $0.value) })
                    router.pendingVoiceDraft = map
                    router.navigate(to: .metricQuickEntry)
                },
                onRetry: { confirmSet = nil },
                onCancel: { confirmSet = nil })
            .presentationDetents([.medium])
        }
    }
}

/// §4.10 MetricTile：大数字 + 单位 + 来源点 + 30 天迷你趋势线
struct MetricTile: View {
    let item: TrendQueryStore.LatestMetric
    /// 30 天迷你趋势数据源（按 metricKey 独立查询——每 tile 各画各的线）
    let sparkLoader: (String) async -> TrendSeries?
    @State private var spark: TrendSeries?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metricName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                // 来源点：医院实心 / 自测·设备空心（FR7.6）
                Circle()
                    .strokeBorder(Color("brand-primary", bundle: .main), lineWidth: 1.5)
                    .background(Circle().fill(item.origin == "hospital"
                                              ? Color("brand-primary", bundle: .main)
                                              : .clear))
                    .frame(width: 10, height: 10)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.value.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let unit = item.unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let spark, !spark.points.isEmpty {
                Chart(spark.points) { p in
                    LineMark(x: .value("t", p.measuredAt), y: .value("v", p.value))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 32)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .task(id: item.metricKey) {
            spark = await sparkLoader(item.metricKey)
        }
    }

    private var metricName: String {
        if let m = MetricType(rawValue: item.metricKey) { return L10n.metricName(m) }
        return item.metricKey
    }
}
