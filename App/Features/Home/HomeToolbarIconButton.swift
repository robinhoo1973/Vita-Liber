import SwiftUI

/// 首页导航栏图标按钮（2026-10-23 业主：SOS / AI 助手 / 通知原样式难看）。
///
/// 统一几何：32pt 可见圆 + 44pt 命中区；三个按钮同屏时只靠色彩与填充
/// 建立层级，不靠尺寸差。SOS 用实心语义红（唯一实心项），其余为低透明度
/// 着色圆。无常态阴影（§3.3 阴影收敛），边界由着色描边承担；SOS 文字色
/// 取系统背景色，浅色模式=白、深色模式=黑，保证两种模式下的对比度。
struct HomeToolbarIconButton: View {
    enum Emphasis {
        /// 低透明度着色圆 + 彩色符号（AI 助手、通知）。
        case tinted
        /// 语义色实心圆 + 反色符号（SOS，唯一强调项）。
        case filled
    }

    let systemImage: String
    let tint: Color
    var emphasis: Emphasis = .tinted
    /// >0 时右上角显示计数胶囊（通知中心待办数）。
    var badgeCount: Int = 0
    let label: String
    let identifier: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var badgeText: String { badgeCount > 99 ? "99+" : "\(badgeCount)" }

    private var iconColor: Color {
        switch emphasis {
        case .filled: return Color(.systemBackground)
        case .tinted: return tint
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(fill)
                    Circle()
                        .stroke(border, lineWidth: 1)
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                }
                .frame(width: 32, height: 32)
                .overlay {
                    if emphasis == .filled {
                        Circle().stroke(.white.opacity(0.22), lineWidth: 0.8)
                    }
                }

                if badgeCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, badgeCount > 9 ? 4 : 0)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color("semantic-danger", bundle: .main), in: Capsule())
                        .overlay(
                            Capsule().stroke(Color("bg-grouped", bundle: .main), lineWidth: 1.5)
                        )
                        .offset(x: 5, y: -5)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(badgeCount > 0 ? "\(badgeCount) \(L10n.tabRemindersBadge)" : "")
        .accessibilityIdentifier(identifier)
    }

    private var fill: AnyShapeStyle {
        switch emphasis {
        case .filled:
            return AnyShapeStyle(LinearGradient(
                colors: [tint, tint.opacity(colorScheme == .dark ? 0.80 : 0.86)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .tinted:
            return AnyShapeStyle(tint.opacity(colorScheme == .dark ? 0.24 : 0.13))
        }
    }

    private var border: Color {
        switch emphasis {
        case .filled: return tint.opacity(0.55)
        case .tinted: return tint.opacity(colorScheme == .dark ? 0.32 : 0.22)
        }
    }
}
