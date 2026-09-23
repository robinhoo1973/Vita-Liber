import SwiftUI
import Domain

/// 字段 → 原文行锚定面板（2026-09-17 借鉴批，业界复核台共识：把复核从"信任模型"变成"核对证据"）。
///
/// 高亮的是**文本行**（`sourceLineIndex` = 理解层对页文本行的编号）；扫描图
/// 上的框级高亮由 `DocumentSourcePageView(highlight:)` 承担（2026-09-19
/// 几何回管线接通后，实测 bbox 归一化坐标直出）。锚不到就不显示入口
/// （`FieldConfirmRow.sourceLine == nil`），绝不拿整页原文充数。
///
/// **点行引用（业主 2026-09-19 第 1 项；2026-09-20 升级多行）**：行可点选 →
/// 多行**按行序连接**后经 `onPick([line])` 回填字段（连接语义收敛 Domain
/// `FieldDraft.quoteLines`，分隔符与抽取管线叙事归并同源）——语义 = 用户选取
/// 原文修订，走 revise 留痕、D 级待确认（引用文本是机器原文的搬运，不是
/// 用户手输，不得借 `fillByUser` 升 C；BR-003）。点选不立即回填：多行选择
/// 需「引用所选」按钮确认（单行亦可连点两行后一并引用）。
struct SourceLineSheet: View {
    let lines: [String]
    let highlight: Int?
    /// 点选引用回调（按行序：原文 + 行号——round5 Q1：行号即出处锚，字段据此获得 [原文] 入口）；
    /// nil = 只读面板（无引用语义的调用方）
    var onPick: ((_ lines: [String], _ indices: [Int]) -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// 已选行集合（按行序输出；行 tap 切换选择，不立即回填）
    @State private var selection: Set<Int> = []

    private var highlighted: Int? {
        guard let highlight, lines.indices.contains(highlight) else { return nil }
        return highlight
    }

    private var pickable: Bool { onPick != nil }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pickable ? L10n.entityCardSourceLineQuoteHint : L10n.entityCardSourceLineHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let selected = selection.contains(index)
                            Button {
                                guard pickable, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                if selected { selection.remove(index) } else { selection.insert(index) }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    if pickable {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .font(.body)
                                            .foregroundStyle(selected
                                                ? Color("brand-primary", bundle: .main)
                                                : Color.secondary)
                                            .accessibilityLabel(selected
                                                ? L10n.entityCardSourceLineSelected
                                                : L10n.entityCardSourceLineSelect)
                                    }
                                    Text(line)
                                        .font(highlighted == index ? .body.weight(.semibold) : .body)
                                        .foregroundStyle(highlighted == index ? Color.primary : Color.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 44)   // 触点纪律：行 ≥44pt
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selected
                                            ? Color("brand-primary", bundle: .main).opacity(0.10)
                                            : (highlighted == index
                                                ? Color("semantic-warning", bundle: .main).opacity(0.18)
                                                : Color.clear))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
                            .disabled(!pickable)
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
                if pickable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.entityCardSourceLineQuoteConfirm(selection.count)) {
                            pickSelection()
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("OCR.source.quote")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.onboard_gotIt) { dismiss() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
            }
        }
    }

    /// 按行序取已选行的原文与行号，交 `FieldDraft.quoteLines(_:sourceLineIndices:)` 归并并记录出处
    /// （空行剔除、\n 连接、锚点写入均在 Domain）。
    private func pickSelection() {
        guard let onPick, !selection.isEmpty else { return }
        let indices = lines.indices.filter { selection.contains($0) }
        onPick(indices.map { lines[$0] }, Array(indices))
        dismiss()
    }
}
