import Foundation
import Testing
@testable import Domain

// binds: SU-M15-VOICE
/// FR17.1（V3.61 停顿丢字修正）：一次按住说话 = 一个会话，会话内多轮识别请求——
/// 静音端点/60s 上限出 isFinal 只是「提交一段」，不是结束；显示文本 = 已提交段 + 当前部分。
/// FR17.15：主语言 = 用户选择顺序首位（不再字母序）；混说词表注入 contextualStrings。
@Suite("SU-M15-VOICE · 连续转写会话累加与主语言/混说词表（FR17.1/FR17.15 V3.61）")
struct TranscriptSessionTests {
    @Test func 提交段与部分结果合并显示() {
        var acc = TranscriptSessionAccumulator()
        acc.updatePartial("我今天")
        acc.updatePartial("我今天头疼")
        #expect(acc.displayText == "我今天头疼")
        acc.commit("我今天头疼")                 // 静音端点 isFinal
        #expect(acc.partial.isEmpty)
        acc.updatePartial("吃了")
        #expect(acc.displayText == "我今天头疼 吃了", "停顿后的话接在已提交段之后，不覆盖")
        #expect(acc.finish() == ["我今天头疼", "吃了"])
    }

    @Test func 空白提交忽略且finish幂等() {
        var acc = TranscriptSessionAccumulator()
        acc.commit("   ")
        acc.commit("")
        #expect(acc.committed.isEmpty)
        acc.commit(" 血压 130 ")
        #expect(acc.committed == ["血压 130"])
        #expect(acc.finish() == ["血压 130"])
        #expect(acc.finish() == ["血压 130"], "重复 finish 不重复提交")
    }

    @Test func 分段换段判定按能力上限留安全余量() {
        let baseline = TranscriptionCapability.baseline()
        #expect(TranscriptSessionAccumulator.shouldRotate(elapsedSeconds: 55, capability: baseline))
        #expect(!TranscriptSessionAccumulator.shouldRotate(elapsedSeconds: 54.9, capability: baseline))
        #expect(!TranscriptSessionAccumulator.shouldRotate(elapsedSeconds: 1e9, capability: .longForm()),
                "升级轨长音频免分段")
    }

    @Test func 转写结果携带各段且向后兼容() {
        let legacy = TranscriptionResult(text: "a", confidence: 0.9, resolvedLocale: "zh-Hans-CN", segmented: false)
        #expect(legacy.segments.isEmpty)
        let multi = TranscriptionResult(text: "a b", confidence: 0.9, resolvedLocale: "zh-Hans-CN",
                                        segmented: true, segments: ["a", "b"])
        #expect(multi.segments == ["a", "b"])
    }

    // MARK: - FR17.15 主语言与混说

    @Test func 语音语言保序去重且主语言为首位() {
        #expect(SettingsRules.voiceLocales("en-US,zh-Hans-CN,en-US") == ["en-US", "zh-Hans-CN"])
        #expect(SettingsRules.preferredVoiceLocale("yue-Hant-HK,zh-Hans-CN") == "yue-Hant-HK")
        #expect(SettingsRules.preferredVoiceLocale(nil) == "zh-Hans-CN", "默认主语言普通话")
        #expect(SettingsRules.voiceLocales(" ") == ["zh-Hans-CN"], "空存储回落默认")
    }

    @Test func 混说词表有上限_药名优先_含英文医学词与单位() {
        let drugs = (0..<150).map { "药名\($0)" }
        let terms = MixedSpeechVocabulary.terms(primaryLocale: "zh-Hans-CN", otherLocales: ["en-US"],
                                                recentDrugNames: drugs)
        #expect(terms.count <= MixedSpeechVocabulary.limit)
        #expect(Set(terms).count == terms.count, "无重复")
        #expect(terms.prefix(10).allSatisfy { $0.hasPrefix("药名") }, "已确认药名优先注入")
        let base = MixedSpeechVocabulary.terms(primaryLocale: "zh-Hans-CN", otherLocales: ["en-US"], recentDrugNames: [])
        #expect(base.contains("mmHg"))
        #expect(base.contains("CT"))
        #expect(base.contains(where: { $0 == "mmol/L" }))
        let mono = MixedSpeechVocabulary.terms(primaryLocale: "zh-Hans-CN", otherLocales: [], recentDrugNames: [])
        #expect(mono.count < base.count, "未选英语时不注入英文混说词（仍含单位）")
    }
}
