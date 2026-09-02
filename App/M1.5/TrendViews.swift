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
struct TrendChartView: View {
    let series: TrendSeries
    /// 显示已排除点对照视图（FR7.4 软删可恢复）
    var showExcluded: Bool = false
    /// 选点回原报告（sourceRef → 深链）；nil 时点不可跳转
    var onOpenSource: ((TrendPoint) -> Void)?
    /// 排除 / 恢复
    var onToggleExcluded: ((TrendPoint) -> Void)?

    @State private var selectedDate: Date?

    /// 参考带用同一中性色的不同不透明度区分来源——避免语义色（BR-006），
    /// 同时保证色觉障碍下仍可经图例文字辨识（无障碍不依赖颜色单通道）。
    private func bandOpacity(_ index: Int) -> Double {
        let steps = [0.30, 0.22, 0.16, 0.12]
        return steps[min(index, steps.count - 1)]
    }

    private var selectedPoint: TrendPoint? {
        guard let selectedDate else { return nil }
        return series.points.min {
            abs($0.measuredAt.timeIntervalSince(selectedDate))
                < abs($1.measuredAt.timeIntervalSince(selectedDate))
        }
    }

    private var xDomainStart: Date { series.points.first?.measuredAt ?? Date() }
    private var xDomainEnd: Date { series.points.last?.measuredAt ?? Date() }

    var body: some View {
        // 轴标签在 ForEach 内逐点求值 = 每个数据点走一次 NSLocalizedString
        // （一年日测约 730 点，且拖动 chartXSelection 时每帧重算 body）。
        // 循环不变量提到外层，求值一次。
        let axisTime = L10n.trendAxisTime
        let axisValue = L10n.trendAxisValue
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                // ① 多来源参考带：逐条独立绘制（FR7.2）
                ForEach(Array(series.referenceBands.enumerated()), id: \.element.id) { index, band in
                    RectangleMark(
                        xStart: .value(L10n.trendAxisStart, xDomainStart),
                        xEnd: .value(L10n.trendAxisEnd, xDomainEnd),
                        yStart: .value(L10n.trendAxisLower, band.lower),
                        yEnd: .value(L10n.trendAxisUpper, band.upper)
                    )
                    .foregroundStyle(Color("surface-tint-start", bundle: .main)
                        .opacity(bandOpacity(index)))
                    .accessibilityLabel(L10n.trendBandAccessibility(band.sourceLabel, MedicalNumberFormat.oneDecimal(band.lower), MedicalNumberFormat.oneDecimal(band.upper)))
                }
                // ② 已排除点对照（虚线空心，视觉上明确「不参与」）
                if showExcluded {
                    ForEach(series.excludedPoints) { point in
                        PointMark(x: .value(axisTime, point.measuredAt), y: .value(axisValue, point.value))
                            .symbolSize(90)
                            .foregroundStyle(Color("text-tertiary", bundle: .main).opacity(0.5))
                            .symbol(.cross)
                            .accessibilityLabel(L10n.trendExcludedAccessibility(MedicalNumberFormat.oneDecimal(point.value)))
                    }
                }
                // ③ 数据点：实心=医院、空心=自测/设备
                ForEach(TrendRules.sorted(series.points)) { point in
                    PointMark(x: .value(axisTime, point.measuredAt), y: .value(axisValue, point.value))
                        .symbolSize(120)
                        .foregroundStyle(point.isHollow
                            ? Color("bg-grouped", bundle: .main)
                            : Color("brand-primary", bundle: .main))
                        .symbol(.circle)
                }
                // ④ 选中点竖线（chartXSelection 气泡锚点）
                if let selectedPoint {
                    RuleMark(x: .value(L10n.trendAxisSelected, selectedPoint.measuredAt))
                        .foregroundStyle(Color("text-tertiary", bundle: .main).opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 200)
            .accessibilityIdentifier("SP-13.trend.chart")
            .accessibilityLabel(L10n.trendChartAccessibility(series.metricType.rawValue, series.points.count, series.referenceBands.count))

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
                            Text(L10n.trendBandLegend(band.sourceLabel, MedicalNumberFormat.oneDecimal(band.lower), MedicalNumberFormat.oneDecimal(band.upper)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("SP-13.trend.band.legend")
                    }
                }
            }

            // 选点气泡：值/单位/医院/参考范围/日期（ui-ux §5.37 五要素）
            if let p = selectedPoint {
                TrendPointBubble(point: p, onOpenSource: onOpenSource)
            }

            // 数据列表并存（VoiceOver 主通道）
            ForEach(TrendRules.sorted(series.points)) { point in
                TrendPointRow(point: point, isExcluded: false,
                              onOpenSource: onOpenSource, onToggleExcluded: onToggleExcluded)
            }
            if showExcluded && !series.excludedPoints.isEmpty {
                Divider()
                Text(L10n.trendExcludedHeader)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-13.trend.excluded.header")
                ForEach(TrendRules.sorted(series.excludedPoints)) { point in
                    TrendPointRow(point: point, isExcluded: true,
                                  onOpenSource: onOpenSource, onToggleExcluded: onToggleExcluded)
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
            Text(point.isHollow ? L10n.trendOriginSelfDevice : (point.refSourceLabel ?? L10n.trendOriginHospital))
                .font(.caption2).foregroundStyle(.secondary)
            if let lo = point.refLow, let hi = point.refHigh {
                Text(L10n.trendRefRange(MedicalNumberFormat.oneDecimal(lo), MedicalNumberFormat.oneDecimal(hi)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if point.sourceRef != nil, let onOpenSource {
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
        .accessibilityIdentifier("SP-13.trend.bubble")
    }
}

/// 数据行（VoiceOver 主通道 + 排除/恢复动作）
private struct TrendPointRow: View {
    let point: TrendPoint
    let isExcluded: Bool
    var onOpenSource: ((TrendPoint) -> Void)?
    var onToggleExcluded: ((TrendPoint) -> Void)?

    var body: some View {
        HStack {
            Circle()
                .fill(point.isHollow ? Color.clear : Color("brand-primary", bundle: .main))
                .overlay(Circle().strokeBorder(Color("brand-primary", bundle: .main), lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .opacity(isExcluded ? 0.4 : 1)
            Text(point.measuredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote)
            Spacer()
            Text("\(MedicalNumberFormat.oneDecimal(point.value)) \(point.unit ?? "")")
                .font(.footnote).monospacedDigit()
                .strikethrough(isExcluded)
            if point.isHollow {
                Text(L10n.trendSelfMeasured).font(.caption2).foregroundStyle(.secondary)
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
                .buttonStyle(.plain)
                .accessibilityLabel(isExcluded ? L10n.trendRestorePoint : L10n.trendExcludePoint)
                .accessibilityIdentifier(isExcluded ? "SP-13.trend.restore" : "SP-13.trend.exclude")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isExcluded { onOpenSource?(point) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.trendRowAccessibility(MedicalNumberFormat.oneDecimal(point.value), point.unit ?? "", point.isHollow ? L10n.trendOriginSelfShort : (point.refSourceLabel ?? L10n.trendOriginHospitalShort), point.measuredAt.formatted(date: .abbreviated, time: .shortened)) + (isExcluded ? L10n.trendRowExcludedSuffix : ""))
        .accessibilityIdentifier(isExcluded ? "SP-13.trend.point.excluded" : "SP-13.trend.point")
    }
}

/// 双来源趋势页面壳（数据经 TrendQueryStore 注入；换算注记随 series 呈现）
struct TrendDetailView: View {
    let series: TrendSeries
    var conversionNote: String?
    var onOpenSource: ((TrendPoint) -> Void)?
    var onToggleExcluded: ((TrendPoint) -> Void)?

    @State private var showExcluded = false

    var body: some View {
        ScrollView {
            TrendChartView(series: series,
                           showExcluded: showExcluded,
                           onOpenSource: onOpenSource,
                           onToggleExcluded: onToggleExcluded)
            if let note = conversionNote {
                Text(L10n.trendConvertedFrom(note))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-13.trend.conversion")
            }
        }
        .navigationTitle(L10n.trendTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showExcluded) {
                    HStack(spacing: 4) {
                        VLIcon.filter.resizable().frame(width: 18, height: 18)
                        Text(L10n.trendShowExcluded)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .toggleStyle(.button)
                .accessibilityLabel(L10n.trendShowExcludedAccessibility)
                .accessibilityIdentifier("SP-13.trend.excluded.toggle")
            }
        }
    }
}
