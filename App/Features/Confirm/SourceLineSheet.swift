import SwiftUI
import Domain

/// 字段 → 原文行锚定面板（2026-09-17 借鉴批，业界复核台共识：把复核从"信任模型"变成"核对证据"）。
///
/// **只做行级、不做框级**：`sourceLineIndex` 是理解层对**页文本行**的编号，而
/// `ExtractionOrchestrator` 在入口就把几何信息丢了（`PageLayout.linesOnly`，无 bbox），
/// 所以这里高亮的是**文本行**，不是扫描图上的框。图上框要等 bbox 接回来（另一条工作线）。
/// 现状是诚实的：锚不到就不显示入口（`FieldConfirmRow.sourceLine == nil`），绝不拿整页原文充数。
struct SourceLineSheet: View {
    let lines: [String]
    let highlight: Int?
    @Environment(\.dismiss) private var dismiss

    private var highlighted: Int? {
        guard let highlight, lines.indices.contains(highlight) else { return nil }
        return highlight
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.entityCardSourceLineHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(highlighted == index ? .body.weight(.semibold) : .body)
                                .foregroundStyle(highlighted == index ? Color.primary : Color.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(highlighted == index ? Color("semantic-warning", bundle: .main).opacity(0.18) : Color.clear)
                                )
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onAppear { if let highlighted { proxy.scrollTo(highlighted, anchor: .center) } }
            }
            .navigationTitle(L10n.entityCardSourceLineTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.onboard_gotIt) { dismiss() }
                }
            }
        }
    }
}
