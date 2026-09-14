import Foundation
import Testing
@testable import Domain

/// FR5.5 / round2 O-N3 上游：识别层丢掉 bbox 即无行身份。几何聚行须确定、与输入顺序无关。
/// 子项目 E1（2026-09-14 实施计划 Task E1）：`PageLayout` / `LayoutRowBuilder` Domain 纯函数用例，
/// 合成 bbox 覆盖单列、两列标签/值、五列处方表、轻微倾斜四种版面；
/// 仅 `@testable import Domain`，本机 `refactor/scripts/run-domain-tests.sh` 直跑。
@Suite("SU-CE-LAYOUT · 版面几何聚行（子项目 E1）")
struct LayoutRowBuilderTests {
    private func block(_ text: String, x: Double, y: Double, w: Double = 0.1, h: Double = 0.03, line: Int) -> TextBlock {
        TextBlock(text: text, bbox: LayoutRect(x: x, y: y, width: w, height: h), lineIndex: line, confidence: 0.9)
    }

    // MARK: 计划 Step 1 三用例

    @Test func 同y带三块聚为一行按x排列并分三列() {
        let blocks = [block("阿莫西林胶囊", x: 0.05, y: 0.30, line: 2), block("0.25g×24", x: 0.45, y: 0.305, line: 4),
                      block("每次1粒 每日3次", x: 0.70, y: 0.31, line: 3),
                      block("布洛芬缓释胶囊", x: 0.05, y: 0.36, line: 5), block("0.3g×20", x: 0.45, y: 0.362, line: 6),
                      block("每次1粒 每日2次", x: 0.70, y: 0.36, line: 7)]
        let rows = LayoutRowBuilder.rows(from: blocks)
        #expect(rows.count == 2)
        #expect(rows[0].cells.map(\.text) == ["阿莫西林胶囊", "0.25g×24", "每次1粒 每日3次"])
        #expect(rows[0].cells.map(\.columnIndex) == [0, 1, 2] && rows[1].cells.map(\.columnIndex) == [0, 1, 2])
        #expect(rows[0].lineIndices == [2, 4, 3])
    }

    @Test func 乱序输入结果相同且竖向不重叠的块不合并() {
        let a = [block("A", x: 0.1, y: 0.10, line: 0), block("B", x: 0.1, y: 0.20, line: 1)]
        #expect(LayoutRowBuilder.rows(from: a).count == 2)
        #expect(LayoutRowBuilder.rows(from: a.reversed()) == LayoutRowBuilder.rows(from: a))
    }

    @Test func 仅行文本退化为每行一块一行() {
        let layout = PageLayout.linesOnly(["处方笺", "阿莫西林胶囊 0.25g"])
        #expect(layout.blocks.count == 2 && layout.blocks[1].lineIndex == 1 && layout.blocks[1].id == "b1")
        #expect(LayoutRowBuilder.rows(from: layout.blocks).count == 2)
        #expect(ImageInputRules.Recognition(lines: ["x"], confidence: 0.5).layout == nil)
    }

    // MARK: 版面形态补充用例

    @Test func 单列文本每块自成一行且全部归第0列() {
        let blocks = (0..<6).map { i in block("第\(i)行", x: 0.05, y: 0.10 + Double(i) * 0.05, w: 0.6, line: i) }
        let rows = LayoutRowBuilder.rows(from: blocks)
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { $0.cells.count == 1 && $0.cells[0].columnIndex == 0 })
        #expect(rows.map(\.id) == ["r0", "r1", "r2", "r3", "r4", "r5"])
        #expect(rows.map { $0.lineIndices[0] } == [0, 1, 2, 3, 4, 5])
    }

    @Test func 两列标签值成对同行且缺值行标签仍在第0列() {
        let blocks = [block("姓名", x: 0.05, y: 0.10, line: 0), block("张三", x: 0.30, y: 0.102, line: 1),
                      block("科室", x: 0.05, y: 0.15, line: 2), block("内科", x: 0.30, y: 0.148, line: 3),
                      block("诊断", x: 0.05, y: 0.20, line: 4)]
        let rows = LayoutRowBuilder.rows(from: blocks)
        #expect(rows.count == 3)
        #expect(rows[0].cells.map(\.text) == ["姓名", "张三"] && rows[0].cells.map(\.columnIndex) == [0, 1])
        #expect(rows[1].cells.map(\.text) == ["科室", "内科"] && rows[1].cells.map(\.columnIndex) == [0, 1])
        #expect(rows[2].cells.map(\.text) == ["诊断"] && rows[2].cells.map(\.columnIndex) == [0])
        #expect(rows[0].text == "姓名 张三")
    }

    @Test func 五列处方表按x对齐分列且缺格行保留真实列号() {
        let xs = [0.05, 0.30, 0.50, 0.65, 0.85]
        let header = ["药品名称", "规格", "数量", "用法", "用量"]
        let drugA = ["阿莫西林胶囊", "0.25g", "24", "口服", "每次1粒"]
        var blocks: [TextBlock] = []
        for (c, t) in header.enumerated() { blocks.append(block(t, x: xs[c], y: 0.20, w: 0.08, line: c)) }
        for (c, t) in drugA.enumerated() { blocks.append(block(t, x: xs[c], y: 0.25, w: 0.08, line: 5 + c)) }
        // 第二味药「数量」格为空——列号须按 x 对齐取 3/4，而非按顺位取 2/3。
        blocks.append(block("布洛芬缓释胶囊", x: 0.05, y: 0.30, w: 0.08, line: 10))
        blocks.append(block("0.3g", x: 0.30, y: 0.30, w: 0.08, line: 11))
        blocks.append(block("口服", x: 0.65, y: 0.30, w: 0.08, line: 12))
        blocks.append(block("每次1粒", x: 0.85, y: 0.30, w: 0.08, line: 13))
        let rows = LayoutRowBuilder.rows(from: blocks.shuffled())
        #expect(rows.count == 3)
        #expect(rows[0].cells.map(\.text) == header && rows[0].cells.map(\.columnIndex) == [0, 1, 2, 3, 4])
        #expect(rows[1].cells.map(\.text) == drugA && rows[1].cells.map(\.columnIndex) == [0, 1, 2, 3, 4])
        #expect(rows[2].cells.map(\.text) == ["布洛芬缓释胶囊", "0.3g", "口服", "每次1粒"])
        #expect(rows[2].cells.map(\.columnIndex) == [0, 1, 3, 4])
        #expect(rows[1].lineIndices == [5, 6, 7, 8, 9])
    }

    @Test func 轻微倾斜扫描行内y漂移与列x抖动仍聚同行同列() {
        // 每列 y 漂移 0.003（行高 0.03，跨五列共漂 0.012 ≈ 40% 行高）；同列 x 抖动 ±0.01。
        let row1X = [0.05, 0.30, 0.50, 0.65, 0.85], row2X = [0.06, 0.29, 0.51, 0.66, 0.84]
        var blocks: [TextBlock] = []
        for c in 0..<5 { blocks.append(block("甲\(c)", x: row1X[c], y: 0.30 + Double(c) * 0.003, w: 0.08, line: c)) }
        for c in 0..<5 { blocks.append(block("乙\(c)", x: row2X[c], y: 0.36 + Double(c) * 0.003, w: 0.08, line: 5 + c)) }
        let rows = LayoutRowBuilder.rows(from: blocks)
        #expect(rows.count == 2)
        #expect(rows[0].cells.map(\.text) == ["甲0", "甲1", "甲2", "甲3", "甲4"])
        #expect(rows[1].cells.map(\.text) == ["乙0", "乙1", "乙2", "乙3", "乙4"])
        #expect(rows[0].cells.map(\.columnIndex) == [0, 1, 2, 3, 4] && rows[1].cells.map(\.columnIndex) == [0, 1, 2, 3, 4])
        // 行 bbox 为各格并集：覆盖最左格左缘与最右格右缘。
        #expect(abs(rows[0].bbox.x - 0.05) < 1e-9 && abs(rows[0].bbox.x + rows[0].bbox.width - 0.93) < 1e-9)
    }

    @Test func 空输入返回空且矩形并集覆盖两者() {
        #expect(LayoutRowBuilder.rows(from: []).isEmpty)
        let u = LayoutRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1).union(LayoutRect(x: 0.5, y: 0.1, width: 0.1, height: 0.3))
        #expect(abs(u.x - 0.1) < 1e-9 && abs(u.y - 0.1) < 1e-9)
        #expect(abs(u.maxX - 0.6) < 1e-9 && abs(u.maxY - 0.4) < 1e-9)
        #expect(PageLayout(blocks: []).tables.isEmpty && PageLayout(blocks: []).paragraphs.isEmpty)
    }
}
