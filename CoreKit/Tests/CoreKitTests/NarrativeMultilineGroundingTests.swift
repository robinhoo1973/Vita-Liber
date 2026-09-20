import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

@Suite("R3 叙事值多行放行")
struct NarrativeMultilineGroundingTests {
    let lines = ["现病史：患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲", "减退，大小便正常。", "诊断：急性上呼吸道感染"]

    @Test func groundingAcceptsConsecutiveWholeLinesForNarrative() {
        let span = OCRExtractedSpan(key: "present_illness",
                                    value: "患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲\n减退，大小便正常。", lineIndex: 0)
        let fields = OCRGrounding.fields([span], lines: lines)
        #expect(fields.count == 1)
        #expect(fields.first?.value == "患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲\n减退，大小便正常。")
        #expect(fields.first?.rawText == lines[0] + "\n" + lines[1])
        #expect(fields.first?.sourceLineIndex == 0)
    }

    @Test func groundingRejectsPartialContinuationSegment() {
        // 第二段不是整行 → 拒（不许摘要/截断）
        let span = OCRExtractedSpan(key: "present_illness", value: "患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲\n减退", lineIndex: 0)
        #expect(OCRGrounding.fields([span], lines: lines).isEmpty)
    }

    @Test func groundingRejectsNonAdjacentSegments() {
        let span = OCRExtractedSpan(key: "present_illness", value: "患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲\n诊断：急性上呼吸道感染", lineIndex: 0)
        #expect(OCRGrounding.fields([span], lines: lines).isEmpty)
    }

    @Test func nonNarrativeKeyStillSingleLine() {
        let span = OCRExtractedSpan(key: "hospital", value: "a\nb", lineIndex: 0)
        #expect(OCRGrounding.fields([span], lines: ["a", "b"]).isEmpty)
    }

    @Test func assemblerBuildsContinuationAnchors() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "encounter"))
        let span = ModelSpan(key: "present_illness", value: "患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲\n减退，大小便正常。", unit: nil, lineIndex: 0)
        let region = ModelSpanAssembler.region(shared: [span], rows: [], spec: spec, lines: lines, pageIndex: 0)
        let gv = try #require(region.shared["present_illness"])
        #expect(gv.anchor.lineIndex == 0)
        #expect(gv.continuation.map(\.lineIndex) == [1])
        // 经 ExtractionGrounding 分段校验仍通过
        let card = ExtractedCard(kind: spec.kind, pageIndex: 0, shared: region.shared, rows: [],
                                 provenance: .init(track: .foundationModels, specVersion: spec.version, modelId: nil, durationMs: 0),
                                 diagnostics: .init(track: .foundationModels))
        #expect(ExtractionGrounding.validate(card, spec: spec, lines: lines).card.shared["present_illness"] != nil)
    }
}
