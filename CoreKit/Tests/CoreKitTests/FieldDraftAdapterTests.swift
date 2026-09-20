import Foundation
import Testing
@testable import Domain

/// round4 D-2：`GroundedValue.continuation` 自 E2 起存在，适配器从未消费——确认页「原文」只显首行而
/// `value` 三行，用户无法核对后两行出处（BR-002 出处呈现完整性）。本套件钉住三轨归一后的 rawText 语义。
@Suite("SU-OCRA-LAYOUT · FieldDraftAdapter 出处呈现")
struct FieldDraftAdapterTests {
    let lines = ["现病史：患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲", "减退，大小便正常。", "诊断：急性上呼吸道感染"]

    private func anchor(_ line: Int) -> TextAnchor {
        TextAnchor(pageIndex: 0, lineIndex: line, blockId: nil, rowId: nil, utf16Range: 0..<1)
    }

    @Test func rawTextCoversAnchorAndContinuationLines() {
        let gv = GroundedValue(value: "患儿3天前受凉后出现发热，无抽搐，精神尚可，食欲\n减退，大小便正常。",
                               anchor: anchor(0), continuation: [anchor(1)], confidence: 0.9)
        let draft = FieldDraftAdapter.draft(key: "present_illness", gv, lines: lines, pageConfidence: 0.9, track: .rules)
        #expect(draft.rawText == lines[0] + "\n" + lines[1])
        #expect(draft.sourceLineIndex == 0)
    }

    @Test func rawTextStaysSingleLineWithoutContinuation() {
        let gv = GroundedValue(value: "急性上呼吸道感染", anchor: anchor(2), confidence: 0.9)
        let draft = FieldDraftAdapter.draft(key: "diagnosis_text", gv, lines: lines, pageConfidence: 0.9, track: .rules)
        #expect(draft.rawText == lines[2])
    }

    @Test func rawTextSkipsOutOfRangeContinuationFailClosed() {
        // 续行越界：不猜、不拼半截——只保留可定位的行（主锚仍在范围内）。
        let gv = GroundedValue(value: "a\nb", anchor: anchor(2), continuation: [anchor(9)], confidence: 0.9)
        let draft = FieldDraftAdapter.draft(key: "present_illness", gv, lines: lines, pageConfidence: 0.9, track: .rules)
        #expect(draft.rawText == lines[2])
    }

    @Test func rawTextFallsBackToValueWhenAnchorOutOfRange() {
        let gv = GroundedValue(value: "孤值", anchor: anchor(9), confidence: 0.9)
        let draft = FieldDraftAdapter.draft(key: "hospital", gv, lines: lines, pageConfidence: 0.9, track: .rules)
        #expect(draft.rawText == "孤值")
    }

    @Test func confidenceIsCappedAtUnconfirmedCeiling() {
        let gv = GroundedValue(value: "急性上呼吸道感染", anchor: anchor(2), confidence: 0.99)
        let draft = FieldDraftAdapter.draft(key: "diagnosis_text", gv, lines: lines, pageConfidence: 0.95, track: .localLLM)
        #expect(draft.confidence == 0.6)
        #expect(draft.grade == .ocrUnconfirmed)
    }
}
