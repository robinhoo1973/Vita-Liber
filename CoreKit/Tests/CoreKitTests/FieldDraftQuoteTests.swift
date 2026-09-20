import Foundation
import Testing
@testable import Domain

/// 多行原文引用归并（业主 2026-09-20 第 1 项）：`FieldDraft.quoteLines` 的
/// 连接语义单一事实源——空行剔除、按行序 `\n` 连接（与抽取管线
/// `DocumentTypeClassifierFallback.mergeNarrativeLines` 分隔符同源）、
/// 走 `revise` 修订留痕（D 级待确认、不借 fillByUser 升 C；BR-003）。
@Suite("SU-FR6.9 · 多行原文引用归并")
struct FieldDraftQuoteTests {

    @Test("quoteLines：按行序连接、空行剔除、修订留痕（grade 不升 C）")
    /// 原名：多行引用连接语义
    func quoteLinesJoinsInOrderAndStaysUnconfirmed() {
        var field = FieldDraft(key: "present_illness", value: "旧值", confidence: 0.8, grade: .ocrUnconfirmed)
        field.quoteLines(["  头痛三天", "", "伴发热  ", "  ", "咳嗽"])
        #expect(field.value == "头痛三天\n伴发热\n咳嗽", "空行剔除、trim 后按行序以 \\n 连接")
        #expect(field.grade == .ocrUnconfirmed, "引用是机器原文的搬运——D 级待确认，不得升 C（BR-003）")
        #expect(field.isConfirmed == false)
        #expect(field.revisionHistory.count == 1, "revise 留痕恰一条")
    }

    @Test("quoteLines：全空输入不改值不记痕")
    /// 原名：全空引用无副作用
    func quoteLinesAllEmptyIsNoOp() {
        var field = FieldDraft(key: "note", value: "原文", confidence: 0.5, grade: .ocrUnconfirmed)
        field.quoteLines(["  ", "", " \n"])
        #expect(field.value == "原文")
        #expect(field.revisionHistory.isEmpty)
    }

    @Test("quoteLines：行内换行原样保留（行结构不重排）")
    /// 原名：行内换行保留
    func quoteLinesPreservesInlineLineBreaks() {
        var field = FieldDraft(key: "visit_summary", value: "", confidence: 0.9, grade: .ocrUnconfirmed)
        field.quoteLines(["第一行\n第二行", "第三行"])
        #expect(field.value == "第一行\n第二行\n第三行")
    }
}
