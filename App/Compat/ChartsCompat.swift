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
            self.chartScrollableAxes(.horizontal).chartXVisibleDomain(length: visibleLength).chartXSelection(value: selection)
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
