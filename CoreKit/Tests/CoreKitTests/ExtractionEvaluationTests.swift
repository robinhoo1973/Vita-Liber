import Foundation
import Testing
@testable import Domain

/// 子项目 E6：抽取质量评估框架——金样比对 + 字段级 P/R 评分（Stage 0 修复，2026-09-20）。
/// 基线要求：T3 规则轨 field_precision ≥ 0.7 / field_recall ≥ 0.6（多卡种加权）。
/// 金样格式：`{ "kind", "lines": [...真实源行], "shared": {key: {value}}, "rows": [{key: {value}}] }`——
/// `lines` 是 harness 唯一输入；期望值必须逐字出现在源行中（`goldenLinesAreVerbatimSources` 钉住）。
@Suite("SU-OCR0-EVAL · 抽取金样 P/R")
struct ExtractionEvaluationTests {

    struct GoldenCard: Codable, Sendable {
        var kind: String
        var lines: [String]                 // 真实源行——harness 唯一输入
        var shared: [String: GoldenValue]
        var rows: [[String: GoldenValue]]
    }

    struct GoldenValue: Codable, Sendable {
        var value: String
    }

    struct EvalResult {
        var truePositives: Int
        var falsePositives: Int
        var falseNegatives: Int
        var precision: Double { truePositives + falsePositives > 0 ? Double(truePositives) / Double(truePositives + falsePositives) : 0 }
        var recall: Double { truePositives + falseNegatives > 0 ? Double(truePositives) / Double(truePositives + falseNegatives) : 0 }
    }

    /// 定标常量：2026-09-20 首测见 baseline_thresholds 打印。
    /// 口径纪律（round3 委员会裁定）：任何下调 = 独立复核提交（diff 仅常量+注释，
    /// 提交信息附逐卡 P/R 打印），禁止与 harness 改动同提交。
    enum GoldenBaseline {
        static let precisionFloor = 0.7
        static let recallFloor = 0.6
    }

    // MARK: - 金样加载

    private func loadGolden(_ name: String) -> GoldenCard? {
        // 两种执行宿主：swift test（cwd = 包根 CoreKit/，macOS CI 与本机同此路径）
        // 与 run-domain-tests.sh（cwd = repo 根）。
        let candidates = [
            URL(fileURLWithPath: "Tests/CoreKitTests/Fixtures/extraction/\(name).json"),
            URL(fileURLWithPath: "CoreKit/Tests/CoreKitTests/Fixtures/extraction/\(name).json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }  // try?-ok: 测试金样加载，失败跳过
            return try? JSONDecoder().decode(GoldenCard.self, from: data)  // try?-ok: 测试金样解码，失败返回 nil
        }
        return nil
    }

    // MARK: - 归一化等值：单源 `ExtractionGrounding.folded`（round4 P-10：与 locate 同一实现而非同纪律副本）

    static func normalized(_ s: String) -> String { ExtractionGrounding.folded(s) }

    private func equalNormalized(_ a: String, _ b: String) -> Bool {
        Self.normalized(a) == Self.normalized(b)
    }

    // MARK: - 行对齐评分（round3 裁定：shared 按键计；rows 按序配对逐行逐字段计）

    private func eval(got: (shared: [String: GroundedValue], rows: [[String: GroundedValue]]),
                      expected: (shared: [String: String], rows: [[String: String]])) -> EvalResult {
        var tp = 0, fp = 0, fn = 0
        // shared：按键计
        for (key, exp) in expected.shared {
            if let g = got.shared[key], equalNormalized(g.value, exp) { tp += 1 } else { fn += 1 }
        }
        for (key, g) in got.shared where expected.shared[key] == nil {
            if !g.value.isEmpty { fp += 1 }
        }
        // rows：按序配对，逐行逐字段计；行数不等按多出/缺失整行计
        let pairCount = min(expected.rows.count, got.rows.count)
        for i in 0..<pairCount {
            for (key, exp) in expected.rows[i] {
                if let g = got.rows[i][key], equalNormalized(g.value, exp) { tp += 1 } else { fn += 1 }
            }
            for (key, g) in got.rows[i] where expected.rows[i][key] == nil {
                if !g.value.isEmpty { fp += 1 }
            }
        }
        if expected.rows.count > got.rows.count {
            for i in pairCount..<expected.rows.count { fn += expected.rows[i].count }
        }
        if got.rows.count > expected.rows.count {
            for i in pairCount..<got.rows.count { fp += got.rows[i].count }
        }
        return EvalResult(truePositives: tp, falsePositives: fp, falseNegatives: fn)
    }

    // MARK: - T3 规则轨跑分（真实源行 → linesOnly 版面 → 区域 → 抽取 → grounding）

    private func runT3(_ golden: GoldenCard) -> (shared: [String: GroundedValue], rows: [[String: GroundedValue]]) {
        guard let spec = ExtractionSpecRegistry.spec(for: golden.kind) else { return ([:], []) }
        var card = ExtractedCard(kind: spec.kind, pageIndex: 0, shared: [:], rows: [],
                                 provenance: .init(track: .rules, specVersion: spec.version, modelId: nil, durationMs: 0),
                                 diagnostics: .init(track: .rules))
        for region in PageLayout.linesOnly(golden.lines).extractionRegions(pageIndex: 0) {
            let r = RuleExtractor.extract(region: region, spec: spec, lines: golden.lines)
            card.shared.merge(r.shared) { a, _ in a }
            card.rows += r.rows
        }
        let grounded = ExtractionGrounding.validate(card, spec: spec, lines: golden.lines).card
        var outShared: [String: GroundedValue] = [:]
        for (k, v) in grounded.shared { outShared[k] = v }
        var outRows: [[String: GroundedValue]] = []
        for row in grounded.rows {
            var dict: [String: GroundedValue] = [:]
            for (k, v) in row { dict[k] = v }
            outRows.append(dict)
        }
        return (outShared, outRows)
    }

    private func goldenExpectation(_ golden: GoldenCard) -> (shared: [String: String], rows: [[String: String]]) {
        let shared = golden.shared.mapValues(\.value)
        let rows = golden.rows.map { $0.mapValues(\.value) }
        return (shared, rows)
    }

    // MARK: - 金样自洽：期望值逐字来自源行（grounding 纪律）

    @Test(arguments: ["prescription_golden", "lab_golden", "encounter_golden"])
    func goldenLinesAreVerbatimSources(_ name: String) throws {
        let golden = try #require(loadGolden(name), "金样 \(name) 缺失")
        #expect(!golden.lines.isEmpty, "\(name) 缺 lines")
        let joined = golden.lines.joined(separator: "\n")
        for (k, v) in golden.shared {
            for segment in v.value.components(separatedBy: "\n") {
                #expect(joined.contains(segment), "\(name).shared.\(k) 段「\(segment)」不在源行中")
            }
        }
        for (i, row) in golden.rows.enumerated() {
            for (k, v) in row {
                #expect(joined.contains(v.value), "\(name).rows[\(i)].\(k)「\(v.value)」不在源行中")
            }
        }
    }

    // MARK: - 基线门槛断言（多卡种加权，真实源行）

    @Test func baseline_thresholds() throws {
        let fixtures = ["prescription_golden", "lab_golden", "encounter_golden"]
        var totalTP = 0, totalFP = 0, totalFN = 0
        var perKind: [String: EvalResult] = [:]
        for name in fixtures {
            let golden = try #require(loadGolden(name), "金样 \(name) 缺失")
            let score = eval(got: runT3(golden), expected: goldenExpectation(golden))
            perKind[golden.kind] = score
            totalTP += score.truePositives; totalFP += score.falsePositives; totalFN += score.falseNegatives
        }
        for (kind, s) in perKind.sorted(by: { $0.key < $1.key }) {
            print("[golden] \(kind) P=\(String(format: "%.3f", s.precision)) R=\(String(format: "%.3f", s.recall)) TP=\(s.truePositives) FP=\(s.falsePositives) FN=\(s.falseNegatives)")
        }
        let aggregated = EvalResult(truePositives: totalTP, falsePositives: totalFP, falseNegatives: totalFN)
        print("[golden] aggregated P=\(String(format: "%.3f", aggregated.precision)) R=\(String(format: "%.3f", aggregated.recall))")
        #expect(aggregated.precision >= GoldenBaseline.precisionFloor, "baseline precision \(aggregated.precision)")
        #expect(aggregated.recall >= GoldenBaseline.recallFloor, "baseline recall \(aggregated.recall)")
    }
}
