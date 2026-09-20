import Foundation

/// 纵向段落聚合（2026-09-20，Q1 根因 R4）：iOS 26 的 `RecognizeDocumentsRequest` 直接给段落；
/// iOS 16–25 只有块 bbox，本类型按几何把**连续单列行**聚成段：同列左缘（|Δx| ≤ 1.5×中位行高）∧
/// 行距（下行 y − 上行 maxY ≤ 1.0×中位行高）。多列视觉行（表格样）既是段落分隔又不入段；
/// `excluded`（表格块行号）同样跳过。纯函数、确定性、与输入顺序无关。
public enum ParagraphBuilder {
    public static func paragraphs(from blocks: [TextBlock], excluding excluded: Set<Int> = []) -> [Paragraph] {
        let usable = blocks.filter { !excluded.contains($0.lineIndex) }
        guard !usable.isEmpty else { return [] }
        let heights = usable.map(\.bbox.height).sorted()
        let median = max(heights[heights.count / 2], 0.005)
        let rows = LayoutRowBuilder.rows(from: usable).sorted { $0.bbox.midY < $1.bbox.midY }

        var out: [Paragraph] = []
        var current: [LayoutRow] = []
        func flush() {
            guard !current.isEmpty else { return }
            let indices = current.flatMap(\.lineIndices)
            let bbox = current.dropFirst().reduce(current[0].bbox) { $0.union($1.bbox) }
            out.append(Paragraph(text: current.map(\.text).joined(separator: "\n"), bbox: bbox, lineIndices: indices))
            current = []
        }
        for row in rows {
            guard row.cells.count == 1 else { flush(); continue }     // 多列行：分隔且不入段
            if let last = current.last {
                let sameColumn = abs(row.bbox.x - last.bbox.x) <= 1.5 * median
                let close = row.bbox.y - last.bbox.maxY <= 1.0 * median
                if !(sameColumn && close) { flush() }
            }
            current.append(row)
        }
        flush()
        return out
    }
}
