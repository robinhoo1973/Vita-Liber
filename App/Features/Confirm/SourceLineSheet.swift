import SwiftUI
import Domain

/// 字段 → 原文行锚定面板（2026-09-17 借鉴批，业界复核台共识：把复核从"信任模型"变成"核对证据"）。
///
/// 高亮的是**文本行**（`sourceLineIndex` = 理解层对页文本行的编号）；扫描图
/// 上的框级高亮由 `DocumentSourcePageView(highlight:)` 承担（2026-09-19
/// 几何回管线接通后，实测 bbox 归一化坐标直出）。锚不到就不显示入口
/// （`FieldConfirmRow.sourceLine == nil`），绝不拿整页原文充数。
///
/// **点行引用（业主 2026-09-19 第 1 项）**：行可点选 → `onPick(line)` 回填
/// 字段（语义 = 用户选取原文修订，走 revise 留痕、D 级待确认——引用文本
/// 是机器原文的搬运，不是用户手输，不得借 `fillByUser` 升 C；BR-003）。
struct SourceLineSheet: View {
    let lines: [String]
    let highlight: Int?
    /// 点选引用回调：nil = 只读面板（无引用语义的调用方）
    var onPick: ((String) -> Void)?
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
                        Text(onPick != nil ? L10n.entityCardSourceLineQuoteHint : L10n.entityCardSourceLineHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Button {
                                guard let onPick, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                onPick(line)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line)
                                        .font(highlighted == index ? .body.weight(.semibold) : .body)
                                        .foregroundStyle(highlighted == index ? Color.primary : Color.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if onPick != nil {
                                        Image(systemName: "text.quote")
                                            .font(.caption)
                                            .foregroundStyle(Color("brand-primary", bundle: .main))
                                            .accessibilityLabel(L10n.entityCardSourceLineQuote)
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(highlighted == index ? Color("semantic-warning", bundle: .main).opacity(0.18) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(onPick == nil)
                            .textSelection(.enabled)
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
