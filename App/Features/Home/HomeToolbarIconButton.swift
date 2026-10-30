import SwiftUI

/// 首页导航栏图标按钮（2026-10-23 业主：SOS / AI 助手 / 通知原样式难看）。
///
/// 统一几何：40pt 可见圆 + 44pt 命中区；三个按钮同屏时只靠色彩与填充
/// 建立层级，不靠尺寸差。SOS 用实心语义红（唯一实心项），其余为低透明度
/// 着色圆。无常态阴影（§3.3 阴影收敛），边界由着色描边承担；SOS 文字色
/// 取系统背景色，浅色模式=白、深色模式=黑，保证两种模式下的对比度。
struct HomeToolbarIconButton: View {
    let systemImage: String
    let tint: Color
    /// >0 时右上角显示计数胶囊（通知中心待办数）。
    var badgeCount: Int = 0
    let label: String
    let identifier: String
    let action: () -> Void

    private var badgeText: String { badgeCount > 99 ? "99+" : "\(badgeCount)" }

    var body: some View {
        // iPhone HIG：导航栏动作使用 SF Symbol 字形本身（无色块/圆圈背景），
        // 18–19pt medium、44×44pt 命中区；强调只靠语义色，不靠实心圆。
        // 此前 40pt 着色圆 + 实心 SOS 在玻璃导航栏上形成三个色块，观感零散。
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
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
                        .offset(x: 1, y: 1)
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
}
