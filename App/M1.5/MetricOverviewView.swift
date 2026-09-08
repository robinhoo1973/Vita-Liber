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
    @Environment(AppDataChangeCenter.self) private var dataChange
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
                            MetricTile(item: item,
                                       // 成员纳入 task id（审查修复）：仅按 metricKey
                                       // 作 id 时，A→B 切换成员后 tile 身份不变、
                                       // @State spark 不重载——A 的 30 天迷你线
                                       // 挂在 B 名下（BR-001 同族）
                                       taskId: "\(app.currentPatientId.uuidString)-\(item.metricKey)",
                                       sparkLoader: { key in
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
                            ? [VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)]
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
        .onAppear { routeMonitor.start() }
        // BR-001 成员切换：与 TrendEntryView/VoiceNotePanel 同款 task(id:)——
        // onAppear 只在首次挂载触发，切换成员后宫格仍显示上一成员的指标
        .task(id: app.currentPatientId) { await state.loadLatest(patientId: app.currentPatientId) }
        // FR7.9（V3.86）：设备读数入库后按类型化版本计数失效刷新——
        // 宫格最新点即时反映 Apple 健康自动汇入（数据经 Store 观察 DB）
        .onChange(of: dataChange.metricsVersion) { _, _ in
            Task { await state.loadLatest(patientId: app.currentPatientId) }
        }
        .onDisappear { routeMonitor.stop() }
        // FR17.13-entry: 指标总览语音入口 —— 统一确认模板，不自建确认逻辑
        .voiceConfirmSheet($confirmSet, route: routeMonitor.route) { confirmed in
            confirmSet = nil
            router.pendingVoiceIntent = confirmed.pendingIntent(VoiceIntentKey.recordMetric.rawValue)
            router.navigate(to: .metricQuickEntry)
        }
    }
}

/// §4.10 MetricTile：大数字 + 单位 + 来源点 + 30 天迷你趋势线
struct MetricTile: View {
    let item: TrendQueryStore.LatestMetric
    /// 迷你趋势加载任务 id（成员+指标键）——变化即重载 spark
    let taskId: String
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
                // 医学数值显示单一出口（审查修复：此前内联 .formatted，
                // 与趋势页 oneDecimal 双规则漂移——同一值宫格显示 62、
                // 趋势页显示 62.0）；大数字字号收敛 VLFont 令牌
                Text(MedicalNumberFormat.quantity(item.value))
                    .font(VLFont.metricTileValue)
                    .monospacedDigit()
                if let unit = item.unit, !unit.isEmpty {
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Color("bg-grouped", bundle: .main)))
        .task(id: taskId) {
            spark = await sparkLoader(item.metricKey)
        }
    }

    private var metricName: String {
        if let m = MetricType(rawValue: item.metricKey) { return L10n.metricName(m) }
        return item.metricKey
    }
}
