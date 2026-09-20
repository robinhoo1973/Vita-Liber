import Foundation
import Testing
@testable import Domain

/// round4 P-1…P-4：中位行高 ×3、bbox 并集 ×3、表格行集 ×2、`LayoutRowBuilder.rows` 同管线双算——
/// 几何度量收敛为 `LayoutMetrics` 单点计算；本套件钉住其与既有内联算法**逐值等价**（重构零行为变化）。
@Suite("LayoutMetrics 版面度量单点")
struct LayoutMetricsTests {
    private func block(_ text: String, line: Int, x: Double = 0.05, y: Double, width: Double, height: Double = 0.03) -> TextBlock {
        TextBlock(text: text, bbox: LayoutRect(x: x, y: y, width: width, height: height), lineIndex: line, confidence: 0.9)
    }

    @Test func medianHeightHasFloorAndIsUpperMedian() {
        let blocks = [block("a", line: 0, y: 0.1, width: 0.5, height: 0.02),
                      block("b", line: 1, y: 0.2, width: 0.5, height: 0.04),
                      block("c", line: 2, y: 0.3, width: 0.5, height: 0.06),
                      block("d", line: 3, y: 0.4, width: 0.5, height: 0.08)]
        // 与 TextLineMerger/ParagraphBuilder 同口径：sorted[count/2]（偶数取上中位）
        #expect(LayoutMetrics(blocks: blocks).medianHeight == 0.06)
        let tiny = [block("a", line: 0, y: 0.1, width: 0.5, height: 0.001)]
        #expect(LayoutMetrics(blocks: tiny).medianHeight == LayoutMetrics.minimumMedianHeight)
    }

    @Test func rightEdgeIsNinetiethPercentileWithSmallNGuard() {
        // n=2：取较大者（round3 测试委员复核：小 n 不得退化到较小者）
        let two = [block("a", line: 0, y: 0.1, width: 0.30), block("b", line: 1, y: 0.2, width: 0.90)]
        #expect(abs(LayoutMetrics(blocks: two).rightEdge - 0.95) < 1e-9)
        // n=10：tenth = 1 → rights[9] = 最大
        let ten = (0..<10).map { block("x", line: $0, y: 0.1 + Double($0) * 0.04, width: 0.1 + Double($0) * 0.08) }
        #expect(abs(LayoutMetrics(blocks: ten).rightEdge - (0.05 + 0.1 + 9 * 0.08)) < 1e-9)
        // n=20：tenth = 2 → rights[18]（第二大）
        let twenty = (0..<20).map { block("x", line: $0, y: 0.1 + Double($0) * 0.04, width: 0.1 + Double($0) * 0.04) }
        #expect(abs(LayoutMetrics(blocks: twenty).rightEdge - (0.05 + 0.1 + 18 * 0.04)) < 1e-9)
    }

    @Test func multiColumnLinesComeFromRowsWithTwoOrMoreCells() {
        let blocks = [block("项目", line: 0, x: 0.05, y: 0.10, width: 0.20),
                      block("结果", line: 1, x: 0.50, y: 0.10, width: 0.10),
                      block("单列", line: 2, x: 0.05, y: 0.20, width: 0.30)]
        let m = LayoutMetrics(blocks: blocks)
        #expect(m.multiColumnLineIndices == [0, 1])
        #expect(m.rows.count == 2)
    }

    @Test func sameColumnAndAdjacencyUseMedianScaledThresholds() {
        let a = LayoutRect(x: 0.05, y: 0.10, width: 0.9, height: 0.03)
        let m = LayoutMetrics(blocks: [TextBlock(text: "a", bbox: a, lineIndex: 0, confidence: 1)])
        // medianHeight = 0.03 → 同列容差 0.045、相邻上限 0.024
        #expect(m.isSameColumn(a, LayoutRect(x: 0.09, y: 0.14, width: 0.2, height: 0.03)))
        #expect(!m.isSameColumn(a, LayoutRect(x: 0.10, y: 0.14, width: 0.2, height: 0.03)))
        #expect(m.isVerticallyAdjacent(a, LayoutRect(x: 0.05, y: 0.15, width: 0.2, height: 0.03)))
        #expect(!m.isVerticallyAdjacent(a, LayoutRect(x: 0.05, y: 0.30, width: 0.2, height: 0.03)))
    }

    @Test func emptyBlocksYieldSafeDefaults() {
        let m = LayoutMetrics(blocks: [])
        #expect(m.medianHeight == LayoutMetrics.minimumMedianHeight)
        #expect(m.rightEdge == 0)
        #expect(m.rows.isEmpty)
        #expect(m.multiColumnLineIndices.isEmpty)
    }

    @Test func tableLineIndicesCoverBodyAndHeader() {
        let cell = { (li: Int) in TableCell(text: "c", bbox: LayoutRect(x: 0, y: 0, width: 0.1, height: 0.1), columnIndex: 0, lineIndices: [li]) }
        let table = TableRegion(id: "t", bbox: LayoutRect(x: 0, y: 0, width: 1, height: 1),
                                rows: [TableRow(cells: [cell(3), cell(4)])], header: TableRow(cells: [cell(2)]))
        let layout = PageLayout(blocks: [], tables: [table])
        #expect(layout.tableLineIndices == [2, 3, 4])
    }

    @Test func unionOfRectsIsMinimalBoundingBox() {
        let rects = [LayoutRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                     LayoutRect(x: 0.5, y: 0.3, width: 0.1, height: 0.2),
                     LayoutRect(x: 0.0, y: 0.2, width: 0.1, height: 0.1)]
        let u = LayoutRect.union(of: rects)
        #expect(u == LayoutRect(x: 0.0, y: 0.1, width: 0.6, height: 0.4))
        #expect(LayoutRect.union(of: []) == nil)
    }
}
