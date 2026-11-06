import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

@Suite("Core ML extraction engine")
struct CoreMLExtractionEngineTests {
    private func request(lines: [String]) -> ExtractionRequest {
        ExtractionRequest(pageIndex: 0, lines: lines,
                          regions: [ExtractionRegion(
                            pageIndex: 0, id: "g0", kind: .paragraph, columnHeader: nil,
                            rows: [ExtractionRow(id: "r0", cells: [ExtractionCell(text: lines[0], lineIndices: [0], columnIndex: 0)])])],
                          specs: [ExtractionSpecRegistry.spec(for: "prescription")!],
                          allowsGenerativeProcessing: false, pageConfidence: 0.9)
    }

    @Test("maps shared/row matches, clamps confidence and deduplicates")
    func mapsAndDeduplicates() async throws {
        let matcher = StubInformationElementMatching { _, _ in
            [
                InformationElementMatch(key: "hospital", value: "市一医院", confidence: 0.99, sourceLineIndex: 0),
                InformationElementMatch(key: "hospital", value: "另一医院", confidence: 0.9, sourceLineIndex: 0),
                InformationElementMatch(key: "drug_name", value: "阿莫西林", confidence: 0.95, sourceLineIndex: 0),
                InformationElementMatch(key: "not_in_spec", value: "x", confidence: 1, sourceLineIndex: 0),
            ]
        }
        let engine = CoreMLExtractionEngine(matcher: matcher)
        let lines = ["市一医院 阿莫西林"]
        let spec = ExtractionSpecRegistry.spec(for: "prescription")!
        let region = request(lines: lines).regions[0]
        let result = try await engine.extract(region: region, spec: spec, request: request(lines: lines))
        #expect(result.shared["hospital"]?.value == "市一医院")
        #expect(result.shared["hospital"]?.confidence == 0.6)
        #expect(result.rows.count == 1)
        #expect(result.rows[0]["drug_name"]?.value == "阿莫西林")
        #expect(result.shared["not_in_spec"] == nil)
    }

    @Test("unavailable matcher throws instead of producing a fake empty result")
    func unavailableThrows() async {
        let matcher = StubInformationElementMatching(available: false) { _, _ in [] }
        let engine = CoreMLExtractionEngine(matcher: matcher)
        let lines = ["市一医院"]
        let region = request(lines: lines).regions[0]
        await #expect(throws: ExtractionEngineError.self) {
            _ = try await engine.extract(region: region,
                                         spec: ExtractionSpecRegistry.spec(for: "prescription")!,
                                         request: request(lines: lines))
        }
    }

    @Test("Core ML track does not require generative authorization")
    func coreMLIsNotGenerative() {
        #expect(!ExtractionTrack.coreML.requiresGenerativeAuthorization)
        #expect(ExtractionTrack.foundationModels.requiresGenerativeAuthorization)
        #expect(ExtractionTrack.localLLM.requiresGenerativeAuthorization)
        #expect(!ExtractionTrack.rules.requiresGenerativeAuthorization)
    }

    @Test("registry runs Core ML even when generative processing is not authorized")
    func registryRunsCoreMLWithoutGenerativeGate() async throws {
        let matcher = StubInformationElementMatching { _, _ in
            [InformationElementMatch(key: "hospital", value: "市一医院", confidence: 0.95, sourceLineIndex: 0)]
        }
        let registry = CardExtractionRegistry(engines: [
            CoreMLExtractionEngine(matcher: matcher),
            RuleExtractionEngine(),
        ])
        let lines = ["市一医院 阿莫西林"]
        let cards = try await registry.extract(request(lines: lines))
        #expect(cards.first?.provenance.track == .coreML)
        #expect(cards.first?.shared["hospital"]?.value == "市一医院")
    }

    @Test("zero Core ML output does not block the rules track")
    func zeroCoreMLOutputFallsBackToRules() async throws {
        let matcher = StubInformationElementMatching { _, _ in [] }
        let rules = StubCardExtractionEngine(track: .rules, regionTimeout: nil) { _, _ in
            RegionExtraction(shared: ["hospital": GroundedValue(
                value: "市一医院",
                anchor: TextAnchor(pageIndex: 0, lineIndex: 0, blockId: nil, rowId: nil, utf16Range: 0..<4),
                confidence: 0.6)], rows: [])
        }
        let registry = CardExtractionRegistry(engines: [
            CoreMLExtractionEngine(matcher: matcher),
            rules,
        ])
        let cards = try await registry.extract(request(lines: ["市一医院"]))
        #expect(cards.first?.provenance.track == .rules)
        #expect(cards.first?.shared["hospital"]?.value == "市一医院")
    }

    @Test("ungrounded Core ML output does not block the rules track")
    func ungroundedCoreMLOutputFallsBackToRules() async throws {
        // 模型有产出（raw.valueCount > 0）但值不在锚定行 → 产出率 0。
        // 此时若结束区域，规则轨被挡掉，整张卡会缺掉模型漏检的字段。
        let matcher = StubInformationElementMatching { _, _ in
            [InformationElementMatch(key: "hospital", value: "不存在的医院", confidence: 0.99, sourceLineIndex: 0)]
        }
        let rules = StubCardExtractionEngine(track: .rules, regionTimeout: nil) { _, _ in
            RegionExtraction(shared: ["hospital": GroundedValue(
                value: "市一医院",
                anchor: TextAnchor(pageIndex: 0, lineIndex: 0, blockId: nil, rowId: nil, utf16Range: 0..<4),
                confidence: 0.6)], rows: [])
        }
        let registry = CardExtractionRegistry(engines: [
            CoreMLExtractionEngine(matcher: matcher),
            rules,
        ])
        let card = try #require(try await registry.extract(request(lines: ["市一医院"])).first)
        #expect(card.shared["hospital"]?.value == "市一医院")
        #expect(card.provenance.track == .rules)
        #expect(card.diagnostics.degradedReason == .lowGrounding)
    }

    @Test("table row lines are matched one by one and anchored to their own lines")
    func tableRowLinesGetOwnAnchors() async throws {
        // 表格行的多个格各占一个 OCR 行：整行拼接文本不在任一单行内，
        // 逐行匹配后每格以自身行号作锚点（值 = 该行原文）。
        let matcher = StubInformationElementMatching { lines, _ in
            lines.enumerated().compactMap { index, line in
                switch line {
                case "阿莫西林": return InformationElementMatch(key: "drug_name", value: line, confidence: 0.9, sourceLineIndex: index)
                case "0.5g": return InformationElementMatch(key: "dosage", value: line, confidence: 0.9, sourceLineIndex: index)
                case "一日三次": return InformationElementMatch(key: "frequency", value: line, confidence: 0.9, sourceLineIndex: index)
                default: return nil
                }
            }
        }
        let spec = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let lines = ["处方日期：2026-09-01", "阿莫西林", "0.5g", "一日三次"]
        let region = ExtractionRegion(
            pageIndex: 0, id: "t0", kind: .table, columnHeader: nil,
            rows: [ExtractionRow(id: "r0", cells: [
                ExtractionCell(text: "阿莫西林", lineIndices: [1], columnIndex: 0),
                ExtractionCell(text: "0.5g", lineIndices: [2], columnIndex: 1),
                ExtractionCell(text: "一日三次", lineIndices: [3], columnIndex: 2),
            ])])
        let request = ExtractionRequest(pageIndex: 0, lines: lines, regions: [region], specs: [spec],
                                        allowsGenerativeProcessing: false, pageConfidence: 0.9)
        let result = try await CoreMLExtractionEngine(matcher: matcher)
            .extract(region: region, spec: spec, request: request)
        #expect(result.rows.count == 1)
        #expect(result.rows[0]["drug_name"]?.value == "阿莫西林")
        #expect(result.rows[0]["dosage"]?.value == "0.5g")
        #expect(result.rows[0]["frequency"]?.value == "一日三次")
        #expect(result.rows[0]["drug_name"]?.anchor.lineIndex == 1)
        #expect(result.rows[0]["dosage"]?.anchor.lineIndex == 2)
        #expect(result.rows[0]["frequency"]?.anchor.lineIndex == 3)
    }

    @Test("same physical row from Core ML and rules merges by row id")
    func sameRowMergesByRowID() async throws {
        // Core ML 取整行文本、规则轨取拆出的药名：锚值不同，但 anchor.rowId
        // 同为区域行 id —— 必须并为一行，否则确认卡出现重复药品行。
        let matcher = StubInformationElementMatching { _, _ in
            [
                InformationElementMatch(key: "drug_name", value: "阿莫西林", confidence: 0.9, sourceLineIndex: 0),
                InformationElementMatch(key: "dosage", value: "不存在的剂量", confidence: 0.9, sourceLineIndex: 0),
                InformationElementMatch(key: "frequency", value: "不存在的频次", confidence: 0.9, sourceLineIndex: 0),
            ]
        }
        let spec = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let lines = ["处方日期：2026-09-01", "阿莫西林 0.5g"]
        let region = ExtractionRegion(
            pageIndex: 0, id: "t0", kind: .table, columnHeader: nil,
            rows: [ExtractionRow(id: "r0", cells: [
                ExtractionCell(text: "阿莫西林 0.5g", lineIndices: [1], columnIndex: 0)
            ])])
        let request = ExtractionRequest(pageIndex: 0, lines: lines, regions: [region], specs: [spec],
                                        allowsGenerativeProcessing: false, pageConfidence: 0.9)
        let rules = StubCardExtractionEngine(track: .rules, regionTimeout: nil) { _, _ in
            RegionExtraction(shared: [:], rows: [[
                "drug_name": GroundedValue(value: "阿莫西林 0.5g",
                    anchor: TextAnchor(pageIndex: 0, lineIndex: 1, blockId: nil, rowId: "r0", utf16Range: 0..<0),
                    confidence: 0.6),
                "dosage": GroundedValue(value: "0.5g",
                    anchor: TextAnchor(pageIndex: 0, lineIndex: 1, blockId: nil, rowId: "r0", utf16Range: 0..<0),
                    confidence: 0.6),
            ]])
        }
        let card = try #require(try await CardExtractionRegistry(engines: [
            CoreMLExtractionEngine(matcher: matcher),
            rules,
        ]).extract(request).first)
        #expect(card.rows.count == 1)
        #expect(card.rows[0]["drug_name"]?.value == "阿莫西林")
        #expect(card.rows[0]["dosage"]?.value == "0.5g")
    }
}
