import SwiftUI

/// 启动门（session 之前）动作按钮的统一尺寸（2026-10-30 业主反馈：
/// 「按钮尺寸非常难看，按 iPhone UI 规范调整，特别是长宽比例」）。
///
/// iPhone HIG：最小触控 44pt，常用主行动高度 50–52pt；全宽 + 52pt 高
/// ≈ 7:1 长宽比，与系统表单主按钮观感一致。此前 64pt 高全宽按钮在 6.1"
/// 屏上呈「胖条」，与 mock（52pt / 圆角 14）不符；本文件为单一出口。
enum VLButtonMetrics {
    static let height: CGFloat = 52
    static let cornerRadius: CGFloat = 14
    /// iPad 上卡片最大宽 520，按钮限宽 420 避免出现 10:1 的极端长宽比。
    static let maxWidth: CGFloat = 420
}

/// 实心主行动按钮（品牌填充、白字、52pt、圆角 14）。
struct VLPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: VLButtonMetrics.maxWidth,
                   minHeight: VLButtonMetrics.height,
                   maxHeight: VLButtonMetrics.height)
            .background(
                fill(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: VLButtonMetrics.cornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: VLButtonMetrics.cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.2), value: configuration.isPressed)
            .frame(maxWidth: .infinity)   // 在卡片内居中（iPad 限宽后仍平衡）
    }

    private func fill(pressed: Bool) -> Color {
        let base = Color("brand-primary", bundle: .main)
        guard isEnabled else { return base.opacity(0.5) }
        return pressed ? base.opacity(0.9) : base
    }
}

/// 描边次行动按钮（白/浅底、品牌描边与文字、52pt、圆角 14）。
/// 低于主按钮的实心强调，符合 HIG 主次分层；命中区仍 ≥44pt。
struct VLSecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let brand = Color("brand-primary", bundle: .main)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? brand : brand.opacity(0.45))
            .frame(maxWidth: VLButtonMetrics.maxWidth,
                   minHeight: VLButtonMetrics.height,
                   maxHeight: VLButtonMetrics.height)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.55),
                in: RoundedRectangle(cornerRadius: VLButtonMetrics.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VLButtonMetrics.cornerRadius)
                    .stroke(brand.opacity(isEnabled ? 0.42 : 0.2), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: VLButtonMetrics.cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.2), value: configuration.isPressed)
            .frame(maxWidth: .infinity)
    }
}
