import SwiftUI
import Domain
import Perception

/// ui-ux §4.17 PagingStepper 翻页步进器（关怀模式）：大号 ‹ › 双钮 + 中间标签。
///
/// 抽成组件（业主 2026-09-16 第 2 项「时间周期往前和往后的图形按钮需要更大一点」）：
/// 此前趋势页把两枚按钮手写在视图里，图标 18pt 画在 44pt 框内**且无 contentShape**
/// ——外部 frame 只占布局，指尖落点仍是那枚 18pt 的图（FR18.2 / ui-ux §4.17
/// 「两枚按钮 ≥44pt（关怀模式 ≥64pt）」名存实亡），且关怀模式完全不放大。
/// 本组件：`CareModeMetrics` 决定触点边长（常规 44pt / 关怀 64pt，与药箱行、
/// 紧急页同一出口），图标 24pt 画在**有底色的圆形可点区域内**，整块区域 contentShape。
///
/// 未交付项：§4.17 的「页码指示（当前/总数）」需要「该指标最早周期」这一事实，
/// 查询层目前不提供（已登记 tech-spec §11「PagingStepper 页码指示」行与
/// ui-ux §4.17 未交付说明），本组件只渲染传入的标签。
struct PagingStepper<Label: View>: View {
    var canGoPrevious: Bool = true
    var canGoNext: Bool = true
    var previousLabel: String
    var nextLabel: String
    var previousIdentifier: String?
    var nextIdentifier: String?
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(AppState.self) private var app

    private var metrics: CareModeMetrics { app.careMode ? .care : .standard }

    var body: some View {
        // 关怀模式开关是 @Perceptible 状态：读取须在跟踪上下文内，否则切换
        // 关怀模式后控件尺寸要等下一次无关刷新才跟上
        WithPerceptionTracking {
            HStack(spacing: metrics.spacing) {
                button(icon: VLIcon.chevronLeft, enabled: canGoPrevious,
                       accessibilityLabel: previousLabel, identifier: previousIdentifier, action: onPrevious)
                label()
                button(icon: VLIcon.chevronRight, enabled: canGoNext,
                       accessibilityLabel: nextLabel, identifier: nextIdentifier, action: onNext)
            }
        }
    }

    /// 步进按钮：可点区域 = `CareModeMetrics.touchTarget` 方形（内容为居中图标 +
    /// 底色圆），`.contentShape` 保证整块区域命中——`buttonStyle(.plain)` 的命中区
    /// 只跟随绘制内容，没有它时大框仍是装饰。
    private func button(icon: Image, enabled: Bool, accessibilityLabel: String,
                        identifier: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(enabled ? Color("brand-primary", bundle: .main)
                                         : Color("text-tertiary", bundle: .main))
                .frame(width: metrics.touchTarget, height: metrics.touchTarget)
                .background(Circle().fill(Color("bg-grouped", bundle: .main)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier ?? "")
    }
}
