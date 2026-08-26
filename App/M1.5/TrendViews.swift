import SwiftUI
import Charts
import Domain

/// F7 指标趋势（SP-13）：Swift Charts（ADR-022）——
/// RuleMark 参考带、PointMark 空心/实心双来源、chartXSelection 选点。
/// 图表旁数据列表是 VoiceOver 主通道（ui-ux 5.37 无障碍兜底）。
struct TrendChartView: View {
    let series: TrendSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                if let range = series.referenceRange {
                    RuleMark(y: .value("上限", range.upper))
                        .foregroundStyle(Color("semantic-warning", bundle: .main).opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    RuleMark(y: .value("下限", range.lower))
                        .foregroundStyle(Color("semantic-warning", bundle: .main).opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
                ForEach(TrendRules.sorted(series.points)) { point in
                    PointMark(
                        x: .value("时间", point.measuredAt),
                        y: .value("值", point.value)
                    )
                    .symbolSize(56)
                    .foregroundStyle(point.isHollow ? Color.clear : Color("brand-primary", bundle: .main))
                    .symbol(point.isHollow ? .circle : .circle)   // 实心=医院/空心=自测（描边空心）
                    .annotation(position: .top) {
                        if point.isHollow {
                            Text("\(point.value, specifier: "%.1f")")
                                .font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 200)
            .accessibilityLabel("\(series.metricType.rawValue) 趋势图，共 \(series.points.count) 个数据点")

            // 数据列表并存（VoiceOver 主通道）
            ForEach(TrendRules.sorted(series.points)) { point in
                HStack {
                    Circle()
                        .fill(point.isHollow ? Color.clear : Color("brand-primary", bundle: .main))
                        .overlay(Circle().strokeBorder(Color("brand-primary", bundle: .main), lineWidth: 1))
                        .frame(width: 10, height: 10)
                    Text(point.measuredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                    Spacer()
                    Text("\(point.value, specifier: "%.1f")")
                        .font(.footnote).monospacedDigit()
                    if point.isHollow {
                        Text("自测").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("SP-13.trend.point")
            }
        }
        .padding(16)
    }
}

/// 双来源趋势页面壳（数据经 TrendQueryStore 注入；换算注记随 series 呈现）
struct TrendDetailView: View {
    let series: TrendSeries
    var conversionNote: String?

    var body: some View {
        ScrollView {
            TrendChartView(series: series)
            if let note = conversionNote {
                Text("换算自 \(note)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-13.trend.conversion")
            }
        }
        .navigationTitle("指标趋势")
        .navigationBarTitleDisplayMode(.inline)
    }
}
