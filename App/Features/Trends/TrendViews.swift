import SwiftUI
import Charts
import Domain

/// F7 指标趋势（SP-13 / ui-ux §5.37）：Swift Charts（ADR-022）。
///
/// 四条渲染铁律：
/// 1. **FR7.2**：不同医院的参考范围各自成独立半透明横带，**绝不合并**；图例标注来源名。
/// 2. **ui-ux 4.7**：医院实心点 / 自测·设备空心点（描边可见，非透明填充）。
/// 3. **BR-006**：参考带一律中性色——不得用红/绿等语义色暗示「超标/正常」判断。
/// 4. 图表旁的数据列表是 VoiceOver 主通道，不依赖图形可读性。
///
/// round2 H4（子项目 C7）：按指标选图型（TrendMarkFamily：步数日柱 / 心率均值折线+min·max 区间 /
/// 睡眠时长柱 / 血压成对点 / 其余点）；保极值降采样只作用于图形（列表仍全量、惰性）；
/// 可见时间窗经 chartXVisibleDomain；空心点带描边。全部为统计呈现，不含阈值判定（BR-003/004）。
struct TrendChartView: View {
    let series: TrendSeries
    /// 可见时间窗（chartXVisibleDomain 长度；数据范围优先取 series.identity.range）
    var window: TrendTimeWindow = .year
    /// 选点回原报告（sourceRef → 深链）；nil 时点不可跳转
    var onOpenSource: ((TrendPoint) -> Void)?
    /// 排除 / 恢复
    var onToggleExcluded: ((TrendPoint) -> Void)?

    @State private var selectedDate: Date?
    /// 已排除点是否叠加到图上（对照视图；默认不叠加——被排除点通常是 OCR 错值，
    /// 画回图上会拉爆 Y 轴并让错值重新以图形事实出现）。开关放在「已排除」分段
    /// 内部（贴着它作用的数据），不在工具栏——原工具栏模式按钮「语义不明、
    /// 不知道用意」（业主 2026-09-16 第 2 项）。
    @State private var showsExcludedOnChart = false

    /// 参考带用同一中性色的不同不透明度区分来源——避免语义色（BR-006），
    /// 同时保证色觉障碍下仍可经图例文字辨识（无障碍不依赖颜色单通道）。
    /// 参考带来源标签：空串（Domain 缺失来源，不臆造文案）→ L10n 缺省标签
    private func bandLabel(_ source: String) -> String {
        source.isEmpty ? L10n.trendBandUnlabeled : source
    }

    private func bandOpacity(_ index: Int) -> Double {
        let steps = [0.30, 0.22, 0.16, 0.12]
        return steps[min(index, steps.count - 1)]
    }

    /// 来源图例行：医院实心 / 自测·设备空心（ui-ux 4.7 同款符号语义）
    private func originLegendRow(solid: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(solid ? Color("brand-primary", bundle: .main) : Color.clear)
                .overlay(Circle().strokeBorder(Color("brand-primary", bundle: .main), lineWidth: 1.5))
                .frame(width: 12, height: 12)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var selectedPoint: TrendPoint? {
        guard let selectedDate else { return nil }
        return series.points.min {
            abs($0.measuredAt.timeIntervalSince(selectedDate))
                < abs($1.measuredAt.timeIntervalSince(selectedDate))
        }
    }

    /// 同一时刻可有多条来源行（设备按来源分小时聚合，measured_at 同为窗口左边界）：
    /// 选点按时刻命中全部并列点，每条统计都可查看（二轮复审 P2）。
    private var selectedPoints: [TrendPoint] {
        guard let nearest = selectedPoint else { return [] }
        // 审查修复：并列点按 exact Date == 过滤——同刻不同源的行时间戳
        // 常有秒级差异（设备整点窗口 vs 页面捕获时刻），注释承诺的
        // 「全部并列点」落空、该来源行在选点详情中不可见。60 秒容差
        // 收敛同刻行；跨读数（小时/日粒度）不受影响。
        let tolerance: TimeInterval = 60
        return TrendRules.sorted(series.points.filter {
            abs($0.measuredAt.timeIntervalSince(nearest.measuredAt)) <= tolerance
        })
    }

    private var xDomainStart: Date { series.points.first?.measuredAt ?? Date() }
    private var xDomainEnd: Date { series.points.last?.measuredAt ?? Date() }

    /// H4 按图型族生成数据标记。独立 @ChartContentBuilder 函数而非 Chart 闭包内联 switch——
    /// TN3211：Chart 闭包内多分支 buildEither 候选集超线性增长，可能超出类型检查预算
    /// （本仓 CI 已有「unable to type-check in reasonable time」实证族），抽出隔离。
    @ChartContentBuilder
    private func dataMarks(_ family: TrendMarkFamily, points: [TrendPoint],
                           axisTime: String, axisValue: String, tint: Color,
                           maxGap: TimeInterval) -> some ChartContent {
        switch family {
        case .dailyBars, .durationBars:
            // 步数日总量 / 睡眠时长：按日柱；设备/自测行沿用「空心」语义以降低不透明度区分
            ForEach(points) { point in
                BarMark(x: .value(axisTime, point.measuredAt, unit: .day),
                        y: .value(axisValue, point.value))
                    .foregroundStyle(tint.opacity(point.isHollow ? 0.55 : 1))
            }
        case .hourlyRange:
            // 心率小时窗：均值折线 + min/max 区间带（区间只呈现窗口内统计范围，非参考范围）。
            // 数据诚实四铁律（gap 断线不插值）：小时窗天然稀疏（本批 sparseWindows 即首类公民），
            // 缺测小时之间必须断线——按相邻点时间差 > maxGap 切段；maxGap 由窗口与桶宽决定
            // （TrendDownsampler.gapThreshold）：写成常量 1.5h 时，降采样后的 1 年心率
            // （桶宽 ≈ 1.5 天）每个保留点都会被判成新段，折线与区间带整条消失。
            ForEach(Array(Self.contiguousSegments(points, maxGap: maxGap).enumerated()), id: \.offset) { _, segment in
                ForEach(segment) { point in
                    if let low = point.valueMin, let high = point.valueMax {
                        // Swift Charts 无 RangeMark（CI 34748416488 实证编译错误族）：
                        // min/max 区间带用 AreaMark(yStart:yEnd:) 呈现，线性插值即可
                        // （带内只是窗口统计范围，非参考范围）。
                        AreaMark(x: .value(axisTime, point.measuredAt),
                                 yStart: .value(axisValue, low),
                                 yEnd: .value(axisValue, high))
                            .foregroundStyle(tint.opacity(0.25))
                    }
                    LineMark(x: .value(axisTime, point.measuredAt), y: .value(axisValue, point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                }
            }
        case .points, .pairedPoints:
            // 离散读数 / 血压（sys·dia 双序列由路由按 metric 成对加载）
            ForEach(points) { point in
                pointMark(point, axisTime: axisTime, axisValue: axisValue, tint: tint)
            }
        }
    }

    /// 连续段切分（数据诚实 gap 断线）：相邻点时间差 > maxGap 即断段。
    /// 纯函数（不读视图状态）——maxGap 由调用侧按窗口与桶宽给出
    /// （`TrendDownsampler.gapThreshold`）：短窗回落小时步长 ×1.5 = 5400s
    /// （覆盖 DST 边界；春令跳小时本身无数据，断线正确）。
    private static func contiguousSegments(_ points: [TrendPoint], maxGap: TimeInterval) -> [[TrendPoint]] {
        var segments: [[TrendPoint]] = []
        var current: [TrendPoint] = []
        for point in points {
            if let last = current.last, point.measuredAt.timeIntervalSince(last.measuredAt) > maxGap {
                segments.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// 实心=医院；空心=自测/设备——描边圆环（ui-ux 4.7「描边可见，非透明填充」；
    /// 旧实现用背景色实心圆冒充空心，无描边、浅色背景上不可辨）
    @ChartContentBuilder
    private func pointMark(_ point: TrendPoint, axisTime: String, axisValue: String, tint: Color) -> some ChartContent {
        if point.isHollow {
            PointMark(x: .value(axisTime, point.measuredAt), y: .value(axisValue, point.value))
                .symbolSize(120)
                .symbol(.circle.strokeBorder(lineWidth: 1.5))
                .foregroundStyle(tint)
        } else {
            PointMark(x: .value(axisTime, point.measuredAt), y: .value(axisValue, point.value))
                .symbolSize(120)
                .symbol(.circle)
                .foregroundStyle(tint)
        }
    }

    var body: some View {
        // 轴标签在 ForEach 内逐点求值 = 每个数据点走一次 NSLocalizedString
        // （一年日测约 730 点，且拖动 chartXSelection 时每帧重算 body）。
        // 循环不变量提到外层，求值一次。
        let axisTime = L10n.trendAxisTime
        let axisValue = L10n.trendAxisValue
        // 排序结果同样只求一次（审查修复：此前 Chart 数据点与数据列表
        // 各排一遍 O(n log n)，拖动选点时每帧两趟——曲线与列表永远同序，
        // 同一份排序即可）
        let sortedPoints = TrendRules.sorted(series.points)
        // H4：数据范围优先取查询身份（时间窗整段可见，不因数据只覆盖一段而收缩）；
        // 无身份的旧路径回落首末点。保极值降采样只作用于图形——心率一年小时窗 8760 点
        // → ≤ 482 点（240 桶 × min/max + 首尾），列表仍全量。
        let range = series.identity?.range ?? DateInterval(start: xDomainStart, end: xDomainEnd)
        let visible = TrendDownsampler.thin(sortedPoints, in: range, maxBuckets: TrendDownsampler.maxBuckets)
        // 折线断段阈值与桶宽同源（见 TrendDownsampler.gapThreshold 的说明）
        // 结构轮修复：窗口起止与可见域同源一份日历区间（TrendTimeWindow.interval，
        // DayArithmetic 出口）——此前两处各写 rawValue × 86400，DST 日与查询
        // 范围差 ±1h（裸 86400 违反全仓 DST 纪律）。
        let visibleInterval = window.interval(endingAt: range.end)
        let windowStart = visibleInterval.start
        let shown = ChartsCompat.supportsScrollableAxes ? visible : visible.filter { $0.measuredAt >= windowStart }   // iOS 16 只画窗口内点
        let family = TrendMarkFamily.family(for: series.metricType)
        let tint = Color("brand-primary", bundle: .main)
        // 断段阈值：**未降采样时不得用桶宽**（桶宽是「若抽稀会用的粒度」，
        // 与数据实际间距无关——90 天窗内 200 条小时读数会被 13.5 h 阈值
        // 跨 12 h 缺测连成一条插值线，违反「缺测不插值」）
        let maxGap = TrendDownsampler.gapThreshold(range: range, pointCount: sortedPoints.count)
        VStack(alignment: .leading, spacing: 12) {
            // 可见读数全部被排除时的事实句：否则图表区空白且无任何解释
            // （原实现靠工具栏开关的 onAppear 副作用兜底，切窗后不再触发）
            if sortedPoints.isEmpty, !series.excludedPoints.isEmpty {
                Text(L10n.trendExcludedAllExcluded)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-13.trend.excluded.allExcluded")
            }
            Chart {
                // ① 多来源参考带：逐条独立绘制（FR7.2）
                ForEach(Array(series.referenceBands.enumerated()), id: \.element.id) { index, band in
                    RectangleMark(
                        xStart: .value(L10n.trendAxisStart, range.start),
                        xEnd: .value(L10n.trendAxisEnd, range.end),
                        yStart: .value(L10n.trendAxisLower, band.lower),
                        yEnd: .value(L10n.trendAxisUpper, band.upper)
                    )
                    .foregroundStyle(Color("surface-tint-start", bundle: .main)
                        .opacity(bandOpacity(index)))
                    .accessibilityLabel(L10n.trendBandAccessibility(bandLabel(band.sourceLabel), MedicalNumberFormat.oneDecimal(band.lower), MedicalNumberFormat.oneDecimal(band.upper)))
                }
                // ② 已排除点对照（叉号，视觉上明确「不参与」）：默认不叠加到图上，
                // 由「已排除」分段内的显式开关开启（被排除点通常是 OCR 错值——
                // 画回图上会拉爆 Y 轴，也让已知错值重新以图形事实出现）
                if showsExcludedOnChart {
                    ForEach(series.excludedPoints) { point in
                        PointMark(x: .value(axisTime, point.measuredAt), y: .value(axisValue, point.value))
                            .symbolSize(90)
                            .foregroundStyle(Color("text-tertiary", bundle: .main).opacity(0.5))
                            .symbol(.cross)
                            .accessibilityLabel(L10n.trendExcludedAccessibility(MedicalNumberFormat.oneDecimal(point.value)))
                    }
                }
                // ③ 数据标记：按指标图型族（H4）——分支抽出为独立 @ChartContentBuilder 函数
                dataMarks(family, points: shown, axisTime: axisTime, axisValue: axisValue,
                          tint: tint, maxGap: maxGap)
                // ④ 选中点竖线（chartXSelection 气泡锚点）
                if let selectedPoint {
                    RuleMark(x: .value(L10n.trendAxisSelected, selectedPoint.measuredAt))
                        .foregroundStyle(Color("text-tertiary", bundle: .main).opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            // H4：横向可滚动 + 可见域 = 所选时间窗（iOS 17 原生；iOS 16 由 App/Compat 垫片钉窗口 + 拖动选点）
            .chartWindowCompat(visibleLength: visibleInterval.duration, domainEnd: range.end, selection: $selectedDate)
            .frame(height: 200)
            .accessibilityIdentifier("SP-13.trend.chart")
            .accessibilityLabel(L10n.trendChartAccessibility(L10n.metricName(series.metricType), series.points.count, series.referenceBands.count))

            // 参考带图例：来源名必须可读——「各自显示」的可验证出口
            if series.referenceBands.isEmpty {
                Text(L10n.trendRangeUnavailable)
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-13.trend.range.unavailable")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(series.referenceBands.enumerated()), id: \.element.id) { index, band in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color("surface-tint-start", bundle: .main)
                                    .opacity(bandOpacity(index)))
                                .frame(width: 18, height: 12)
                            Text(L10n.trendBandLegend(bandLabel(band.sourceLabel), MedicalNumberFormat.oneDecimal(band.lower), MedicalNumberFormat.oneDecimal(band.upper)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("SP-13.trend.band.legend")
                    }
                }
            }

            // 来源图例（ui-ux §5.45 V3.53 设备来源行）：医院实心 / 自测空心 /
            // 设备自动空心+标注——只渲染序列中存在的来源（未连接设备时
            // 不渲染设备占位）；色觉障碍可经文字辨识（无障碍不依赖颜色）
            let origins = Set(series.points.map(\.origin))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.trendOriginLegend).font(.caption2).foregroundStyle(.secondary)
                if origins.contains(.hospital) {
                    originLegendRow(solid: true, label: L10n.trendOriginHospital)
                }
                if origins.contains(.manual) {
                    originLegendRow(solid: false, label: L10n.trendSelfMeasured)
                }
                if origins.contains(.device) {
                    originLegendRow(solid: false, label: L10n.trendOriginDevice)
                }
            }
            .accessibilityIdentifier("SP-13.trend.origin.legend")

            // 选点气泡：值/单位/医院/参考范围/日期（ui-ux §5.37 五要素）；
            // 同时刻多来源行各出一张气泡，不只取首个并列点
            ForEach(selectedPoints) { p in
                TrendPointBubble(point: p, onOpenSource: onOpenSource)
            }

            // 数据列表并存（VoiceOver 主通道）——全量、惰性构建（H4：一年小时窗数千行
            // 在外层 ScrollView 内按需实例化，不随图表降采样）
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sortedPoints) { point in
                    TrendPointRow(point: point, isExcluded: false,
                                  onOpenSource: onOpenSource, onToggleExcluded: onToggleExcluded)
                }
            }
            // 已排除点分段：**恒渲染**（不再由工具栏模式开关门控）。
            // FR7.4「原记录可见可恢复」由构造保证——排除最后一个可见读数后，
            // 恢复入口不可能消失（原实现靠 onAppear 副作用打开对照视图，
            // 本页原地刷新时不再触发，用户会看到空白图表且找不到恢复入口）。
            if !series.excludedPoints.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Text(L10n.trendExcludedHeader(series.excludedPoints.count))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-13.trend.excluded.header")
                    Spacer()
                    Button(showsExcludedOnChart ? L10n.trendExcludedHideFromChart
                                                : L10n.trendExcludedShowOnChart) {
                        showsExcludedOnChart.toggle()
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("SP-13.trend.excluded.chartToggle")
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(TrendRules.sorted(series.excludedPoints)) { point in
                        TrendPointRow(point: point, isExcluded: true,
                                      onOpenSource: onOpenSource, onToggleExcluded: onToggleExcluded)
                    }
                }
            }
        }
        .padding(16)
    }
}

/// 选点气泡（ui-ux §5.37）：值 / 单位 / 医院 / 参考范围 / 日期 + [回原报告]
private struct TrendPointBubble: View {
    let point: TrendPoint
    var onOpenSource: ((TrendPoint) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(MedicalNumberFormat.oneDecimal(point.value)) \(point.unit ?? "")")
                .font(.title3).monospacedDigit()
            Text(point.measuredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
            if let aggregation = point.aggregation {
                Text(L10n.healthAggregation(aggregation)).font(.caption)
            }
            if let end = point.windowEnd, point.aggregation != .sample {
                Text(L10n.healthWindowEnd(end.formatted(date: .abbreviated, time: .shortened))).font(.caption2)
            }
            if let source = point.sourceName { Text(source).font(.caption2) }
            if let low = point.valueMin, let high = point.valueMax, let count = point.sampleCount {
                Text(L10n.healthWindowStatistics(MedicalNumberFormat.quantity(low), MedicalNumberFormat.quantity(high), count))
                    .font(.caption2)
            }
            Text(point.origin == .device ? L10n.trendOriginDevice
                 : (point.isHollow ? L10n.trendSelfMeasured
                    : (point.refSourceLabel ?? L10n.trendOriginHospital)))
                .font(.caption2).foregroundStyle(.secondary)
            if let lo = point.refLow, let hi = point.refHigh {
                Text(L10n.trendRefRange(MedicalNumberFormat.oneDecimal(lo), MedicalNumberFormat.oneDecimal(hi)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if point.origin == .hospital, point.sourceRef != nil, let onOpenSource {
                Button {
                    onOpenSource(point)
                } label: {
                    HStack(spacing: 6) {
                        VLIcon.externalLink.resizable().frame(width: 18, height: 18)
                        Text(L10n.trendOpenSource).font(.caption)
                    }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("SP-13.trend.openSource")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-13.trend.bubble")
    }
}

/// 数据行（VoiceOver 主通道 + 排除/恢复动作）
private struct TrendPointRow: View {
    let point: TrendPoint
    let isExcluded: Bool
    var onOpenSource: ((TrendPoint) -> Void)?
    var onToggleExcluded: ((TrendPoint) -> Void)?

    /// 设备统计行的来源/统计类型/极值与样本数（二轮复审 P2：同小时多来源行
    /// 只有首个并列点可经气泡查看——列表行必须自带这些事实，每条汇总都可核对）
    private var statisticsLine: String? {
        var parts: [String] = []
        if let aggregation = point.aggregation, aggregation != .sample {
            parts.append(L10n.healthAggregation(aggregation))
        }
        if let source = point.sourceName, point.origin == .device { parts.append(source) }
        if let low = point.valueMin, let high = point.valueMax, let count = point.sampleCount {
            parts.append(L10n.healthWindowStatistics(MedicalNumberFormat.quantity(low),
                                                     MedicalNumberFormat.quantity(high), count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            Circle()
                .fill(point.isHollow ? Color.clear : Color("brand-primary", bundle: .main))
                .overlay(Circle().strokeBorder(Color("brand-primary", bundle: .main), lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .opacity(isExcluded ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.measuredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                if let statisticsLine {
                    Text(statisticsLine)
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-13.trend.point.statistics")
                }
            }
            Spacer()
            Text("\(MedicalNumberFormat.oneDecimal(point.value)) \(point.unit ?? "")")
                .font(.footnote).monospacedDigit()
                .strikethrough(isExcluded)
            if point.isHollow {
                // V3.53 §5.45 设备来源行：设备自动与自测同空心但标注区分
                Text(point.origin == .device ? L10n.trendOriginDevice : L10n.trendSelfMeasured)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // 显式动作按钮，不用 .swipeActions——本行不在 List 内，swipeActions
            // 会静默失效（ERR#32 同族：API 在错误容器里不报错也不生效）；
            // 且滑动手势对震颤/视障用户不可达，关怀模式要求 ≥44pt 显式触点。
            if let onToggleExcluded {
                Button {
                    onToggleExcluded(point)
                } label: {
                    (isExcluded ? VLIcon.undo : VLIcon.ban)
                        .resizable().frame(width: 20, height: 20)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                .accessibilityLabel(isExcluded ? L10n.trendRestorePoint : L10n.trendExcludePoint)
                .accessibilityIdentifier(isExcluded ? "SP-13.trend.restore" : "SP-13.trend.exclude")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isExcluded { onOpenSource?(point) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.trendRowAccessibility(MedicalNumberFormat.oneDecimal(point.value), point.unit ?? "", point.origin == .device ? L10n.trendOriginDevice : (point.isHollow ? L10n.trendOriginSelfShort : (point.refSourceLabel ?? L10n.trendOriginHospitalShort)), point.measuredAt.formatted(date: .abbreviated, time: .shortened)) + (isExcluded ? L10n.trendRowExcludedSuffix : ""))
        .accessibilityIdentifier(isExcluded ? "SP-13.trend.point.excluded" : "SP-13.trend.point")
    }
}

/// SP-13 睡眠整合页（FR7.11，业主 2026-09-16 第 3 项）：一晚一根**堆叠柱**
/// ——段色 = 阶段，柱高 = 各段时长之和——配一张文字可读的阶段图例，
/// 其下是逐夜列表（每晚一行：总时长 + 分段明细）与已排除夜分段（FR7.4 可恢复）。
///
/// 业界同款：Apple Health「睡眠」以堆叠柱区分 Awake/REM/Core/Deep（柱高 = 当夜
/// 各段之和），浅色/深色 + 文字图例双通道（色觉障碍不依赖颜色单通道）。
/// BR-006：段色是**分类编码**（阶段身份），不表达「睡得好/不好」的任何判断；
/// 阶段时间轴（真实发生顺序的 hypnogram）仍不绘制——存储只有每窗时长，
/// 不得从总量反造顺序（trend-visualization-module-spec §6.3 V1.5 边界）。
struct SleepTrendDetailView: View {
    let series: SleepTrendSeries
    /// round2 H4：所选时间窗（路由页分段控件下传，图表可见域随之）
    var window: TrendTimeWindow = .year
    var onToggleExcluded: ((SleepTrendNight, Bool) -> Void)?

    var body: some View {
        ScrollView {
            SleepTrendChartView(series: series, window: window, onToggleExcluded: onToggleExcluded)
        }
        .navigationTitle(L10n.trendSleepTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 睡眠堆叠柱 + 阶段图例 + 逐夜列表。
struct SleepTrendChartView: View {
    let series: SleepTrendSeries
    var window: TrendTimeWindow = .year
    /// (夜, 是否排除)：可见段传 true（排除该夜），已排除段传 false（恢复）
    var onToggleExcluded: ((SleepTrendNight, Bool) -> Void)?

    @State private var selectedDate: Date?

    /// 查询范围（身份回传；无身份时用夜集跨度兜底——不崩、不画错轴）
    private var range: DateInterval {
        if let identity = series.identity { return identity.range }
        let days = series.nights.map(\.day)
        guard let first = days.first, let last = days.last else { return DateInterval(start: Date(), duration: 0) }
        return DateInterval(start: first, end: DayArithmetic.offset(days: 1, from: last))
    }

    /// 本窗口出现过的阶段（图例只列存在的阶段，与来源图例同纪律）
    private var presentStages: [SleepStage] {
        let stages = Set(series.nights.flatMap { $0.slices.map(\.stage) })
        return stages.sorted { $0.trendStackOrder < $1.trendStackOrder }
    }

    /// 选中的夜（选点气泡锚点；按日最近命中）
    private var selectedNight: SleepTrendNight? {
        guard let selectedDate else { return nil }
        return series.nights.min {
            abs($0.day.timeIntervalSince(selectedDate)) < abs($1.day.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        let range = self.range
        let stages = presentStages
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(series.nights) { night in
                    ForEach(night.slices) { slice in
                        // BarMark 按样式维度分组即堆叠：x 同为「日」，各段自下而上
                        // 依次叠放（trendStack 顺序 = 图例顺序）
                        BarMark(x: .value(L10n.trendAxisTime, night.day, unit: .day),
                                y: .value(L10n.trendAxisValue, slice.hours))
                            .foregroundStyle(by: .value(L10n.trendSleepLegend, L10n.sleepStage(slice.stage)))
                    }
                }
                if let selectedNight {
                    RuleMark(x: .value(L10n.trendAxisSelected, selectedNight.day))
                        .foregroundStyle(Color("text-tertiary", bundle: .main).opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartForegroundStyleScale(domain: stages.map(L10n.sleepStage),
                                       range: stages.map(SleepStagePalette.color))
            // 图例自绘（不消失的内置图例）：标识可测、文字随应用语言、阶段名可读
            .chartLegend(.hidden)
            .chartWindowCompat(visibleLength: window.interval(endingAt: range.end).duration,
                               domainEnd: range.end, selection: $selectedDate)
            .frame(height: 200)
            .accessibilityIdentifier("SP-13.trend.sleep.chart")
            .accessibilityLabel(L10n.trendSleepChartAccessibility(series.nights.count,
                                                                 series.nights.reduce(0) { $0 + $1.slices.count }))
            .accessibilityElement(children: .contain)

            // 阶段图例：色块 + 阶段名 + 本窗口该阶段合计（可核对的量化出口）
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.trendSleepLegend).font(.caption2).foregroundStyle(.secondary)
                ForEach(stages, id: \.self) { stage in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(SleepStagePalette.color(stage))
                            .frame(width: 18, height: 12)
                        Text(L10n.sleepStageValue(stage, durationText(stageTotal(stage))))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("SP-13.trend.sleep.legend")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-13.trend.sleep.legends")

            // 选夜气泡：该夜的阶段明细（值/单位/来源口径同列表行）
            if let selectedNight {
                SleepNightBubble(night: selectedNight, unit: unit)
            }

            // 逐夜列表（VoiceOver 主通道）：全量、惰性
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(series.nights) { night in
                    SleepNightRow(night: night, unit: unit, isExcluded: false) {
                        onToggleExcluded?(night, true)
                    }
                }
            }

            // 已排除夜分段：**恒渲染**（FR7.4「原记录可见可恢复」由构造保证——
            // 排除最后一夜后恢复入口不可能消失）
            if !series.excludedNights.isEmpty {
                Divider()
                Text(L10n.trendExcludedHeader(series.excludedNights.count))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-13.trend.sleep.excluded.header")
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(series.excludedNights) { night in
                        SleepNightRow(night: night, unit: unit, isExcluded: true) {
                            onToggleExcluded?(night, false)
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private var unit: String {
        series.nights.compactMap(\.unit).first ?? series.excludedNights.compactMap(\.unit).first ?? ""
    }

    private func stageTotal(_ stage: SleepStage) -> Double {
        series.nights.reduce(0) { total, night in
            total + (night.slices.first { $0.stage == stage }?.hours ?? 0)
        }
    }

    private func durationText(_ hours: Double) -> String {
        let text = MedicalNumberFormat.oneDecimal(hours)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }
}

/// 睡眠阶段配色（分类编码，FR7.11 图例的色通道；BR-006：不表达优劣）。
/// 令牌在 Assets（sleep-***），浅色/深色各一档——不写死色值（设计系统纪律）。
enum SleepStagePalette {
    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .deep: return Color("sleep-deep", bundle: .main)
        case .core: return Color("sleep-core", bundle: .main)
        case .rem: return Color("sleep-rem", bundle: .main)
        case .awake: return Color("sleep-awake", bundle: .main)
        case .unspecified: return Color("sleep-unspecified", bundle: .main)
        case .inBed: return Color("sleep-unspecified", bundle: .main)
        }
    }
}

/// 选夜气泡：日期 + 总时长 + 逐段时长（与列表行同一数字出口）
private struct SleepNightBubble: View {
    let night: SleepTrendNight
    let unit: String

    private var total: Double { night.asleepHours ?? night.stackedHours }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(unit.isEmpty ? MedicalNumberFormat.oneDecimal(total)
                              : "\(MedicalNumberFormat.oneDecimal(total)) \(unit)")
                .font(.title3).monospacedDigit()
            Text(L10n.trendDate(night.day))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(night.slices) { slice in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SleepStagePalette.color(slice.stage))
                        .frame(width: 10, height: 10)
                    Text(L10n.sleepStageValue(slice.stage, MedicalNumberFormat.oneDecimal(slice.hours)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-13.trend.sleep.bubble")
    }
}

/// 逐夜行：日期 + 总时长 + 分段明细 + 排除/恢复动作
private struct SleepNightRow: View {
    let night: SleepTrendNight
    let unit: String
    let isExcluded: Bool
    var onToggle: (() -> Void)?

    private var total: Double { night.asleepHours ?? night.stackedHours }

    private var breakdown: String {
        night.slices
            .map { L10n.sleepStageValue($0.stage, MedicalNumberFormat.oneDecimal($0.hours)) }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.trendDate(night.day)).font(.footnote)
                if !breakdown.isEmpty {
                    Text(breakdown)
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-13.trend.sleep.breakdown")
                }
            }
            Spacer()
            Text(unit.isEmpty ? MedicalNumberFormat.oneDecimal(total)
                              : "\(MedicalNumberFormat.oneDecimal(total)) \(unit)")
                .font(.footnote).monospacedDigit()
                .strikethrough(isExcluded)
            if let onToggle {
                Button(action: onToggle) {
                    (isExcluded ? VLIcon.undo : VLIcon.ban)
                        .resizable().frame(width: 20, height: 20)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                .contentShape(Rectangle())
                .accessibilityLabel(isExcluded ? L10n.trendRestorePoint : L10n.trendExcludePoint)
                .accessibilityIdentifier(isExcluded ? "SP-13.trend.sleep.restore" : "SP-13.trend.sleep.exclude")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isExcluded ? "SP-13.trend.sleep.night.excluded" : "SP-13.trend.sleep.night")
    }
}

/// 双来源趋势页面壳（数据经 TrendQueryStore 注入）。
/// 审查修复：conversionNote 参数与渲染块删除——状态层恒 nil 的换算注记
/// 曾是「管道齐全但用户永远看不到」的假接线（FR7.8 留痕待查询层
/// 换算注记真正产出时再挂回，接点即此壳）。
struct TrendDetailView: View {
    let series: TrendSeries
    /// round2 H4：所选时间窗（路由页分段控件下传，图表可见域随之）
    var window: TrendTimeWindow = .year
    var onOpenSource: ((TrendPoint) -> Void)?
    var onToggleExcluded: ((TrendPoint) -> Void)?

    var body: some View {
        ScrollView {
            TrendChartView(series: series,
                           window: window,
                           onOpenSource: onOpenSource,
                           onToggleExcluded: onToggleExcluded)
        }
        .navigationTitle(L10n.trendTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
