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

    // MARK: round5 Q1（业主 2026-09-20 第 1 项「识别原文为空」）：引用即出处

    @Test("quoteLines(sourceLineIndices:)：记录出处——rawText = 所选原行、sourceLineIndex = 首行；字段随之获得 [原文] 锚")
    func quoteLinesRecordsProvenance() {
        var field = FieldDraft(key: "route", value: "", confidence: 1)          // 新增字段：无 rawText/无锚
        #expect(field.rawText == nil && field.sourceLineIndex == nil)
        field.quoteLines(["口服 每日三次", "饭后"], sourceLineIndices: [4, 5])
        #expect(field.value == "口服 每日三次\n饭后")
        #expect(field.rawText == "口服 每日三次\n饭后", "出处 = 用户所选原行（用户点选即出处断言，非机器猜测）")
        #expect(field.sourceLineIndex == 4, "锚定首行，[原文] 入口据此出现")
        #expect(field.grade == .ocrUnconfirmed, "引用不升 C（V3.99 ①）")
    }

    @Test("quoteLines(sourceLineIndices:)：行数与行号数不等 → 只写值不写出处（不猜锚点）")
    func quoteLinesMismatchedIndicesDoNotFakeProvenance() {
        var field = FieldDraft(key: "route", value: "", confidence: 1)
        field.quoteLines(["A", "B"], sourceLineIndices: [1])
        #expect(field.value == "A\nB")
        #expect(field.rawText == nil && field.sourceLineIndex == nil)
    }

    @Test("CardConfirmationRules.quote：走 revise 语义（不经 fillByUser 升 C），并写出处")
    func cardLevelQuoteStaysUnconfirmedAndRecordsProvenance() {
        var card = MatchedCard(kind: "prescription", pageIndex: 0, shared: [.init(key: "prescribed_at", value: "2026-09-20")],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "X"), .init(key: "route", value: "", confidence: 1)])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let rowId = card.rows[0].id
        CardConfirmationRules.quote(&card, key: "route", rowId: rowId, lines: ["口服"], sourceLineIndices: [7])
        let field = card.rows[0].fields[1]
        #expect(field.value == "口服" && field.rawText == "口服" && field.sourceLineIndex == 7)
        #expect(field.isConfirmed == false, "此前 quoteLine 经 CardConfirmationRules.revise → fillByUser，原值为空的新增字段被顺手升 C——违反 V3.99 ①")
        // 对照：手填走 revise → fillByUser——原值为空（机器从未给值）即升 C（2026-09-17 裁定不变）
        CardConfirmationRules.revise(&card, at: 1, rowId: rowId, to: "外用")
        #expect(card.rows[0].fields[1].isConfirmed == true, "手填是用户提供的值，与引用（机器原文搬运）语义不同")
    }
}
