import Foundation
import Testing
@testable import Domain

// binds: FR6.1 换行归并几何证据（业主 2026-09-20 Q1「无法理解分段/换行」）
@Suite("FR6.1 几何折行归并")
struct TextLineMergerGeometryTests {
    /// 造块：同列左缘 x=0.05，行高 0.03，行距 0.035；width 按给定
    private func block(_ text: String, line: Int, x: Double = 0.05, width: Double, y: Double? = nil) -> TextBlock {
        TextBlock(text: text, bbox: LayoutRect(x: x, y: y ?? (0.1 + Double(line) * 0.035), width: width, height: 0.03),
                  lineIndex: line, confidence: 0.9)
    }

    @Test func wrappedNarrativeWithDigitsMergesUnderGeometry() {
        // 上行含数字（旧规则 3 拦下）但写满列宽、下行同列相邻更短 → 合
        let blocks = [
            block("主诉：发热3天，最高39.2℃，伴咳嗽、流涕，服用布洛芬后", line: 0, width: 0.90),
            block("体温可暂退。", line: 1, width: 0.20),
            block("诊断：急性上呼吸道感染", line: 2, width: 0.40),
        ]
        let merged = TextLineMerger.merge(blocks: blocks)
        #expect(merged.map(\.text) == ["主诉：发热3天，最高39.2℃，伴咳嗽、流涕，服用布洛芬后体温可暂退。", "诊断：急性上呼吸道感染"])
        #expect(merged[0].sourceIndices == [0, 1])
    }

    @Test func wrapAfterCommaMerges() {
        let blocks = [
            block("现病史：患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲", line: 0, width: 0.90),
            block("减退，大小便正常。", line: 1, width: 0.30),
        ]
        #expect(TextLineMerger.merge(blocks: blocks).map(\.text) == ["现病史：患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲减退，大小便正常。"])
    }

    @Test func shortLabelNeverMergesWithValueLine() {
        // 「血压」未写满列宽 → 几何证据不成立 → 不合（文本规则本就拦）
        let blocks = [block("血压", line: 0, width: 0.08), block("120/80 mmHg", line: 1, width: 0.20)]
        #expect(TextLineMerger.merge(blocks: blocks).count == 2)
    }

    @Test func sentenceTerminalPunctuationStopsMerge() {
        let blocks = [
            block("患者一般情况可，无发热，无咳嗽，无胸闷气促，饮食睡眠正常。", line: 0, width: 0.90),
            block("既往体健。", line: 1, width: 0.15),
        ]
        #expect(TextLineMerger.merge(blocks: blocks).count == 2)
    }

    @Test func tableLinesNeverMerge() {
        let blocks = [
            block("血红蛋白        135       g/L      115-150", line: 0, width: 0.90),
            block("白细胞计数      6.2       10^9/L   3.5-9.5", line: 1, width: 0.90),
        ]
        #expect(TextLineMerger.merge(blocks: blocks, tableLineIndices: [0, 1]).count == 2)
    }

    @Test func multiColumnRowNeverMerges() {
        // 同一视觉行两块（表头两列）→ 与下一行不合
        let blocks = [
            block("项目名称", line: 0, x: 0.05, width: 0.20),
            block("结果", line: 1, x: 0.50, width: 0.10, y: 0.1),
            block("血红蛋白", line: 2, x: 0.05, width: 0.20),
        ]
        #expect(TextLineMerger.merge(blocks: blocks).count == 3)
    }

    @Test func differentParagraphsNeverMerge() {
        let blocks = [
            block("主诉：发热3天，最高39.2℃，伴咳嗽、流涕，服用布洛芬后", line: 0, width: 0.90),
            block("体温可暂退。", line: 1, width: 0.20),
        ]
        let paragraphs = [
            Paragraph(text: blocks[0].text, bbox: blocks[0].bbox, lineIndices: [0]),
            Paragraph(text: blocks[1].text, bbox: blocks[1].bbox, lineIndices: [1]),
        ]
        #expect(TextLineMerger.merge(blocks: blocks, paragraphs: paragraphs).count == 2)
    }

    @Test func largeGapStopsMerge() {
        var second = block("体温可暂退。", line: 1, width: 0.20)
        second = TextBlock(text: second.text, bbox: LayoutRect(x: 0.05, y: 0.30, width: 0.20, height: 0.03), lineIndex: 1, confidence: 0.9)
        let blocks = [block("主诉：发热3天，最高39.2℃，伴咳嗽、流涕，服用布洛芬后", line: 0, width: 0.90), second]
        #expect(TextLineMerger.merge(blocks: blocks).count == 2)
    }

    @Test func narrowEqualWidthRowsNeverMergeWithoutAbsoluteFloor() {
        // round3 开发委员反例：全窄列收据（等宽相邻短行）——rightEdge 90 分位退化时
        // 「上行写满」恒真，绝对宽度下限（≥0.5）拦下错合。
        let blocks = [
            block("对乙酰氨基酚片", line: 0, width: 0.18),
            block("维生素C片", line: 1, width: 0.18),
        ]
        #expect(TextLineMerger.merge(blocks: blocks).count == 2)
    }

    @Test func textualRuleStillMergesWithoutGeometry() {
        // 纯文本路径不变（回归）
        #expect(TextLineMerger.mergedText(["阿莫西林克拉维酸钾分", "散片"]) == ["阿莫西林克拉维酸钾分散片"])
    }
}
