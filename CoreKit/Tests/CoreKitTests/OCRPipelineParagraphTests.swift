import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// R2：iOS 26 段落曾只用于关闭归并；本测试钉住「段内几何归并 + 段间不合 + 版面重映射」。
@Suite("SU-OCRA-LAYOUT · OCRPipeline 段落边界归并")
struct OCRPipelineParagraphTests {
    struct Decoder: GrayscaleDecoding {
        func decode(_ data: Data, maxDimension: Int) throws -> GrayscaleImage {
            GrayscaleImage(width: 4, height: 4, buffer: [UInt8](repeating: 128, count: 16))
        }
    }
    private func block(_ text: String, line: Int, y: Double, width: Double) -> TextBlock {
        TextBlock(text: text, bbox: LayoutRect(x: 0.05, y: y, width: width, height: 0.03), lineIndex: line, confidence: 0.9)
    }

    @Test func mergesInsideVisionParagraphAndRemapsIndices() async throws {
        let lines = ["主诉：发热3天，最高39.2℃，伴咳嗽、流涕，服用布洛芬后", "体温可暂退。", "诊断：急性上呼吸道感染"]
        let blocks = [block(lines[0], line: 0, y: 0.10, width: 0.90), block(lines[1], line: 1, y: 0.135, width: 0.20),
                      block(lines[2], line: 2, y: 0.25, width: 0.40)]
        let paragraphs = [
            Paragraph(text: lines[0] + "\n" + lines[1], bbox: blocks[0].bbox.union(blocks[1].bbox), lineIndices: [0, 1]),
            Paragraph(text: lines[2], bbox: blocks[2].bbox, lineIndices: [2]),
        ]
        let recognizer = StubImageTextRecognizer(scripted: .init(lines: lines, confidence: 0.9,
                                                                  layout: PageLayout(blocks: blocks, paragraphs: paragraphs)))
        let result = try await OCRPipeline(recognizer: recognizer, grayscaleDecoder: Decoder()).run(imageData: Data([1, 2, 3]))
        #expect(result.lines == ["主诉：发热3天，最高39.2℃，伴咳嗽、流涕，服用布洛芬后体温可暂退。", "诊断：急性上呼吸道感染"])
        let layout = try #require(result.layout)
        #expect(layout.blocks.map(\.lineIndex) == [0, 1])
        #expect(layout.blocks[0].text == result.lines[0])
        #expect(layout.paragraphs.map(\.lineIndices) == [[0], [1]])
        #expect(layout.paragraphs[0].text == result.lines[0])
    }

    @Test func derivesParagraphsGeometricallyWhenVisionGivesNone() async throws {
        let lines = ["现病史：患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲", "减退，大小便正常。", "诊断：急性上呼吸道感染"]
        let blocks = [block(lines[0], line: 0, y: 0.10, width: 0.90), block(lines[1], line: 1, y: 0.135, width: 0.30),
                      block(lines[2], line: 2, y: 0.30, width: 0.40)]
        let recognizer = StubImageTextRecognizer(scripted: .init(lines: lines, confidence: 0.9, layout: PageLayout(blocks: blocks)))
        let result = try await OCRPipeline(recognizer: recognizer, grayscaleDecoder: Decoder()).run(imageData: Data([1]))
        #expect(result.lines.count == 2)
        let layout = try #require(result.layout)
        #expect(layout.paragraphs.count == 2)
    }

    @Test func tableRowsStayUnmergedAndRemap() async throws {
        let lines = ["检验报告", "血红蛋白 135 g/L 115-150", "白细胞 6.2 10^9/L 3.5-9.5"]
        let blocks = [block(lines[0], line: 0, y: 0.05, width: 0.30), block(lines[1], line: 1, y: 0.10, width: 0.90),
                      block(lines[2], line: 2, y: 0.135, width: 0.90)]
        let table = TableRegion(id: "t0", bbox: blocks[1].bbox.union(blocks[2].bbox), rows: [
            TableRow(cells: [TableCell(text: lines[1], bbox: blocks[1].bbox, columnIndex: 0, lineIndices: [1])]),
            TableRow(cells: [TableCell(text: lines[2], bbox: blocks[2].bbox, columnIndex: 0, lineIndices: [2])]),
        ])
        let recognizer = StubImageTextRecognizer(scripted: .init(lines: lines, confidence: 0.9,
                                                                  layout: PageLayout(blocks: blocks, tables: [table])))
        let result = try await OCRPipeline(recognizer: recognizer, grayscaleDecoder: Decoder()).run(imageData: Data([1]))
        #expect(result.lines == lines)
        #expect(result.layout?.tables.first?.rows.flatMap { $0.cells.flatMap(\.lineIndices) } == [1, 2])
    }
}
