import Foundation
import Testing
@testable import Domain

/// round5 Q4（业主 2026-09-20 第 4 项「加强日期文本识别」）：此前日期正则四份近似副本、全部要求 4 位年在前，
/// 不识全角数字 / OCR 混淆字 / 紧凑 8 位 / 两位年。收敛为 `ExtractionPatterns.dateMatch` **单文法**，
/// `parseDate` / `dateToken` / 规则轨 / fallback 边界全部委托——控件、校验、识别三者同源。
/// 记号恒为原文精确子串（grounding 纪律不变）。
@Suite("SU-OCRA-LAYOUT · 日期单文法")
struct DateGrammarTests {
    private let gregorian = Calendar(identifier: .gregorian)
    private func ymd(_ date: Date?) -> String? {
        guard let date else { return nil }
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    @Test(arguments: [
        ("2026-09-20", "2026-09-20"),
        ("2026/9/20", "2026-09-20"),
        ("2026年9月20日", "2026-09-20"),
        ("2026.09.20", "2026-09-20"),
        ("就诊日期：2026-09-20 14:30", "2026-09-20"),       // 时间后缀忽略、标签前缀忽略
        ("２０２６年９月２０日", "2026-09-20"),               // 全角数字（NFKC 折叠）
        ("2O26-O9-2O", "2026-09-20"),                       // OCR 混淆：字母 O → 0
        ("2026-09-2l", "2026-09-21"),                       // OCR 混淆：字母 l → 1
        ("20260920", "2026-09-20"),                         // 紧凑 8 位
        ("报告日期 20260920 12:01", "2026-09-20"),
        ("26-09-20", "2026-09-20"),                         // 两位年（三段齐全含分隔）
        ("26/9/20", "2026-09-20"),
    ])
    func recognizesCommonOCRDateForms(_ input: String, _ expected: String) {
        let match = ExtractionPatterns.dateMatch(in: input, referenceYear: 2026)
        #expect(match.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } == expected, "input=\(input)")
        #expect(ymd(EntityCardProjection.parseDate(input, calendar: gregorian)) == expected, "parseDate input=\(input)")
    }

    @Test(arguments: [
        "20261320",          // 紧凑：月 13 非法
        "20260932",          // 紧凑：日 32 非法
        "12345678",          // 8 位非日期数字
        "2026-13-01",        // 月越界
        "2026-00-10",
        "总额 2026.5 元",    // 只有一段
        "1-2-3",             // 两位年要求恰两位
        "电话 010-2026-0920",// 数字前后紧邻数字/连字符——不成三段日期（前置 010- 使 2026 段前有 -，仍应拒）
        "",
    ])
    func rejectsNonDates(_ input: String) {
        #expect(ExtractionPatterns.dateMatch(in: input, referenceYear: 2026) == nil, "input=\(input)")
        #expect(EntityCardProjection.parseDate(input, calendar: gregorian) == nil, "parseDate input=\(input)")
    }

    @Test func twoDigitYearUsesReferenceYearCentury() {
        // 参考年 2026：yy ≤ 27 → 20yy；yy ≥ 28 → 19yy（不把「99-01-01」当 2099）
        #expect(ExtractionPatterns.dateMatch(in: "27-01-01", referenceYear: 2026)?.year == 2027)
        #expect(ExtractionPatterns.dateMatch(in: "28-01-01", referenceYear: 2026)?.year == 1928)
        #expect(ExtractionPatterns.dateMatch(in: "99-01-01", referenceYear: 2026)?.year == 1999)
    }

    @Test func tokenIsVerbatimSubstringOfOriginalText() {
        // 记号取自原文（含全角/混淆字原样），grounding 可逐字定位
        let line = "报告日期：２０２６年９月２０日 出具人：张三"
        let token = ExtractionPatterns.dateToken(in: line)
        #expect(token == "２０２６年９月２０日")
        #expect(line.range(of: token ?? "") != nil)
        let ocr = "开具 2O26-O9-2O 有效"
        #expect(ExtractionPatterns.dateToken(in: ocr) == "2O26-O9-2O")
    }

    @Test func compactFormRequiresDigitBoundaries() {
        // 前后紧邻数字 → 不是独立日期（票据号/身份证号片段）
        #expect(ExtractionPatterns.dateMatch(in: "NO.202609201234", referenceYear: 2026) == nil)
        #expect(ExtractionPatterns.dateMatch(in: "编号 20260920", referenceYear: 2026) != nil)
    }

    @Test func ruleExtractorAndFallbackShareTheGrammar() {
        // 规则轨 dateToken 与 fallback 边界判定委托同一文法（此前各自一份 4 位年正则）
        #expect(RuleExtractor.dateToken(in: "２０２６年９月２０日 复诊") == "２０２６年９月２０日")
        #expect(DocumentTypeClassifierFallback.startsWithDate("2O26-09-20 血常规") == true)
        #expect(DocumentTypeClassifierFallback.startsWithDate("血常规 2026-09-20") == false)
    }
}
