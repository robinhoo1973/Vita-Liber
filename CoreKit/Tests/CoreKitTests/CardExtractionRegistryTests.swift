import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §5.3）：`CardExtractionRegistry` 逐区域失败切换——超时 / 引擎错误 /
/// grounding 产出率低（同轨缩范围重试一次 → 下一轨）/ 不可用 / 未授权 / 页预算，两轨结果按 (row, key) 并集，诊断诚实标注产出轨。
/// 本机 `refactor/scripts/run-domain-tests.sh` 直跑（脚本以 Linux 安全文件子集编译 mini-Infrastructure 模块）。
@Suite("SU-CE4 · 逐区域失败切换")
struct CardExtractionRegistryTests {
    /// 线程安全计数器（引擎被调用次数 / 收到的 spec）。
    private actor Calls {
        var count = 0
        var specs: [ExtractionSpec] = []
        var regionKinds: [RegionKind] = []
        func record(_ spec: ExtractionSpec, _ region: ExtractionRegion) { count += 1; specs.append(spec); regionKinds.append(region.kind) }
    }

    private static let lines = ["处方日期：2026-09-01", "阿莫西林胶囊", "每次1粒", "布洛芬缓释胶囊", "每次1粒"]
    private static func layout() -> PageLayout {
        func b(_ i: Int, x: Double, y: Double, w: Double) -> TextBlock {
            TextBlock(text: lines[i], bbox: LayoutRect(x: x, y: y, width: w, height: 0.05), lineIndex: i, confidence: 0.9)
        }
        return PageLayout(blocks: [b(0, x: 0, y: 0, w: 0.6), b(1, x: 0, y: 0.2, w: 0.3), b(2, x: 0.5, y: 0.2, w: 0.2), b(3, x: 0, y: 0.3, w: 0.3), b(4, x: 0.5, y: 0.3, w: 0.2)])
    }
    private static func anchor(_ line: Int) -> TextAnchor { TextAnchor(pageIndex: 0, lineIndex: line, blockId: "b\(line)", rowId: nil, utf16Range: 0..<0) }
    private static func request(_ specs: [ExtractionSpec], allowsGenerative: Bool = true, pageBudget: Duration? = nil) -> ExtractionRequest {
        ExtractionRequest(pageIndex: 0, lines: lines, regions: layout().extractionRegions(pageIndex: 0), specs: specs,
                          allowsGenerativeProcessing: allowsGenerative, pageConfidence: 0.9, pageBudget: pageBudget)
    }
    /// 规则轨桩：表格区域每行第 0 格为药名。
    private static func rulesEngine(_ calls: Calls? = nil) -> StubCardExtractionEngine {
        StubCardExtractionEngine(track: .rules, regionTimeout: nil) { region, spec in
            await calls?.record(spec, region)
            return RegionExtraction(shared: [:], rows: region.kind == .table ? region.rows.map { row in
                ["drug_name": GroundedValue(value: row.cells[0].text, anchor: anchor(row.cells[0].lineIndices[0]), confidence: 0.6)] } : [])
        }
    }
    private static func prescriptionSpec() throws -> ExtractionSpec { try #require(ExtractionSpecRegistry.spec(for: "prescription")) }

    /// 原名：主轨超时或抛错只让该区域切下一轨且诊断诚实
    @Test func primaryTrackTimeoutOrErrorFallsBackPerRegionWithHonestDiagnostics() async throws {
        let spec = try Self.prescriptionSpec()
        let regions = Self.layout().extractionRegions(pageIndex: 0)
        #expect(regions.map(\.kind) == [.header, .table] && regions[1].rows.count == 2)   // 表头单列行 → header；两列行段 → 合成 table
        let t1 = StubCardExtractionEngine(track: .foundationModels, regionTimeout: .milliseconds(50)) { region, _ in
            if region.kind == .table { try await Task.sleep(for: .seconds(5)) }   // 表格区域超时，表头区域正常
            return RegionExtraction(shared: ["prescribed_at": GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6)], rows: [])
        }
        let started = ContinuousClock.now
        let cards = try await CardExtractionRegistry(engines: [t1, Self.rulesEngine()]).extract(Self.request([spec]))
        let card = try #require(cards.first)
        #expect(ContinuousClock.now - started < .seconds(3), "超时后协作取消，不等 5 秒")
        #expect(card.shared["prescribed_at"]?.value == "2026-09-01")
        #expect(card.rows.map { $0["drug_name"]?.value } == ["阿莫西林胶囊", "布洛芬缓释胶囊"])
        #expect(card.diagnostics.timedOutRegions == 1 && card.diagnostics.degradedReason == .timeout && card.diagnostics.mixedTracks)
        #expect(card.provenance.track == .foundationModels && card.diagnostics.track == .foundationModels, "卡级主轨 = 首个有产出的轨")
        #expect(card.diagnostics.regionTracks["g0"] == [.foundationModels] && card.diagnostics.regionTracks["g1"] == [.rules], "逐区域产出轨")
        #expect(card.provenance.specVersion == spec.version && card.provenance.durationMs >= 0 && card.kind == "prescription" && card.pageIndex == 0)
        #expect(card.shared["prescribed_at"]?.anchor.utf16Range == 5..<15, "grounding 回填锚点范围")
    }

    /// 原名：引擎抛错即本会话内该轨不可用_后续区域直接下一轨
    @Test func engineErrorDisablesTrackForSessionLaterRegionsGoNextTrack() async throws {
        let spec = try Self.prescriptionSpec()
        let calls = Calls()
        let t1 = StubCardExtractionEngine(track: .foundationModels, regionTimeout: .seconds(2)) { region, spec in
            await calls.record(spec, region)
            throw ExtractionEngineError.schemaMismatch
        }
        let card = try #require(try await CardExtractionRegistry(engines: [t1, Self.rulesEngine()]).extract(Self.request([spec])).first)
        #expect(await calls.count == 1, "首区域抛错后该轨被禁用，第二区域不再调用")
        #expect(card.diagnostics.degradedReason == .engineError && !card.diagnostics.mixedTracks)
        #expect(card.provenance.track == .rules && card.rows.count == 2 && card.shared.isEmpty)
        #expect(card.diagnostics.timedOutRegions == 0 && card.diagnostics.retries == 0)
    }

    /// 原名：grounding产出率低先同轨缩范围重试一次再切下一轨并集
    @Test func lowGroundingRetriesSameTrackNarrowedOnceThenFallsBackAndUnions() async throws {
        let spec = try Self.prescriptionSpec()
        let calls = Calls()
        // T1：表头区域给凭空医院 + 真实日期（产出率 1/2 ≥ 0.5 → 通过）；表格区域给两个凭空药名（0/2 → 缩范围重试 → 仍 0 → 切规则轨）。
        let t1 = StubCardExtractionEngine(track: .foundationModels, regionTimeout: .seconds(2)) { region, spec in
            await calls.record(spec, region)
            if region.kind == .header {
                return RegionExtraction(shared: ["prescribed_at": GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6),
                                                 "hospital": GroundedValue(value: "协和医院", anchor: Self.anchor(0), confidence: 0.6)], rows: [])
            }
            return RegionExtraction(shared: [:], rows: [["drug_name": GroundedValue(value: "头孢克肟", anchor: Self.anchor(1), confidence: 0.6)],
                                                       ["drug_name": GroundedValue(value: "奥美拉唑", anchor: Self.anchor(3), confidence: 0.6)]])
        }
        let card = try #require(try await CardExtractionRegistry(engines: [t1, Self.rulesEngine()]).extract(Self.request([spec])).first)
        let specs = await calls.specs
        let kinds = await calls.regionKinds
        #expect(await calls.count == 3)
        #expect(kinds == [.header, .table, .table])
        #expect(specs[1].row.map(\.key) == spec.row.map(\.key) && specs[2].row.map(\.key) == ["drug_name"], "第二次为缩范围 spec")
        #expect(specs[2].shared.map(\.key) == ["prescribed_at"] && specs[2].exemplars.count <= 1)
        #expect(card.diagnostics.retries == 1 && card.diagnostics.degradedReason == .lowGrounding)
        #expect(card.diagnostics.droppedUngrounded == 1 + 2 + 2, "凭空医院 1 + 两次凭空药名 2×2 全部计数")
        #expect(card.shared["prescribed_at"]?.value == "2026-09-01" && card.shared["hospital"] == nil)
        #expect(card.rows.map { $0["drug_name"]?.value } == ["阿莫西林胶囊", "布洛芬缓释胶囊"])
        #expect(card.diagnostics.mixedTracks && card.provenance.track == .foundationModels)
        #expect(card.diagnostics.regionTracks["g1"] == [.rules], "T1 在表格区域零锚定产出——不冒充该区域产出轨")
    }

    /// 原名：两轨同区域结果按行锚并集_同行补键不重复成行
    @Test func twoTracksUnionByRowAnchorAndFillKeysWithoutDuplicatingRows() async throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "metric_sample"))
        let lines = ["报告日期：2026-09-01", "白细胞 6.5 10^9/L", "血红蛋白 150 g/L"]
        let regions = PageLayout.linesOnly(lines).extractionRegions(pageIndex: 0)
        let request = ExtractionRequest(pageIndex: 0, lines: lines, regions: regions, specs: [spec], allowsGenerativeProcessing: true, pageConfidence: 0.8)
        // T1 只给项目名（缺结果 → 每行 1 字段；产出 3 锚定 2：凭空「血小板」→ 2/3 ≥ 0.5 通过；但为演示并集，让其产出率低于 0.5）
        let t1 = StubCardExtractionEngine(track: .foundationModels, regionTimeout: .seconds(2)) { _, _ in
            RegionExtraction(shared: ["measured_at": GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6)],
                             rows: [["raw_label": GroundedValue(value: "白细胞", anchor: Self.anchor(1), confidence: 0.6),
                                     "unit": GroundedValue(value: "mmol/L", anchor: Self.anchor(1), confidence: 0.6)],
                                    ["raw_label": GroundedValue(value: "血小板", anchor: Self.anchor(2), confidence: 0.6),
                                     "value": GroundedValue(value: "300", anchor: Self.anchor(2), confidence: 0.6)]])
        }
        let t3 = StubCardExtractionEngine(track: .rules, regionTimeout: nil) { _, _ in
            RegionExtraction(shared: ["measured_at": GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6)],
                             rows: [["raw_label": GroundedValue(value: "白细胞", anchor: Self.anchor(1), confidence: 0.6),
                                     "value": GroundedValue(value: "6.5", anchor: Self.anchor(1), confidence: 0.6),
                                     "unit": GroundedValue(value: "10^9/L", anchor: Self.anchor(1), confidence: 0.6)],
                                    ["raw_label": GroundedValue(value: "血红蛋白", anchor: Self.anchor(2), confidence: 0.6),
                                     "value": GroundedValue(value: "150", anchor: Self.anchor(2), confidence: 0.6)]])
        }
        let card = try #require(try await CardExtractionRegistry(engines: [t1, t3]).extract(request).first)
        #expect(card.rows.count == 2, "同行锚「白细胞」两轨并为一行")
        #expect(card.rows[0]["raw_label"]?.value == "白细胞" && card.rows[0]["value"]?.value == "6.5" && card.rows[0]["unit"]?.value == "10^9/L")
        #expect(card.rows[1]["raw_label"]?.value == "血红蛋白" && card.rows[1]["value"]?.value == "150")
        #expect(card.shared["measured_at"]?.value == "2026-09-01" && card.shared.count == 1)
        #expect(card.diagnostics.mixedTracks && card.diagnostics.retries == 1 && card.diagnostics.degradedReason == .lowGrounding)
        #expect(card.diagnostics.regionTracks["g0"] == [.foundationModels, .rules])
    }

    /// 原名：不可用轨被跳过并记录原因_全规则轨不算混轨
    @Test func unavailableTrackSkippedWithReasonRulesOnlyIsNotMixed() async throws {
        let spec = try Self.prescriptionSpec()
        struct Unavailable: CardExtractionEngine {
            let track: ExtractionTrack = .localLLM
            let regionTimeout: Duration? = .seconds(20)
            func availability(for request: ExtractionRequest) async -> EngineAvailability { .unavailable(.notInstalled) }
            func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
                Issue.record("不可用引擎不得被调用"); throw ExtractionEngineError.unavailable
            }
        }
        let card = try #require(try await CardExtractionRegistry(engines: [Unavailable(), Self.rulesEngine()]).extract(Self.request([spec])).first)
        #expect(card.diagnostics.degradedReason == .notInstalled && !card.diagnostics.mixedTracks && card.provenance.track == .rules)
        #expect(card.rows.count == 2 && card.diagnostics.regionTracks["g1"] == [.rules])
        let none = try #require(try await CardExtractionRegistry(engines: []).extract(Self.request([spec])).first)
        #expect(none.shared.isEmpty && none.rows.isEmpty && none.provenance.track == .rules && none.diagnostics.degradedReason == .none)
        #expect(try await CardExtractionRegistry(engines: [Self.rulesEngine()]).extract(Self.request([])).isEmpty, "无 spec 无卡")
    }

    /// 原名：关闭生成式处理时生成轨一律不调用
    @Test func generativeTracksNeverCalledWhenGenerativeDisabled() async throws {
        let spec = try Self.prescriptionSpec()
        let calls = Calls()
        let t1 = StubCardExtractionEngine(track: .foundationModels, regionTimeout: .seconds(2)) { region, spec in
            await calls.record(spec, region)
            return RegionExtraction(shared: ["prescribed_at": GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6)], rows: [])
        }
        let card = try #require(try await CardExtractionRegistry(engines: [t1, Self.rulesEngine()]).extract(Self.request([spec], allowsGenerative: false)).first)
        #expect(await calls.count == 0)
        #expect(card.diagnostics.degradedReason == .notAuthorized && card.provenance.track == .rules && card.rows.count == 2)
    }

    /// 原名：页预算耗尽后剩余区域只走规则轨
    @Test func exhaustedPageBudgetSendsRemainingRegionsToRulesTrack() async throws {
        let spec = try Self.prescriptionSpec()
        let calls = Calls()
        let t1 = StubCardExtractionEngine(track: .foundationModels, regionTimeout: .seconds(2)) { region, spec in
            await calls.record(spec, region)
            try await Task.sleep(for: .milliseconds(150))
            return RegionExtraction(shared: ["prescribed_at": GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6)], rows: [])
        }
        let card = try #require(try await CardExtractionRegistry(engines: [t1, Self.rulesEngine()])
            .extract(Self.request([spec], pageBudget: .milliseconds(100))).first)
        #expect(await calls.count == 1, "首区域耗尽页预算，第二区域不再调用生成轨")
        #expect(card.shared["prescribed_at"]?.value == "2026-09-01" && card.rows.count == 2)
        #expect(card.diagnostics.degradedReason == .timeout && card.diagnostics.mixedTracks && card.diagnostics.timedOutRegions == 0)
    }

    /// 原名：多spec各自成卡且共享同键先到先得
    @Test func multipleSpecsProduceSeparateCardsSharingSameKeyFirstWins() async throws {
        let prescription = try Self.prescriptionSpec()
        let encounter = try #require(ExtractionSpecRegistry.spec(for: "encounter"))
        let t3 = StubCardExtractionEngine(track: .rules, regionTimeout: nil) { region, spec in
            guard region.kind == .header else { return RegionExtraction(shared: [:], rows: []) }
            let key = spec.kind == "prescription" ? "prescribed_at" : "date"
            return RegionExtraction(shared: [key: GroundedValue(value: "2026-09-01", anchor: Self.anchor(0), confidence: 0.6)], rows: [])
        }
        let cards = try await CardExtractionRegistry(engines: [t3]).extract(Self.request([prescription, encounter]))
        #expect(cards.map(\.kind) == ["prescription", "encounter"])
        #expect(cards[0].shared["prescribed_at"]?.value == "2026-09-01" && cards[1].shared["date"]?.value == "2026-09-01")
        #expect(cards.allSatisfy { $0.diagnostics.degradedReason == .none && !$0.diagnostics.mixedTracks && $0.provenance.track == .rules })
    }
}
