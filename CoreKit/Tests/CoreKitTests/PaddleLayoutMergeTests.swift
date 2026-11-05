import Testing
import Foundation
@testable import Domain

/// Paddle 主轨 + Vision 副轨合并契约（纯 Domain）。
@Suite("SU-M15-PADDLEMERGE · PaddleLayoutMerge")
struct PaddleLayoutMergeTests {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutRect {
        LayoutRect(x: x, y: y, width: w, height: h)
    }

    private func vision() -> PageLayout {
        PageLayout(blocks: [
            TextBlock(text: "旧一", bbox: rect(0.05, 0.05, 0.40, 0.05), lineIndex: 0, confidence: 0.70),
            TextBlock(text: "旧二", bbox: rect(0.05, 0.15, 0.40, 0.05), lineIndex: 1, confidence: 0.80),
        ])
    }

    @Test("块内命中 Paddle 行 → 文本替换，顺序与几何保持")
    func replaceText() {
        let lines = [
            PaddleLayoutMerge.Line(text: "新一", bbox: rect(0.05, 0.05, 0.40, 0.05), confidence: 0.95),
            PaddleLayoutMerge.Line(text: "新二", bbox: rect(0.05, 0.15, 0.40, 0.05), confidence: 0.90),
        ]
        let result = PaddleLayoutMerge.merge(paddleLines: lines, visionLines: ["旧一", "旧二"],
                                             visionLayout: vision(), visionConfidences: [0.7, 0.8])
        #expect(result.lines == ["新一", "新二"])
        #expect(result.replaced == 2)
        #expect(result.keptVision == 0)
        #expect(result.appended == 0)
        #expect(result.layout.blocks.map(\.lineIndex) == [0, 1])
        #expect(result.layout.blocks[0].bbox == rect(0.05, 0.05, 0.40, 0.05))
        #expect(abs(result.confidence - 0.925) < 0.001)
    }

    @Test("Paddle 空文本 → 保留 Vision 原文")
    func keepVisionWhenPaddleEmpty() {
        let lines = [
            PaddleLayoutMerge.Line(text: "  ", bbox: rect(0.05, 0.05, 0.40, 0.05), confidence: 0.9),
        ]
        let result = PaddleLayoutMerge.merge(paddleLines: lines, visionLines: ["旧一", "旧二"],
                                             visionLayout: vision(), visionConfidences: [0.7, 0.8])
        #expect(result.lines == ["旧一", "旧二"])
        #expect(result.replaced == 0)
        #expect(result.keptVision == 2)
        #expect(result.appended == 0)
    }

    @Test("Vision 漏检 → Paddle 行追加为新块，既有索引不变")
    func appendLeftovers() {
        let lines = [
            PaddleLayoutMerge.Line(text: "新一", bbox: rect(0.05, 0.05, 0.40, 0.05), confidence: 0.9),
            PaddleLayoutMerge.Line(text: "补齐", bbox: rect(0.55, 0.05, 0.30, 0.05), confidence: 0.8),
        ]
        let result = PaddleLayoutMerge.merge(paddleLines: lines, visionLines: ["旧一", "旧二"],
                                             visionLayout: vision(), visionConfidences: [0.7, 0.8])
        #expect(result.lines == ["新一", "旧二", "补齐"])
        #expect(result.appended == 1)
        #expect(result.layout.blocks.map(\.lineIndex) == [0, 1, 2])
    }

    @Test("无 Vision 版面 → 纯 Paddle 按阅读序建块")
    func paddleOnly() {
        let lines = [
            PaddleLayoutMerge.Line(text: "右", bbox: rect(0.60, 0.05, 0.20, 0.05), confidence: 0.9),
            PaddleLayoutMerge.Line(text: "左", bbox: rect(0.10, 0.06, 0.20, 0.05), confidence: 0.9),
        ]
        let result = PaddleLayoutMerge.merge(paddleLines: lines, visionLines: [],
                                             visionLayout: nil, visionConfidences: [])
        #expect(result.lines == ["左", "右"])
        #expect(result.layout.blocks.map(\.lineIndex) == [0, 1])
        #expect(result.appended == 2)
    }

    @Test("表格与段落结构原样保留")
    func keepsTablesAndParagraphs() {
        let cell = TableCell(text: "格", bbox: rect(0.05, 0.05, 0.2, 0.05), columnIndex: 0, lineIndices: [0])
        let table = TableRegion(id: "t0", bbox: rect(0.05, 0.05, 0.4, 0.1),
                                rows: [TableRow(cells: [cell])], header: nil)
        let paragraph = Paragraph(text: "段", bbox: rect(0.05, 0.05, 0.4, 0.1), lineIndices: [0])
        let layout = PageLayout(blocks: vision().blocks, tables: [table], paragraphs: [paragraph])
        let lines = [PaddleLayoutMerge.Line(text: "新一", bbox: rect(0.05, 0.05, 0.40, 0.05),
                                            confidence: 0.9)]
        let result = PaddleLayoutMerge.merge(paddleLines: lines, visionLines: ["旧一", "旧二"],
                                             visionLayout: layout, visionConfidences: [0.7, 0.8])
        #expect(result.layout.tables.count == 1)
        #expect(result.layout.paragraphs.count == 1)
        #expect(result.layout.tableLineIndices.contains(0))
    }

    @Test("一个 Vision 块命中多行 → 按几何行内左右拼接")
    func joinsMultipleLines() {
        let block = TextBlock(text: "整块", bbox: rect(0.05, 0.05, 0.60, 0.05),
                              lineIndex: 0, confidence: 0.6)
        let layout = PageLayout(blocks: [block])
        let lines = [
            PaddleLayoutMerge.Line(text: "右", bbox: rect(0.40, 0.055, 0.20, 0.04), confidence: 0.9),
            PaddleLayoutMerge.Line(text: "左", bbox: rect(0.08, 0.055, 0.20, 0.04), confidence: 0.9),
        ]
        let result = PaddleLayoutMerge.merge(paddleLines: lines, visionLines: ["整块"],
                                             visionLayout: layout, visionConfidences: [0.6])
        #expect(result.lines == ["左 右"])
        #expect(result.layout.blocks.count == 1)
    }
}
