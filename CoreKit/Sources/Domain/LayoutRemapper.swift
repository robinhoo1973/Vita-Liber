import Foundation

/// 归并后版面重映射（round4 P-6：自 `OCRPipeline.rebuildLayout` 迁入 Domain——纯函数、零框架依赖，
/// 此前落 Infrastructure 只能经管线间接测，且表格格 rows/header 两段 remap 闭包重复）。
///
/// 输入：归并产物 `merged`（每行吸收的旧行号）+ 原版面；输出：块 = 成员 bbox 并集 / 置信均值 / 新行号，
/// 表格格与段落 `lineIndices` 按旧→新重写（同一新行只保留一次）。
/// **fail-closed**：任一成员块在原版面找不到 → 不猜，整版面退 `PageLayout.linesOnly`（行身份弱但文本不丢，BR-002）。
public enum LayoutRemapper {
    public static func remap(merged: [TextLineMerger.MergedLine], original: PageLayout) -> PageLayout {
        guard let (blocks, newIndex) = rebuildBlocks(merged: merged, original: original) else {
            return PageLayout.linesOnly(merged.map(\.text))
        }
        let remap = { (indices: [Int]) -> [Int] in remapIndices(indices, by: newIndex) }
        let tables = original.tables.map { table in
            TableRegion(id: table.id, bbox: table.bbox,
                        rows: table.rows.map { remapRow($0, remap) },
                        header: table.header.map { remapRow($0, remap) })
        }
        let paragraphs = original.paragraphs.map { paragraph in
            let indices = remap(paragraph.lineIndices)
            return Paragraph(text: indices.map { merged[$0].text }.joined(separator: "\n"),
                             bbox: paragraph.bbox, lineIndices: indices)
        }
        return PageLayout(blocks: blocks, tables: tables, paragraphs: paragraphs)
    }

    /// 块重建 + 旧→新行号表；成员对不上 → nil（调用方 fail-closed）。
    static func rebuildBlocks(merged: [TextLineMerger.MergedLine], original: PageLayout)
        -> (blocks: [TextBlock], newIndex: [Int: Int])? {
        let byLine = Dictionary(original.blocks.map { ($0.lineIndex, $0) }, uniquingKeysWith: { a, _ in a })
        var newIndex: [Int: Int] = [:]
        var blocks: [TextBlock] = []
        for (index, line) in merged.enumerated() {
            let members = line.sourceIndices.compactMap { byLine[$0] }
            guard members.count == line.sourceIndices.count,
                  let bbox = LayoutRect.union(of: members.map(\.bbox)) else { return nil }
            for src in line.sourceIndices { newIndex[src] = index }
            let confidence = members.map(\.confidence).reduce(0, +) / Double(members.count)
            blocks.append(TextBlock(text: line.text, bbox: bbox, lineIndex: index, confidence: confidence))
        }
        return (blocks, newIndex)
    }

    /// 旧行号 → 新行号（丢无映射项；同一新行只保留首次出现，保持顺序）。
    static func remapIndices(_ indices: [Int], by newIndex: [Int: Int]) -> [Int] {
        var seen = Set<Int>(), out: [Int] = []
        for i in indices { if let n = newIndex[i], seen.insert(n).inserted { out.append(n) } }
        return out
    }

    private static func remapRow(_ row: TableRow, _ remap: ([Int]) -> [Int]) -> TableRow {
        TableRow(cells: row.cells.map {
            TableCell(text: $0.text, bbox: $0.bbox, columnIndex: $0.columnIndex, lineIndices: remap($0.lineIndices))
        })
    }
}
