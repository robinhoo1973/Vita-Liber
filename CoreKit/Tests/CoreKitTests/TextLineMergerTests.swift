import Foundation
import Testing
@testable import Domain

// binds: FR6.1 换行拆词归并（业主 2026-09-19 第 3 项）
/// fail-safe 纪律（宁可漏合、不可错合）：归并只拼接不删字（BR-002）；
/// 错合会把「药名行 + 用法行」粘成一行污染行身份。合并条件：两行非空 ∧
/// 边界字符均字母/CJK ∧ 上行无 ASCII 数字 ∧ 下行不以剂量/用法引导词开头
/// ∧ 下行无冒号。拼接沿用 TranscriptJoiner CJK 策略。
@Suite("FR6.1 换行拆词归并")
struct TextLineMergerTests {

    @Test func wrappedChineseWordMerges() {
        #expect(TextLineMerger.mergedText(["阿莫西林克拉维酸钾分", "散片"]) == ["阿莫西林克拉维酸钾分散片"])
    }

    @Test func wrappedLatinWordsJoinWithSpace() {
        #expect(TextLineMerger.mergedText(["Amoxicillin", "Capsule"]) == ["Amoxicillin Capsule"])
    }

    @Test func labelValuePairNeverMerges() {
        // 「血压」+「120/80」：下行以数字开头 → 不合并（标签-值对是行本体）
        #expect(TextLineMerger.mergedText(["血压", "120/80"]) == ["血压", "120/80"])
        // 上行含数字（剂量/规格行）→ 不合并（处方行身份第一）
        #expect(TextLineMerger.mergedText(["阿莫西林胶囊 0.25g×24粒", "口服 每日三次"])
                == ["阿莫西林胶囊 0.25g×24粒", "口服 每日三次"])
    }

    @Test func dosageDirectionLineNeverAbsorbed() {
        // 下行以「口服」开头（剂量/用法引导词单一词表）→ 不合并
        #expect(TextLineMerger.mergedText(["布洛芬缓释胶囊", "口服 每次一粒"]) == ["布洛芬缓释胶囊", "口服 每次一粒"])
    }

    @Test func labelLineWithColonNeverMerges() {
        #expect(TextLineMerger.mergedText(["用法", "用量：口服"]) == ["用法", "用量：口服"])
    }

    @Test func narrativeContinuationMerges() {
        #expect(TextLineMerger.mergedText(["患者主诉头痛三天伴", "恶心呕吐"]) == ["患者主诉头痛三天伴恶心呕吐"])
    }

    @Test func numericBoundaryBlocksMerge() {
        // 末字符/首字符是数字或标点 → 不合并
        #expect(TextLineMerger.mergedText(["服药10", "年余"]) == ["服药10", "年余"])
        #expect(TextLineMerger.mergedText(["检查结果：", "正常"]) == ["检查结果：", "正常"])
    }

    @Test func sourceIndicesTrackAbsorption() {
        let merged = TextLineMerger.merge(["阿莫西林克拉维酸钾分", "散片", "每日三次"])
        #expect(merged.map(\.text) == ["阿莫西林克拉维酸钾分散片", "每日三次"])
        #expect(merged[0].sourceIndices == [0, 1])
        #expect(merged[1].sourceIndices == [2])
    }

    /// 短碎片不与下行粘连（fail-safe 宁可漏合）：上行 <8 字符不触发合并
    @Test func shortFragmentsStayUnmerged() {
        #expect(TextLineMerger.mergedText(["a分", "b散"]) == ["a分", "b散"])
    }

    @Test func emptyLinesArePreservedAsBarriers() {
        #expect(TextLineMerger.mergedText(["阿莫西林克拉维酸钾分", "", "散片"])
                == ["阿莫西林克拉维酸钾分", "", "散片"])
    }

    @Test func mergeIsIdempotentStable() {
        let lines = ["阿莫西林克拉维酸钾分", "散片", "每日三次"]
        let once = TextLineMerger.mergedText(lines)
        #expect(TextLineMerger.mergedText(once) == once)
    }
}
