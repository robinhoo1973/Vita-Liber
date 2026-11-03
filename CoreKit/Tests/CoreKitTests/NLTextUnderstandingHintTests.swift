import Foundation
import Testing
@testable import Infrastructure
@testable import Domain

/// 2026-11-03 真机：手选资料类型必须能强制理解层按该类型抽取，
/// 否则自动判定失败时页字段只剩 line_N，数据信息元恒空。
@Suite("SU-FR6.9 · 理解层类型提示")
struct NLTextUnderstandingHintTests {
    @Test("documentTypeHint=lab_report 强制目标并产出 lab_item")
    func forcedLabReportTarget() async throws {
        let engine = NLTextUnderstanding()
        let lines = ["血红蛋白 150 g/L 130-175"]
        let result = try await engine.understand(TextUnderstandingInput(
            text: lines.joined(separator: "\n"), lines: lines,
            source: .ocr(documentTypeHint: "lab_report"), allowsGenerativeProcessing: false))
        #expect(result.suggestedTarget == "lab_report")
        #expect(result.fields.contains { $0.key == "lab_item" && $0.value.contains("血红蛋白") })
    }

}
