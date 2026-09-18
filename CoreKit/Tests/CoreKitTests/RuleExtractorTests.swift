import Foundation
import Testing
@testable import Domain

/// 子项目 E3（2026-09-14 实施计划 Task E3）：T3 规则轨——spec 驱动的标签→值 / 列头映射 / 合体行拆分 / 多药成行 / 续表建议。
/// 全部产物必须逐字来自原文并通过 `ExtractionGrounding.validate`（SU-CE2 零违规）；剂量/数量只存原文 + 单位（BR-006/007）。
@Suite("SU-CE5 · T3 规则轨：处方多药成行 / 检验三元组 / 续表建议")
struct RuleExtractorTests {
    private let rx = ExtractionSpecRegistry.spec(for: "prescription")!

    private func regions(_ lines: [String]) -> [ExtractionRegion] {
        PageLayout.linesOnly(lines).extractionRegions(pageIndex: 0)
    }

    private func run(_ spec: ExtractionSpec, _ lines: [String], page: Int = 0) -> ExtractedCard {
        var card = ExtractedCard(kind: spec.kind, pageIndex: page, shared: [:], rows: [],
                                 provenance: .init(track: .rules, specVersion: spec.version, modelId: nil, durationMs: 0),
                                 diagnostics: .init(track: .rules))
        for region in PageLayout.linesOnly(lines).extractionRegions(pageIndex: page) {
            let r = RuleExtractor.extract(region: region, spec: spec, lines: lines)
            card.shared.merge(r.shared) { a, _ in a }
            card.rows += r.rows
        }
        let (grounded, dropped) = ExtractionGrounding.validate(card, spec: spec, lines: lines)
        #expect(dropped == 0, "规则轨产物必须逐字来自原文（SU-CE2 零违规），实际丢弃 \(dropped)")
        return grounded
    }

    @Test func 有列头的三药表格每药一行八字段() {
        let lines = ["北京协和医院 处方笺", "处方日期：2026-09-01", "科室：呼吸内科", "医师：李四",
                     "药品名称 规格 数量 用法用量",
                     "阿莫西林胶囊 0.25g×24 1盒 每次1粒 每日3次 口服 7天",
                     "布洛芬缓释胶囊 0.3g×20 1盒 每次1粒 每日2次 口服 3天",
                     "氨溴索口服溶液 100ml:0.6g 1瓶 每次10ml 每日3次 口服 5天"]
        let card = run(rx, lines)
        #expect(card.shared["prescribed_at"]?.value == "2026-09-01")
        #expect(card.shared["hospital"]?.value == "北京协和医院")
        #expect(card.shared["department"]?.value == "呼吸内科")
        #expect(card.shared["doctor"]?.value == "李四")
        #expect(card.rows.map { $0["drug_name"]?.value } == ["阿莫西林胶囊", "布洛芬缓释胶囊", "氨溴索口服溶液"])
        let r0 = card.rows[0]
        #expect(r0["spec"]?.value == "0.25g×24")
        #expect(r0["quantity"]?.value == "1盒")
        #expect(r0["dosage"]?.value == "1粒")
        #expect(r0["frequency"]?.value == "每日3次")
        #expect(r0["route"]?.value == "口服")
        #expect(r0["days"]?.value == "7")
        #expect(card.rows[2]["dosage"]?.value == "10ml")
        #expect(card.rows[1]["days"]?.value == "3")
    }

    @Test func 两行式处方用法行并入上一药品行不丢第二药() {
        let lines = ["处方 2026-03-02", "1. 阿司匹林肠溶片 100mg×30", "用法：每次1片 每日1次 口服 30天",
                     "2. 阿托伐他汀钙片 20mg×7", "用法：每晚1片 睡前 口服"]
        let card = run(rx, lines)
        #expect(card.rows.count == 2)
        #expect(card.rows[0]["drug_name"]?.value == "阿司匹林肠溶片")
        #expect(card.rows[1]["drug_name"]?.value == "阿托伐他汀钙片")
        #expect(card.rows[0]["frequency"]?.value == "每日1次")
        #expect(card.rows[0]["days"]?.value == "30")
        #expect(card.rows[1]["dosage"]?.value == "1片")
        #expect(card.shared["prescribed_at"]?.value == "2026-03-02", "无标签日期走 firstDateInRegion 兜底")
    }

    @Test(arguments: [
        "阿莫西林胶囊 0.25g 每次1粒 q8h 口服 7天",
        "阿莫西林胶囊 0.25g 一次1粒 bid 口服 7天",
        "阿莫西林胶囊 0.25g 每次1粒 每日两次 口服 7天"
    ])
    /// 原名：合体行频次写法三变体均成行
    func combinedLineFrequencyThreeVariantsAllExtract(_ line: String) {
        let card = run(rx, ["处方日期：2026-09-01", line])
        #expect(card.rows.count == 1)
        #expect(card.rows[0]["drug_name"]?.value == "阿莫西林胶囊")
        #expect(card.rows[0]["dosage"]?.value == "1粒")
        #expect(card.rows[0]["frequency"] != nil)
        #expect(card.rows[0]["days"]?.value == "7")
    }

    /// 审查修复锚点（2026-09-18 业主实测）：整行混排五要素（药名/规格/途径/
    /// 单次量/频次/数量）必须全部拆出；「一天三次」频次写法必须命中。
    @Test func 混排整行五要素全拆() {
        let line = "阿莫西林胶囊 0.5g×24粒 口服 一次2粒 一日三次"
        let split = RuleExtractor.splitPrescriptionLine(line)
        let byKey = Dictionary(split, uniquingKeysWith: { a, _ in a })
        #expect(byKey["drug_name"] == "阿莫西林胶囊")
        // 规格文法含 ×N 包装量（0.5g×24粒 一体，与既有金样同口径）
        #expect(byKey["spec"] != nil && byKey["spec"]!.contains("0.5g") && byKey["spec"]!.contains("24粒"))
        #expect(byKey["route"] == "口服")
        #expect(byKey["dosage"] == "2粒")
        #expect(byKey["frequency"] != nil && byKey["frequency"]!.contains("三次"))
        // 行级管线端到端：混排行成行且五键齐备
        let card = run(rx, ["处方日期：2026-09-01", line])
        #expect(card.rows.count == 1)
        #expect(card.rows[0]["drug_name"]?.value == "阿莫西林胶囊")
        #expect(card.rows[0]["spec"] != nil)
        #expect(card.rows[0]["route"] != nil)
        #expect(card.rows[0]["dosage"] != nil)
        #expect(card.rows[0]["frequency"] != nil)
    }

    /// 审查修复锚点（2026-09-18）：药名与规格间无空格（「胶囊0.5g」）此前
    /// 失配 drugWithSpec（\s+ 要求空格）、行锚丢失。\s* 同收两形态。
    @Test func 无空格规格行锚不丢() {
        let line = "阿莫西林胶囊0.5g×24粒 口服 一次2粒 一天三次"
        let card = run(rx, ["处方日期：2026-09-01", line])
        #expect(card.rows.count == 1, "无空格规格行必须成行（此前被并入上一行或丢弃）")
        #expect(card.rows[0]["drug_name"]?.value == "阿莫西林胶囊")
        #expect(card.rows[0]["frequency"] != nil, "「一天三次」频次写法必须命中")
    }

    /// 审查修复锚点（2026-09-18）：prescriptionNameNeedsSplit 判据——
    /// 混排药名判真（须后拆分），纯药名判假。
    @Test func 混排判据() {
        #expect(RuleExtractor.prescriptionNameNeedsSplit("阿莫西林胶囊 0.5g×24粒 口服 一次2粒 一日三次"))
        #expect(!RuleExtractor.prescriptionNameNeedsSplit("阿莫西林胶囊"))
        #expect(!RuleExtractor.prescriptionNameNeedsSplit("阿莫西林胶囊 0.5g"))
    }

    @Test func 检验合体行三元组与参考范围() {
        let lab = ExtractionSpecRegistry.spec(for: "metric_sample")!
        let card = run(lab, ["检验报告单", "报告日期：2026-09-01", "白细胞 6.5 10^9/L 3.5-9.5", "血红蛋白 150 g/L 115-150", "HbA1c: 5.6%"])
        #expect(card.rows.count == 3)
        #expect(card.rows[0]["raw_label"]?.value == "白细胞")
        #expect(card.rows[0]["value"]?.value == "6.5")
        #expect(card.rows[0]["unit"]?.value == "10^9/L")
        #expect(card.rows[0]["reference_range"]?.value == "3.5-9.5")
        #expect(card.rows[2]["raw_label"]?.value == "HbA1c")
        #expect(card.rows[2]["value"]?.value == "5.6")
        #expect(card.shared["measured_at"]?.value == "2026-09-01")
    }

    @Test func 检验定性与比较符结果原文保留不猜数() {
        let lab = ExtractionSpecRegistry.spec(for: "metric_sample")!
        let card = run(lab, ["报告日期：2026-09-01", "乙肝表面抗原 阴性", "尿蛋白 <0.5 g/L", "白细胞 12.1 10^9/L 3.5-9.5 ↑"])
        let byLabel = Dictionary(uniqueKeysWithValues: card.rows.compactMap { row in row["raw_label"].map { ($0.value, row) } })
        #expect(byLabel["乙肝表面抗原"]?["value"]?.value == "阴性")
        #expect(byLabel["尿蛋白"]?["value"]?.value == "<0.5")
        #expect(byLabel["白细胞"]?["abnormal_flag"]?.value == "↑")
    }

    @Test func 票据合体费用行成行且合计进共享() {
        let claim = ExtractionSpecRegistry.spec(for: "claim_item")!
        let card = run(claim, ["门诊收费票据", "开票日期：2026-09-01", "西药费 98.50", "检验费 120.00", "合计：218.50"])
        #expect(card.rows.map { $0["item_name"]?.value } == ["西药费", "检验费"])
        #expect(card.rows[0]["item_amount"]?.value == "98.50")
        #expect(card.shared["amount"]?.value == "218.50")
    }

    @Test func 标签与值分列两个单元格时取下一格() {
        let region = ExtractionRegion(pageIndex: 0, id: "t0", kind: .header, columnHeader: nil, rows: [
            ExtractionRow(id: "r0", cells: [ExtractionCell(text: "医院", lineIndices: [0], columnIndex: 0),
                                             ExtractionCell(text: "上海市第一人民医院", lineIndices: [0], columnIndex: 1)]),
            ExtractionRow(id: "r1", cells: [ExtractionCell(text: "处方日期", lineIndices: [1], columnIndex: 0),
                                             ExtractionCell(text: "2026年9月1日", lineIndices: [1], columnIndex: 1)]),
        ])
        let lines = ["医院 上海市第一人民医院", "处方日期 2026年9月1日"]
        let r = RuleExtractor.extract(region: region, spec: rx, lines: lines)
        #expect(r.shared["hospital"]?.value == "上海市第一人民医院")
        #expect(r.shared["prescribed_at"]?.value == "2026年9月1日")
    }

    @Test func 标签无值与否认叙事不产字段() {
        let enc = ExtractionSpecRegistry.spec(for: "encounter")!
        let card = run(enc, ["就诊日期：2026-09-01", "既往史：", "过敏史：否认药物过敏", "医院："])
        #expect(card.shared["past_history"] == nil)
        #expect(card.shared["allergy_history"] == nil, "否认/无 叙事不得成为字段（资料建议同口径）")
        #expect(card.shared["hospital"] == nil)
        #expect(card.shared["date"]?.value == "2026-09-01")
    }

    @Test func 续表页只得建议不借用() {
        let p1 = run(rx, ["处方日期：2026-09-01", "科室：呼吸内科", "药品名称 规格 数量 用法用量", "阿莫西林胶囊 0.25g×24 1盒 每次1粒 每日3次 口服 7天"], page: 0)
        let p2 = run(rx, ["药品名称 规格 数量 用法用量", "布洛芬缓释胶囊 0.3g×20 1盒 每次1粒 每日2次 口服 3天"], page: 1)
        let out = ContinuationRules.apply([p1, p2], specs: ExtractionSpecRegistry.spec(for:))
        #expect(out[1].shared["prescribed_at"] == nil, "续表页不得直接借用上一页共享字段")
        #expect(out[1].continuationHint["prescribed_at"]?.value == "2026-09-01")
        #expect(out[1].continuationHint["department"]?.value == "呼吸内科")
        #expect(out[0].continuationHint.isEmpty)
    }
}
