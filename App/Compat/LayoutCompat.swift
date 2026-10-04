import SwiftUI
import Foundation   // sin（iOS 16 回落相位计算）

extension View {
    @ViewBuilder func contentMarginsCompat(_ edges: Edge.Set, _ length: CGFloat, for placement: ContentMarginPlacementCompat) -> some View {
        if #available(iOS 17, *) { self.contentMargins(edges, length, for: placement == .scrollContent ? .scrollContent : .automatic) } else { self }
    }
    @ViewBuilder func listSectionSpacingCompat(_ spacing: ListSectionSpacingCompat) -> some View {
        if #available(iOS 17, *) { self.listSectionSpacing(spacing == .compact ? .compact : .default) } else { self }
    }
    /// 录音态符号脉动：iOS 17 variableColor 迭代；iOS 16 无符号动效——按钮旁的电平柱（PressToTalkMicButton.swift:31-）已承担录音反馈，故 no-op。
    @ViewBuilder func recordingPulseCompat(isActive: Bool) -> some View {
        if #available(iOS 17, *) { self.symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive) } else { self }
    }
}

/// 下载进行态图标动效（2026-10-04 业主反馈①；五角色评审见 discussions/2026-10-04-home-download-card-round1.md）：
/// 首页下载卡图标内箭头持续循环动效，替代原独立一行的不确定 spinner（省行高、卡高跨阶段稳定）。
/// 双轨（成熟实现优先 ADR-025）：iOS 17 用系统符号动效；iOS 16 无符号动效原语，回落
/// TimelineView 相位驱动 ≤3pt 垂直位移 dip——**用 offset 不用 scaleEffect**（§3.3
/// 缩放只用于按压/选中转换，不做持续动效）。
/// 启停：bounce 属离散效果（DiscreteSymbolEffect），无 isActive 启停 API、触发条件 = value 变化，
/// 故激活令牌在激活沿（onAppear 首现已激活 / isActive 上升沿）自增一次；停止靠**整体移除修饰符**
/// （条件挂载）——value 换值只重启不停止。
/// 门控：Reduce Motion 显式门控（Apple 未文档化 symbolEffect 的自动抑制，不依赖系统行为，双轨一致）；
/// 排队（waiting）态由调用方传 isActive=false——无回调活动，动效即撒谎（如实呈现纪律，
/// 与「排队中」文案同源）。图标为装饰性（进行态语义由文案/进度承担），对 VoiceOver 隐藏。
struct VLDownloadActivityIcon: View {
    var isActive: Bool
    var font: Font = .title3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 激活令牌：iOS 17 bounce 以 value 变化触发，每次激活沿自增一次。
    @State private var activationToken = 0

    /// 单一符号源（激活/静置、双版本共用；换图标只改这一处）。
    private var baseIcon: some View {
        Image(systemName: "arrow.down.circle")
    }

    var body: some View {
        Group {
            if #available(iOS 17, *) {
                if isActive && !reduceMotion {
                    baseIcon
                        .symbolEffect(.bounce.down, options: .repeating, value: activationToken)
                } else {
                    baseIcon
                }
            } else {
                if isActive && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                        // 正弦相位驱动 ±3pt 垂直位移 dip（周期 1.2s，对齐 Material 不确定指示时长惯例）；
                        // offset 为 transform-only、不影响布局。
                        let phase = sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)
                        baseIcon
                            .offset(y: CGFloat(phase) * 3)
                    }
                } else {
                    baseIcon
                }
            }
        }
        .font(font)
        .accessibilityHidden(true)   // 装饰性：进行态由阶段文案/进度值承担（HomeSubviews detailText）
        // 激活沿 = composite（isActive && !reduceMotion）的上升沿 + 首现（initial: true）。
        // composite 而非单独 isActive：Reduce Motion 关闭沿（下载中用户去系统设置关掉减弱动态效果）
        // 同样触发 bump——否则 iOS 17 轨以未变的 token 挂载动效分支，按文档语义（仅 value 变化触发）
        // 图标会静置到任务结束；iOS 16 轨相位驱动不受影响，此 bump 对 16 无副作用。
        .onChangeCompat(of: isActive && !reduceMotion, initial: true) { _, newValue in
            if newValue { activationToken += 1 }
        }
    }
}
enum ContentMarginPlacementCompat { case automatic, scrollContent }   // 不能直接暴露 iOS 17 类型 ContentMarginPlacement
enum ListSectionSpacingCompat { case `default`, compact }
