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

/// 下载进行态图标动效（2026-10-04 业主反馈①；round2 2026-10-04 全轨 TimelineView 裁定）：
/// 首页下载卡图标内箭头持续循环动效，替代原独立一行的不确定 spinner（省行高、卡高跨阶段稳定）。
/// 全轨相位驱动 ±5pt 垂直位移 dip（周期 1.2s，对齐 Material 不确定指示时长惯例）——
/// **用 offset 不用 scaleEffect**（§3.3 缩放只用于按压/选中转换，不做持续动效）。
/// round2 退轨申明（ADR-025 手写回落正当性，round1 预登记决策点达成）：iOS 17
/// `.bounce.down` 为离散缩放浸入（非空间位移）、幅度微小，且本卡按观察域纪律以
/// 5 Hz 持续重渲，离散效果存在相位/重启风险（round1 技术债⑨）；L2 实测不可感知、
/// 偏离业主「箭头持续下移」字面——系统原语无法产出该形态，故双轨合一为全轨
/// TimelineView（两版本行为一致，激活令牌机制随之删除）。
/// 门控：Reduce Motion 显式门控（不依赖系统对符号动效的未文档化抑制）；排队
/// （waiting）态由调用方传 isActive=false——无回调活动，动效即撒谎（如实呈现纪律，
/// 与「排队中」文案同源）。图标为装饰性（进行态语义由文案/进度承担），对 VoiceOver 隐藏。
struct VLDownloadActivityIcon: View {
    var isActive: Bool
    var font: Font = .title3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 单一符号源（激活/静置共用；换图标只改这一处）。
    private var baseIcon: some View {
        Image(systemName: "arrow.down.circle")
    }

    var body: some View {
        Group {
            if isActive && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                    // 正弦相位驱动 ±5pt 垂直位移 dip（transform-only、不影响布局）。
                    let phase = sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2)
                    baseIcon
                        .offset(y: CGFloat(phase) * 5)
                }
            } else {
                baseIcon
            }
        }
        .font(font)
        .accessibilityHidden(true)   // 装饰性：进行态由阶段文案/进度值承担（HomeSubviews detailText）
    }
}
enum ContentMarginPlacementCompat { case automatic, scrollContent }   // 不能直接暴露 iOS 17 类型 ContentMarginPlacement
enum ListSectionSpacingCompat { case `default`, compact }
