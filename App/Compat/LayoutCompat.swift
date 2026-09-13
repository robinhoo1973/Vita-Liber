import SwiftUI

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
enum ContentMarginPlacementCompat { case automatic, scrollContent }   // 不能直接暴露 iOS 17 类型 ContentMarginPlacement
enum ListSectionSpacingCompat { case `default`, compact }
