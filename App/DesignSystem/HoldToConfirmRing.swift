import SwiftUI
import Domain

/// 按住确认原语（§4.15 / FR18.2-18.3 / 第九轮审查 S-1）：
/// 零位移拖拽计步 + TimelineView 帧驱动环形进度 + 完成触觉（Haptics 单出口）。
///
/// 下沉依据（DoD 增补：跨 ≥2 Feature 的同一交互形态）：
/// - SOSOrb（Emergency，第六/八轮修复的行为基线：落下即记起点、松手恒复位、
///   位移超 `sosOrbMaxTravelPoints` 取消——滚动误触防护）；
/// - 关怀模式 SOS 大卡（Home，此前仅裸 LongPressGesture：无进度、无触觉，
///   震颤用户无法判断"是否按够"，U2#5）；
/// - 关怀模式时段卡 [全部已服用]（Reminders，震颤下两连点易误触）。
/// 行为细节与 SOSOrb 现行实现逐条同源，抽出的就是那套逻辑本身。
struct HoldToConfirmRing<Content: View>: View {
    /// 触发所需按住时长（Domain `HoldToConfirm.requiredSeconds`）
    var requiredSeconds: TimeInterval
    /// 位移取消阈值（超限 = 滚动/误划；Domain `CareModeMetrics.sosOrbMaxTravelPoints`）
    var maxTravel: CGFloat
    /// nil = Capsule（悬浮球）；数值 = 连续圆角矩形（大卡/按钮）
    var cornerRadius: CGFloat?
    var ringColor: Color = .white
    var lineWidth: CGFloat = 3
    @ViewBuilder var content: () -> Content
    var onComplete: () -> Void

    @State private var holdStart: Date?
    @State private var cancelled = false

    var body: some View {
        content()
            .overlay {
                if holdStart != nil {
                    // 第六轮全仓审查修复：progress 静态求值在按住期间无重渲染
                    // （环恒 0）——改 TimelineView 帧驱动（仅按住期间挂载，
                    // 松开即卸载）。
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        ringShape
                            .trim(from: 0, to: progress(timeline.date))
                            .stroke(ringColor, lineWidth: lineWidth)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !cancelled else { return }
                        let travel = max(abs(value.translation.width), abs(value.translation.height))
                        if travel > maxTravel {
                            cancelled = true
                            holdStart = nil
                            return
                        }
                        if holdStart == nil { holdStart = Date() }
                    }
                    .onEnded { _ in
                        let held = !cancelled
                            && holdStart.map { Date().timeIntervalSince($0) >= requiredSeconds } ?? false
                        holdStart = nil
                        cancelled = false
                        if held {
                            // S-1/S-2：完成触觉（Haptics 单出口；系统触感关闭自动静默）
                            Haptics.impact(.medium)
                            onComplete()
                        }
                    }
            )
    }

    private var ringShape: AnyShape {
        if let cornerRadius {
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        return AnyShape(Capsule())
    }

    private func progress(_ now: Date) -> CGFloat {
        guard let start = holdStart else { return 0 }
        return min(1, now.timeIntervalSince(start) / max(requiredSeconds, 0.001))
    }
}
