import SwiftUI
import Charts
import Domain
import Infrastructure
import Perception

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
        WithPerceptionTracking {
            Group {
                if state.latestMetrics.isEmpty {
                    // 空态零动作（2026-10-05 业主裁决）：指标不可能为空——空态仅作
                    // 四态纪律的防御呈现（§3.0 每屏四态），不提供任何录入入口；
                    // 语音录入入口在总览工具栏 [按住说话]（FR17.13）。
                    VLUnavailableView {
                        Label(L10n.metricOverviewEmpty, systemImage: "waveform.path.ecg")
                    } description: {
                        Text(L10n.metricOverviewEmptyHint)
                    }
                        .accessibilityIdentifier("SP-13.overview.empty")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(state.latestMetrics) { item in
                                // Lazy 容器行闭包逃逸：行内读 app.currentPatientId / dataChange.metricsVersion，须自行包裹（子项目 I）
                                WithPerceptionTracking {
                                    MetricTile(item: item,
                                               // 成员纳入 task id（审查修复）：仅按 metricKey
                                               // 作 id 时，A→B 切换成员后 tile 身份不变、
                                               // @State spark 不重载——A 的 30 天迷你线
                                               // 挂在 B 名下（BR-001 同族）
                                                taskId: "\(app.currentPatientId.uuidString)-\(item.metricKey)-\(dataChange.metricsVersion)",
                                               sparkLoader: { key in
                                        guard let m = MetricType(rawValue: key) else { return nil }
                                        // 30 天窗经 Domain 单一出口（`TrendTimeWindow.month`）：
                                        // 此前视图内联 `DayArithmetic.offset(days: -30)` 是第二份
                                        // 窗长字面量，改档位天数即与详情页漂移；锚点同详情页
                                        // = 今天（第 1 项「起点是当前日期」），宫格与详情页
                                        // 对同一成员说同一段窗口。
                                        let range = TrendTimeWindow.month.period(endingAt: Date())
                                        return try? await state.store.series(for: app.currentPatientId,   // try?-ok: tile 迷你趋势读取失败只不画线，不阻断宫格
                                                                             metric: m,
                                                                             range: range)
                                    },
                                               onSelect: {
                                        router.navigate(to: .trendChart(patientId: app.currentPatientId,
                                                                        metric: item.metricKey))
                                    })
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .tintedCanvas()   // ui-ux §3.0 surface/tint：渐变画布直挂（V4.06 修正）
                }
            }
            .navigationTitle(L10n.metricOverviewTitle)
            .toolbar {
                // §5.13 [按住说话] 顶部常驻（老年模式默认路径）——转写→确认→预填录入
                // 2026-10-05 业主反馈：去掉右上角 [录入] 增加按钮（导航栏单主行动；
                // 手输入口仍在时间轴/语音面板，空态保留引导按钮）——
                // 路由 metricQuickEntry 保留：语音确认流仍落它（FR17.13）。
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
            }
            .onAppear { routeMonitor.start() }
            // BR-001 成员切换：与 TrendEntryView/VoiceNotePanel 同款 task(id:)——
            // onAppear 只在首次挂载触发，切换成员后宫格仍显示上一成员的指标
            .task(id: "\(app.currentPatientId)-\(dataChange.metricsVersion)") {
                await state.loadLatest(patientId: app.currentPatientId)
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
}

/// §4.10 MetricTile：大数字 + 单位 + 来源点 + 30 天迷你趋势线
struct MetricTile: View {
    let item: TrendQueryStore.LatestMetric
    /// 迷你趋势加载任务 id（成员+指标键）——变化即重载 spark
    let taskId: String
    /// 30 天迷你趋势数据源（按 metricKey 独立查询——每 tile 各画各的线）
    let sparkLoader: (String) async -> TrendSeries?
    /// 2026-10-03 评审 R1-3：瓦片整体动作由调用方给——onTapGesture 无辅助功能动作，
    /// VoiceOver 不可激活（主要健康数据卡无障碍缺口）；Button 化同 BigCareCard 先例。
    let onSelect: () -> Void
    @State private var spark: TrendSeries?

    var body: some View {
        WithPerceptionTracking {
            Button(action: onSelect) {
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
                    // 设备标注已并入下方来源行（2026-10-03 评审 R1-4）：标题行不再重复两处来源信息
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // 医学数值显示单一出口（审查修复：此前内联 .formatted，
                    // 与趋势页 oneDecimal 双规则漂移——同一值宫格显示 62、
                    // 趋势页显示 62.0）；2026-10-05 业主反馈修复批：位数定义
                    // 收敛 `MedicalNumberFormat.metricDisplay`（MetricType 键控表，
                    // 默认 2 位——「小数位数有个定义的地方」）。大数字字号收敛 VLFont 令牌。
                    Text(MedicalNumberFormat.metricDisplay(item.value, metric: MetricType(rawValue: item.metricKey)))
                        .font(VLFont.metricTileValue)
                        .monospacedDigit()
                    // 血压双值变体（ui-ux 4.10：收缩压/舒张压同瓦片）
                    if let secondary = item.secondaryValue,
                       MetricType(rawValue: item.metricKey) == .bloodPressureSys {
                        Text("/ \(MedicalNumberFormat.metricDisplay(secondary, metric: .bloodPressureDia))")
                            .font(VLFont.metricTileValue)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let unit = item.unit, !unit.isEmpty {
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
                // 2026-10-05 业主反馈修复批（瓦片等高）：值行是四槽骨架唯一无 lineLimit 的槽——
                // 长值（血压双值+单位）换行撑高瓦片，行间/屏间高低差即由此而来。缩放是
                // 布局手段，不触 §10/§3.3 缩放禁令（该禁令约束 scaleEffect 按压/持续动效）。
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // 2026-10-03 评审 R1-4：4 处 caption2 元信息压 2 行——聚合与来源并入一行
                // （设备来源以「设备」前缀标注），一瞥只给 值/方向/来源/时间
                // （iOS 27.2 Health 改版同向的「信息分层收敛」，迁移的是分层非控件）。
                // round2 ⑤a：固定四槽骨架（标题/数值/元信息恒一行/迷你图槽恒 32pt）——
                // 槽位恒定即瓦片等高；元信息缺失时该行仅时间（时间并入此行）；
                // 迷你图无数据渲染空槽（可选元素不再撑出高低差）。
                let metaParts = [item.aggregation.map { L10n.healthAggregation($0) },
                                 item.sourceName.map { item.origin == "device" ? "\(L10n.trendOriginDevice) · \($0)" : $0 }].compactMap { $0 }
                Text((metaParts + [item.measuredAt.formatted(date: .abbreviated, time: .shortened)])
                        .joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Group {
                    if let spark, !spark.points.isEmpty {
                        Chart(spark.points) { p in
                            PointMark(x: .value("t", p.measuredAt), y: .value("v", p.value))
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                    }
                }
                .frame(height: 32)
            }
            .padding(12)
            .glassCard(cornerRadius: VLCornerRadius.compact)   // §3.3 表面阶梯 L2（V4.05：常态无阴影）
            .task(id: taskId) {
                // 换成员/换指标即清空上一次的迷你线：taskId 变化后新查询完成前，
                // 旧成员的 30 天线不得挂在新成员的数字下（BR-001 同族——瓦片按
                // metricKey 作 id，成员切换时瓦片实例不变，@State spark 会被沿用）
                spark = nil
                let loaded = await sparkLoader(item.metricKey)
                guard !Task.isCancelled else { return }
                spark = loaded
            }
            }
            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metricName)
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("SP-13.overview.tile.\(item.metricKey)")
        }
    }

    /// 朗读值（血压双值/单位同视觉行——纯事实，无判断词）；
    /// 2026-10-05：与可见文本同用 metricDisplay 出口（同 oneDecimal 纪律——二者不得漂移）。
    private var accessibilityValue: String {
        var s = MedicalNumberFormat.metricDisplay(item.value, metric: MetricType(rawValue: item.metricKey))
        if let secondary = item.secondaryValue,
           MetricType(rawValue: item.metricKey) == .bloodPressureSys {
            s += " / \(MedicalNumberFormat.metricDisplay(secondary, metric: .bloodPressureDia))"
        }
        if let unit = item.unit, !unit.isEmpty { s += " \(unit)" }
        return s
    }

    private var metricName: String {
        if let m = MetricType(rawValue: item.metricKey) { return L10n.metricName(m) }
        // 规则①死代码清除：裸 metricKey 回落标签不可达（两条加载路径均按
        // MetricType 注册表过滤）且会把 snake_case raw 键泄漏进中文界面——
        // 未知键不渲染任何文案（比泄漏更诚实）
        return ""
    }
}
