import SwiftUI
import Domain

/// FR17.9 全局语音快速入口（SP-55 语音速记面板 · ui-ux §5.54）：
/// 目标 chips（指标 / 观察 / 问诊问题 / AI 提问 / 提醒设定 / 档案设定 / 任意文本），
/// 上下文感知默认高亮当前页相关目标，可一键切换。
/// 仅限受限文法与结构化录入，不做自由对话（F19 边界延续）；
/// 各目标复用既有流程与 FR17.13 标准确认模板。
struct VoiceQuickLaunchView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var target: L10n.TargetTag = .anyText

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L10n.voicePanelTitle)
                    .font(.title2.bold())
                Text(L10n.voicePanelHint)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                // 目标 chips 横排（换行布局）
                FlowChips(
                    items: L10n.TargetTag.allCases.map { (title: L10n.voiceTargetName($0), tag: $0) },
                    selected: target
                ) { selected in
                    target = selected
                }
                Button(L10n.voicePanelStart) {
                    open(target)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("SP-55.panel.start")
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle(L10n.voicePanelTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.common_cancel) { dismiss() }
                }
                // FR17.15 面板内语言入口（5.54 C）——跳语音语言选择器
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        VoiceLanguageSettingsView()
                    } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityIdentifier("SP-55.panel.language")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func open(_ target: L10n.TargetTag) {
        switch target {
        case .metric: router.navigate(to: .metricQuickEntry)
        case .observation: router.navigate(to: .observationCreate)
        case .question: router.navigate(to: .questionList)
        case .ai: router.navigate(to: .assistantChat)
        case .reminder: router.navigate(to: .voiceReminderDraft)
        case .profile: router.navigate(to: .voiceGuideProfile)
        case .anyText:
            // 任意文本 = 语音速记条目（FR17.14）——VoiceNote 面板
            router.navigate(to: .voiceNotePanel)
        }
    }
}

/// 简易 chips 流式布局（VoiceQuickLaunch 目标选择）
private struct FlowChips<T: Hashable>: View {
    let items: [(title: String, tag: T)]
    let selected: T
    let onSelect: (T) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.tag) { item in
                Button {
                    onSelect(item.tag)
                } label: {
                    Text(item.title)
                        .font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(selected == item.tag
                                                   ? Color("brand-primary", bundle: .main)
                                                   : Color(.systemGray5)))
                        .foregroundStyle(selected == item.tag ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SP-55.panel.chip.\(item.tag.hashValue)")
            }
        }
        .padding(.horizontal, 24)
    }
}

/// iOS 16+ Layout 协议流式布局（行内换行 chips）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
