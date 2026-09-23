import SwiftUI

/// Fluent Glass 玻璃卡片统一出口（ui-ux-spec §3.0 · tech-spec V3.156）。
/// glass/fill + blur + border；**常态不打阴影**（V4.05 阴影收敛：blur + 光泽线 +
/// 表面色差已表达层级——Apple DESIGN.md「全系统唯一阴影」心得），交互抬升时
/// 由调用侧叠加 `.shadow`（glass/shadow-lift，见 §3.0）。
///
/// 纪律（§3.0）：只用于导航栏/卡片/浮层；不得用于长文本阅读区、数据表格、
/// 时间轴正文、图表绘制区。同屏活跃玻璃层 ≤5（tech-spec §3 性能约束）。
/// 高对比度/降低透明度开启时切换为不透明系统背景（WCAG AA）。
struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(material)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.white.opacity(colorScheme == .dark ? 0.08 : 0.45), lineWidth: 1)
            )                                                    // 光泽边缘线（无障碍可见边界）
    }

    @ViewBuilder
    private var material: some View {
        if reduceTransparency {
            Color(.systemBackground)
        } else {
            Color.clear.background(.ultraThinMaterial)           // GPU 加速实时模糊（iOS 15+）
        }
    }
}

/// 按压反馈统一（ui-ux §3.3 V4.05，Apple scale(0.95) 系统微交互心得）：
/// scaleEffect(0.97) + 弹簧动画 ≤350ms；只做按压/选中转换，不做持续动效。
/// 玻璃卡片按压另叠加 glass/bg-hover 填充加深；实心主按钮按压另叠加填充加深一档。
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

extension View {
    /// 玻璃卡片修饰（§3.0 统一出口；cornerRadius 默认 16 对应卡片圆角令牌）。
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// 按压态缩放反馈（自定义按压路径用；Button 优先 `.buttonStyle(PressScaleButtonStyle())`）。
    func pressFeedback(_ pressed: Bool) -> some View {
        scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: pressed)
    }
}
