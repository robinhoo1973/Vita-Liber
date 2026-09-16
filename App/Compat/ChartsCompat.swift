import SwiftUI
import Charts

enum ChartsCompat {
    /// iOS 17 才有横向滚动 + 可见域；iOS 16 由调用侧把数据裁到窗口（见 TrendViews.swift:168）。
    static var supportsScrollableAxes: Bool { if #available(iOS 17, *) { return true } else { return false } }
}
extension View {
    /// iOS 17：滚动 + 可见域 + 原生 X 选点；iOS 16：X 轴钉在 [domainEnd - visibleLength, domainEnd]，chartOverlay + DragGesture 反解 X 值，松手清空（与 chartXSelection 一致）。
    @ViewBuilder
    func chartWindowCompat(visibleLength: TimeInterval, domainEnd: Date, selection: Binding<Date?>) -> some View {
        if #available(iOS 17, *) {
            // 轴域必须显式钉在所选周期（业主 2026-09-16 第 3 项：7/30/90 天与 1 年显示大不相同）。
            // 只给 `.chartXVisibleDomain(length:)` 时 Swift Charts 按**数据自身范围**推断轴域：
            // 数据密时（1 年档/医院报告带多）轴域 ≈ 周期，看不出差别；数据稀疏时轴域塌缩到
            // 实际有点的那一段（甚至单点 → 退化域），短窗于是画不出与长窗同构的图。
            // 周期查询范围已下推到 SQL，滚动超集并不存在——钉域不会损失任何可达数据，
            // 只让「可见域 = 所选时间窗」这条 ui-ux §5.37 契约在两条 OS 路径上一致。
            self.chartXScale(domain: domainEnd.addingTimeInterval(-visibleLength)...domainEnd)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleLength)
                // 滚动锚点显式钉在窗口末端：`.chartScrollableAxes` 的初始位置默认为
                // 「数据起点」（最旧一段），周期查询后仍可能因 domain 比可见域宽
                // （BarMark unit: .day 会按整天外扩）而落到最旧一段——近期读数被推到
                // 屏幕外，观感即「数据没渲染」。
                .chartScrollPosition(initialX: domainEnd)
                .chartXSelection(value: selection)
        } else {
            self.chartXScale(domain: domainEnd.addingTimeInterval(-visibleLength)...domainEnd)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let originX = geo[proxy.plotAreaFrame].origin.x        // iOS 16 API（17 弃用为 plotFrame，仅告警）
                                    selection.wrappedValue = proxy.value(atX: value.location.x - originX, as: Date.self)
                                }
                                .onEnded { _ in selection.wrappedValue = nil })
                    }
                }
        }
    }
}
