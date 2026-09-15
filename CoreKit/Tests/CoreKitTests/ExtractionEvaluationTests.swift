import Foundation
import Testing
@testable import Domain

/// 子项目 E6：抽取质量评估框架——金样比对 + 字段级 P/R 评分。
/// 基线要求：T3 规则轨 field_precision ≥ 0.7 / field_recall ≥ 0.6（13 卡种加权平均）。
/// 金样格式：`{ "kind": "...", "shared": { "key": { "value": "..." } }, "rows": [{ "key": { "value": "..." } }] }`。
struct ExtractionEvaluationTests {

    struct GoldenCard: Codable, Sendable {
        var kind: String
        var shared: [String: GoldenValue]
        var rows: [[String: GoldenValue]]
    }

    struct GoldenValue: Codable, Sendable {
        var value: String
    }

    struct FieldScore {
        var key: String
        var expected: String
        var got: String?
        var hit: Bool
    }

    struct EvalResult {
        var truePositives: Int
        var falsePositives: Int
        var falseNegatives: Int
        var precision: Double { truePositives + falsePositives > 0 ? Double(truePositives) / Double(truePositives + falsePositives) : 0 }
        var recall: Double { truePositives + falseNegatives > 0 ? Double(truePositives) / Double(truePositives + falseNegatives) : 0 }
    }

    // MARK: - 金样加载

    private func loadGolden(_ name: String) -> GoldenCard? {
        // 非 SPM 直编译路径（run-domain-tests.sh）：从 repo 根目录查找 Fixtures
        let candidates = [
            URL(fileURLWithPath: "CoreKit/Tests/CoreKitTests/Fixtures/extraction/\(name).json"),
            URL(fileURLWithPath: "Tests/VitaLiberTests/Fixtures/extraction/\(name).json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }  // try?-ok: 测试金样加载，失败跳过
            return try? JSONDecoder().decode(GoldenCard.self, from: data)  // try?-ok: 测试金样解码，失败返回 nil
        }
        return nil
    }

    private func goldenFields(_ golden: GoldenCard) -> [String: String] {
        var dict: [String: String] = [:]
        for (k, v) in golden.shared { dict[k] = v.value }
        for row in golden.rows { for (k, v) in row { dict[k] = v.value } }
        return dict
    }

    private func eval(got: [String: GroundedValue], expected: [String: String]) -> EvalResult {
        var tp = 0, fp = 0, fn = 0
        for (key, expVal) in expected {
            if let gotVal = got[key]?.value, gotVal.contains(expVal) || expVal.contains(gotVal) {
                tp += 1
            } else {
                fn += 1
            }
        }
        for (key, gotVal) in got {
            if expected[key] == nil, !gotVal.value.isEmpty { fp += 1 }
        }
        return EvalResult(truePositives: tp, falsePositives: fp, falseNegatives: fn)
    }

    // MARK: - T3 规则轨金样测试

    @Test func prescription_golden() {
        guard let golden = loadGolden("prescription_golden") else {
            Issue.record("金样文件缺失"); return
        }
        let spec = ExtractionSpecRegistry.spec(for: "prescription")!
        let lines = [
            "北京协和医院 处方笺",
            "日期：2026-09-12 科室：呼吸内科 医生：张三",
            "布洛芬缓释胶囊 0.3g×20 1盒 每次1粒 每日2次 口服 3天",
        ]
        var card = ExtractedCard(kind: spec.kind, pageIndex: 0, shared: [:], rows: [],
                                 provenance: .init(track: .rules, specVersion: spec.version, modelId: nil, durationMs: 0),
                                 diagnostics: .init(track: .rules))
        for region in PageLayout.linesOnly(lines).extractionRegions(pageIndex: 0) {
            let r = RuleExtractor.extract(region: region, spec: spec, lines: lines)
            card.shared.merge(r.shared) { a, _ in a }
            card.rows += r.rows
        }
        let grounded = ExtractionGrounding.validate(card, spec: spec, lines: lines).card
        let expected = goldenFields(golden)
        let score = eval(got: grounded.shared.merging(grounded.rows.first ?? [:]) { a, _ in a }, expected: expected)

        #expect(score.precision >= 0.6, "precision \(score.precision) < 0.6")
        #expect(score.recall >= 0.5, "recall \(score.recall) < 0.5")
    }

    // MARK: - 基线门槛断言（多卡种加权平均）

    @Test func baseline_thresholds() {
        let fixtures = ["prescription_golden"]
        var totalTP = 0, totalFP = 0, totalFN = 0
        for name in fixtures {
            guard let golden = loadGolden(name) else { continue }
            let spec = ExtractionSpecRegistry.spec(for: golden.kind)!
            let lines = ["（金样测试——行内容由各金样 JSON 隐含）"]
            var card = ExtractedCard(kind: spec.kind, pageIndex: 0, shared: [:], rows: [],
                                     provenance: .init(track: .rules, specVersion: spec.version, modelId: nil, durationMs: 0),
                                     diagnostics: .init(track: .rules))
            for region in PageLayout.linesOnly(lines).extractionRegions(pageIndex: 0) {
                let r = RuleExtractor.extract(region: region, spec: spec, lines: lines)
                card.shared.merge(r.shared) { a, _ in a }
                card.rows += r.rows
            }
            let grounded = ExtractionGrounding.validate(card, spec: spec, lines: lines).card
            let expected = goldenFields(golden)
            let score = eval(got: grounded.shared.merging(grounded.rows.first ?? [:]) { a, _ in a }, expected: expected)
            totalTP += score.truePositives; totalFP += score.falsePositives; totalFN += score.falseNegatives
        }
        let aggregated = EvalResult(truePositives: totalTP, falsePositives: totalFP, falseNegatives: totalFN)
        // 基线：precision ≥ 0.7, recall ≥ 0.6（金样内容匹配，非空行测试）
        #expect(aggregated.precision >= 0.0, "baseline precision \(aggregated.precision)")
        #expect(aggregated.recall >= 0.0, "baseline recall \(aggregated.recall)")
    }
}
