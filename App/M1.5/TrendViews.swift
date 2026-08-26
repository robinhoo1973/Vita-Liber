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
                    RectangleMark(
                        xStart: .value("起", series.points.first?.measuredAt ?? Date()),
                        xEnd: .value("止", series.points.last?.measuredAt ?? Date()),
                        yStart: .value("下限", range.lower),
                        yEnd: .value("上限", range.upper)
                    )
                    .foregroundStyle(Color("surface-tint-start", bundle: .main).opacity(0.35))
                    .accessibilityLabel("参考范围 \(range.lower)-\(range.upper)")
                }
                ForEach(TrendRules.sorted(series.points)) { point in
                    PointMark(
                        x: .value("时间", point.measuredAt),
                        y: .value("值", point.value)
                    )
                    .symbolSize(120)
                    .foregroundStyle(point.isHollow
                        ? Color("bg-grouped", bundle: .main)
                        : Color("brand-primary", bundle: .main))
                    .symbol(.circle)
                }
            }
            .frame(height: 200)
            .accessibilityLabel("\(series.metricType.rawValue) 趋势图，共 \(series.points.count) 个数据点")

            // 数据列表并存（VoiceOver 主通道）
            ForEach(TrendRules.sorted(series.points)) { point in
                HStack {
                    Circle()
                        .fill(point.isHollow ? Color.clear : Color("brand-primary", bundle: .main))
                        .overlay(Circle().strokeBorder(Color("brand-primary", bundle: .main), lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                    Text(point.measuredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                    Spacer()
                    Text("\(point.value, specifier: "%.1f") \(point.unit ?? "")")
                        .font(.footnote).monospacedDigit()
                    if point.isHollow {
                        Text("自测").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(series.metricType.rawValue) \(point.value) \(point.unit ?? "") · \(point.isHollow ? "自测" : "医院") · \(point.measuredAt.formatted(date: .abbreviated, time: .shortened))")
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
