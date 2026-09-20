import Foundation
import Testing
@testable import Domain

/// round4 P-6：`rebuildLayout` 是纯 Domain 规则却落在 Infrastructure `OCRPipeline`——只能经管线间接测。
/// 迁为 `LayoutRemapper` 后直接钉住：块并集/置信均值、表格格与段落行号旧→新重写、成员对不上 fail-closed 退 linesOnly。
@Suite("LayoutRemapper 归并后版面重映射")
struct LayoutRemapperTests {
    private func block(_ text: String, line: Int, y: Double, width: Double, confidence: Double = 0.8) -> TextBlock {
        TextBlock(text: text, bbox: LayoutRect(x: 0.05, y: y, width: width, height: 0.03), lineIndex: line, confidence: confidence)
    }
    private func cell(_ li: Int) -> TableCell {
        TableCell(text: "c\(li)", bbox: LayoutRect(x: 0, y: 0, width: 0.1, height: 0.1), columnIndex: 0, lineIndices: [li])
    }

    @Test func mergedBlocksUnionBBoxAndAverageConfidence() {
        let original = PageLayout(blocks: [block("a", line: 0, y: 0.10, width: 0.9, confidence: 0.6),
                                           block("b", line: 1, y: 0.135, width: 0.2, confidence: 1.0),
                                           block("c", line: 2, y: 0.30, width: 0.4, confidence: 0.9)])
        let merged = [TextLineMerger.MergedLine(text: "ab", sourceIndices: [0, 1]),
                      TextLineMerger.MergedLine(text: "c", sourceIndices: [2])]
        let out = LayoutRemapper.remap(merged: merged, original: original)
        #expect(out.blocks.map(\.lineIndex) == [0, 1])
        #expect(out.blocks[0].text == "ab")
        #expect(abs(out.blocks[0].confidence - 0.8) < 1e-9)
        #expect(out.blocks[0].bbox == LayoutRect(x: 0.05, y: 0.10, width: 0.9, height: 0.065))
        #expect(out.blocks[1].lineIndex == 1 && out.blocks[1].text == "c")
    }

    @Test func tableCellsAndParagraphsAreRemappedToNewIndices() {
        let blocks = [block("t", line: 0, y: 0.05, width: 0.3), block("a", line: 1, y: 0.10, width: 0.9),
                      block("b", line: 2, y: 0.135, width: 0.2), block("r1", line: 3, y: 0.30, width: 0.9),
                      block("r2", line: 4, y: 0.335, width: 0.9)]
        let table = TableRegion(id: "t0", bbox: LayoutRect(x: 0, y: 0.3, width: 1, height: 0.1),
                                rows: [TableRow(cells: [cell(3)]), TableRow(cells: [cell(4)])], header: TableRow(cells: [cell(0)]))
        let paragraphs = [Paragraph(text: "a\nb", bbox: LayoutRect(x: 0.05, y: 0.1, width: 0.9, height: 0.065), lineIndices: [1, 2])]
        let original = PageLayout(blocks: blocks, tables: [table], paragraphs: paragraphs)
        let merged = [TextLineMerger.MergedLine(text: "t", sourceIndices: [0]),
                      TextLineMerger.MergedLine(text: "ab", sourceIndices: [1, 2]),
                      TextLineMerger.MergedLine(text: "r1", sourceIndices: [3]),
                      TextLineMerger.MergedLine(text: "r2", sourceIndices: [4])]
        let out = LayoutRemapper.remap(merged: merged, original: original)
        #expect(out.tables[0].rows.flatMap { $0.cells.flatMap(\.lineIndices) } == [2, 3])
        #expect(out.tables[0].header?.cells.flatMap(\.lineIndices) == [0])
        #expect(out.paragraphs.map(\.lineIndices) == [[1]])
        #expect(out.paragraphs[0].text == "ab")
    }

    @Test func paragraphIndicesDeduplicateWhenTwoOldLinesMergeIntoOne() {
        let blocks = [block("a", line: 0, y: 0.10, width: 0.9), block("b", line: 1, y: 0.135, width: 0.2)]
        let original = PageLayout(blocks: blocks, paragraphs: [Paragraph(text: "a\nb", bbox: blocks[0].bbox, lineIndices: [0, 1])])
        let merged = [TextLineMerger.MergedLine(text: "ab", sourceIndices: [0, 1])]
        let out = LayoutRemapper.remap(merged: merged, original: original)
        #expect(out.paragraphs[0].lineIndices == [0])
    }

    @Test func missingMemberBlockFailsClosedToLinesOnly() {
        // sourceIndices 引用了 original 里不存在的块 → 不猜，整版面退 linesOnly（行身份弱但文本不丢）。
        let original = PageLayout(blocks: [block("a", line: 0, y: 0.1, width: 0.9)])
        let merged = [TextLineMerger.MergedLine(text: "ab", sourceIndices: [0, 7])]
        let out = LayoutRemapper.remap(merged: merged, original: original)
        #expect(out == PageLayout.linesOnly(["ab"]))
    }
}
