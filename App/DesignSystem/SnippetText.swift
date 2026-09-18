import SwiftUI
import Domain

/// 检索片段渲染单一出口（全仓审查 2026-09-18 · F-A8-01/F-D1-02）。
/// FTS `snippet()` 与 `SearchRules.highlight` 产出 `<b>…</b>` 标记，此前视图
/// 直接 `Text(snippet)` 把标记字面渲染给用户。本组件经 Domain
/// `SearchRules.highlightSegments` 拆段后加粗命中段，标记不再渗出；
/// 无障碍朗读取去标记纯文本（`SearchRules.stripHighlight`）。
/// 搜索命中/AI 引用/任何展示检索片段的面都必须经此出口。
struct SnippetText: View {
    let snippet: String

    init(_ snippet: String) { self.snippet = snippet }

    var body: some View {
        composed
            .accessibilityLabel(Text(SearchRules.stripHighlight(snippet)))
    }

    /// `Text` 拼接：命中段 `.bold()` 并用主色强调，其余段沿用外层样式。
    private var composed: Text {
        SearchRules.highlightSegments(snippet).reduce(Text("")) { acc, segment in
            if segment.highlighted {
                return acc + Text(segment.text).bold().foregroundColor(.primary)
            }
            return acc + Text(segment.text)
        }
    }
}
