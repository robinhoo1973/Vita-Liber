import Foundation
import Testing
@testable import Domain

@Suite("版面段落聚合（iOS 16–25 几何路径）")
struct ParagraphBuilderTests {
    private func block(_ text: String, line: Int, x: Double = 0.05, y: Double, width: Double = 0.8) -> TextBlock {
        TextBlock(text: text, bbox: LayoutRect(x: x, y: y, width: width, height: 0.03), lineIndex: line, confidence: 0.9)
    }

    @Test func consecutiveSingleColumnRowsFormOneParagraph() {
        let blocks = [block("A", line: 0, y: 0.10), block("B", line: 1, y: 0.135), block("C", line: 2, y: 0.170)]
        let p = ParagraphBuilder.paragraphs(from: blocks)
        #expect(p.count == 1)
        #expect(p[0].lineIndices == [0, 1, 2])
        #expect(p[0].text == "A\nB\nC")
    }

    @Test func verticalGapSplitsParagraphs() {
        let blocks = [block("A", line: 0, y: 0.10), block("B", line: 1, y: 0.135), block("C", line: 2, y: 0.30)]
        let p = ParagraphBuilder.paragraphs(from: blocks)
        #expect(p.map(\.lineIndices) == [[0, 1], [2]])
    }

    @Test func multiColumnRowBreaksAndIsExcluded() {
        let blocks = [
            block("A", line: 0, y: 0.10),
            block("项目", line: 1, x: 0.05, y: 0.135, width: 0.2), block("结果", line: 2, x: 0.5, y: 0.135, width: 0.1),
            block("B", line: 3, y: 0.170),
        ]
        let p = ParagraphBuilder.paragraphs(from: blocks)
        #expect(p.map(\.lineIndices) == [[0], [3]])
    }

    @Test func leftEdgeShiftSplitsParagraphs() {
        let blocks = [block("A", line: 0, y: 0.10), block("B", line: 1, x: 0.40, y: 0.135)]
        #expect(ParagraphBuilder.paragraphs(from: blocks).count == 2)
    }

    @Test func excludedLinesAreSkipped() {
        let blocks = [block("A", line: 0, y: 0.10), block("T", line: 1, y: 0.135), block("B", line: 2, y: 0.170)]
        #expect(ParagraphBuilder.paragraphs(from: blocks, excluding: [1]).map(\.lineIndices) == [[0], [2]])
    }
}
