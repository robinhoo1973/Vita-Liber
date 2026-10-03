import SwiftUI

/// 淡色状态胶囊统一出口（2026-10-03 呈现评审 T3；ui-ux V4.13 后续注记）。
///
/// 此前「品牌淡色胶囊」在全仓以 0.12 / 0.15 两套不透明度、多色基手写 15+ 处
/// （品牌色胶囊、systemGray5 胶囊、语义色胶囊），与 GradeBadge「全仓唯一渲染
/// 出口」纪律同构——本组件收敛全部淡色胶囊，样式令牌化：
/// - brand:brand-primary 0.15 底 + brand 前景（主语言/主标签类）
/// - neutral:bg-grouped 底 + text-secondary 前景（尽力识别/从属标注类）
/// - warning / danger:semantic-warning/danger 0.15 底 + 同色前景（状态警示类）
/// 统一不透明度 0.15（原 0.12 变体视觉并入）。
/// 两档尺寸与旧形态一致:small = caption2/6/2(行内徽标),regular = caption/8/4(卡片类别徽章)。
struct PillBadge: View {
    enum Style {
        case brand, neutral, warning, danger
    }

    enum Sizing {
        case small, regular
    }

    let text: String
    var style: Style = .brand
    var size: Sizing = .small
    var bold: Bool = false

    var body: some View {
        Text(text)
            .font(size == .regular ? .caption : .caption2)
            .fontWeight(bold ? .bold : nil)
            .padding(.horizontal, size == .regular ? 8 : 6)
            .padding(.vertical, size == .regular ? 4 : 2)
            .background(Capsule().fill(background(for: style)))
            .foregroundStyle(foreground(for: style))
    }

    private func background(for style: Style) -> Color {
        switch style {
        case .brand: return Color("brand-primary", bundle: .main).opacity(0.15)
        case .neutral: return Color("bg-grouped", bundle: .main)
        case .warning: return Color("semantic-warning", bundle: .main).opacity(0.15)
        case .danger: return Color("semantic-danger", bundle: .main).opacity(0.15)
        }
    }

    private func foreground(for style: Style) -> Color {
        switch style {
        case .brand: return Color("brand-primary", bundle: .main)
        case .neutral: return Color("text-secondary", bundle: .main)
        case .warning: return Color("semantic-warning", bundle: .main)
        case .danger: return Color("semantic-danger", bundle: .main)
        }
    }
}
