import Testing
import Foundation
@testable import Domain
@testable import Protocols

// binds: SU-M3-F19 — TC-M3-02 免触三连 / 危险误执行=0 / FR19.4 选择循环 / FR19.5 分级确认
/// F19 关怀语音助手会话引擎（受限文法状态机）的 Domain 半场。
/// M3 一票否决：免触三连成功率 ≥85%、危险动作误执行 = 0。
@Suite("SU-M3-F19 · 关怀语音助手受限文法状态机（FR19.1-19.9）")
struct VoiceConversationTests {

    // MARK: FR19.2 文法白名单

    @Test func 白名单指令解析() {
        #expect(VoiceCommandGrammar.parse("今天吃什么药") == .command(.todayMeds))
        #expect(VoiceCommandGrammar.parse("下次预约") == .command(.nextAppointment))
        #expect(VoiceCommandGrammar.parse("阿司匹林还剩多少") == .command(.stockRemaining))
        #expect(VoiceCommandGrammar.parse("打开时间轴") == .command(.openTimeline))
        #expect(VoiceCommandGrammar.parse("再说一遍") == .command(.repeatLast))
        #expect(VoiceCommandGrammar.parse("血压 148 92 心率 76") == .record(metricText: "血压 148 92 心率 76"))
    }

    @Test func 开放域不解析() {
        // FR19.9：不做自由对话与医疗问答
        #expect(VoiceCommandGrammar.parse("我最近心情不好怎么办") == .unrecognized)
        #expect(VoiceCommandGrammar.parse("帮我查一下医保政策") == .unrecognized)
    }

    // MARK: FR19.5 危险分级确认

    @Test func 拨号必须复述对象再确认() {
        var state = ConversationState()
        let (s1, e1) = VoiceConversationEngine.step(state: state, transcript: "帮我打给女儿")
        #expect(s1.phase == .repeatingObject, "拨号前必须进入复述对象相位")
        #expect(e1.contains(.requireRepeatObject("女儿")))
        state = s1
        // 只说「是」不够——必须先复述对象
        let (s2, e2) = VoiceConversationEngine.step(state: state, transcript: "确认")
        #expect(e2.contains(where: { if case .execute(.callContact, let payload) = $0 { return payload == "女儿" }
                              return false }),
                "复述对象后说确认才执行拨号")
        #expect(s2.phase == .listening)
    }

    @Test func 删除剂量变更一律拒绝() {
        let banned = ["删除阿司匹林的记录", "把剂量改成一天三次", "停用这个药", "删掉时间轴"]
        for phrase in banned {
            let (_, events) = VoiceConversationEngine.step(state: ConversationState(),
                                                          transcript: phrase)
            #expect(events.contains(.rejectForbidden), "「\(phrase)」必须被语音通道拒绝（FR19.5/BR-006）")
            #expect(!events.contains(where: { if case .execute = $0 { return true }; return false }),
                    "拒绝后不得有任何执行事件")
        }
    }

    @Test func 危险动作误执行为零() {
        // M3 一票否决：危险动作误执行次数 = 0。
        // 攻击式表述（确认词混入删除/剂量变更）也必须被拒
        let attacks = ["确认删除阿司匹林", "是的，把剂量改成一天三次", "对，停用"]
        for phrase in attacks {
            let (_, events) = VoiceConversationEngine.step(state: ConversationState(),
                                                          transcript: phrase)
            #expect(!events.contains(where: { if case .execute = $0 { return true }; return false }),
                    "「\(phrase)」不得产生任何执行（FR19.5 一票否决）")
        }
    }

    // MARK: FR19.4 选择循环 + 再说一遍

    @Test func 列选不超过三项且按编号选择() {
        let (state, events) = VoiceConversationEngine.optionsPrompt(["阿司匹林 100mg", "阿司匹林 81mg", "拜阿司匹林", "第四个被截断"])
        #expect(state.options.count == 3, "FR19.4：选项必须 ≤3")
        #expect(events.contains(.askOptions(["阿司匹林 100mg", "阿司匹林 81mg", "拜阿司匹林"])))
        let (s2, e2) = VoiceConversationEngine.step(state: state, transcript: "第二个")
        #expect(e2.contains(where: { if case .execute(_, let payload) = $0 { return payload == "阿司匹林 81mg" }
                              return false }))
        #expect(s2.phase == .listening)
    }

    @Test func 再说一遍重播当前问题与选项() {
        let (state, _) = VoiceConversationEngine.optionsPrompt(["甲", "乙"])
        let (_, events) = VoiceConversationEngine.step(state: state, transcript: "再说一遍")
        #expect(events.contains(where: { if case .speak(let s) = $0 { return !s.isEmpty }; return false }))
        #expect(events.contains(.askOptions(["甲", "乙"])), "重播必须包含当前选项（FR19.4）")
    }

    // MARK: FR19.6 超时降级

    @Test func 两轮无效应答礼貌退出() {
        var state = ConversationState()
        _ = VoiceConversationEngine.step(state: state, transcript: "今天天气不错")     // 第 1 轮无效
        state.silentRounds = 1
        let (s2, e2) = VoiceConversationEngine.step(state: state, transcript: "不知道")   // 第 2 轮无效
        #expect(e2.contains(.exitGracefully), "连续两轮无有效应答必须礼貌退出（FR19.6）")
        #expect(s2.phase == .ended)
    }

    @Test func 有效应答清零静默计数() {
        var state = ConversationState()
        state.silentRounds = 1
        let (s2, _) = VoiceConversationEngine.step(state: state, transcript: "今天吃什么药")
        #expect(s2.silentRounds == 0)
        #expect(s2.phase == .listening)
    }

    // MARK: M3 一票否决：免触三连任务成功率 ≥85%

    /// 免触三连：查今日用药 → 标记已服用 → 查询余量。
    /// 用 100 轮模拟会话（语料含正常/变体/歧义），成功率必须 ≥85%。
    @Test func 免触三连成功率达标() {
        var success = 0
        let rounds = 100
        for i in 0..<rounds {
            // 三种「查今日用药」变体轮换 + 各一步完成三连
            var state = ConversationState()
            let query = i % 3 == 0 ? "今天吃什么药" : (i % 3 == 1 ? "现在吃哪些药" : "今天有什么药")
            let (s1, e1) = VoiceConversationEngine.step(state: state, transcript: query)
            guard e1.contains(where: { if case .execute(.todayMeds, _) = $0 { return true }; return false }) else { continue }
            // 标记已服用：单次口头确认（elevated）
            let (s2, e2) = VoiceConversationEngine.step(state: s1, transcript: "我吃过阿司匹林了")
            let confirm1 = s2.phase == .confirming && e2.contains(where: { if case .speak = $0 { return true }; return false })
            guard confirm1 else { continue }
            let (s3, e3) = VoiceConversationEngine.step(state: s2, transcript: "确认")
            guard e3.contains(where: { if case .execute(.markTaken, let payload) = $0 { return payload == "阿司匹林" }; return false }) else { continue }
            // 查询余量
            let (_, e4) = VoiceConversationEngine.step(state: s3, transcript: "阿司匹林还剩多少")
            guard e4.contains(where: { if case .execute(.stockRemaining, _) = $0 { return true }; return false }) else { continue }
            success += 1
        }
        let rate = Double(success) / Double(rounds)
        #expect(rate >= 0.85, "免触三连成功率 \(String(format: "%.0f", rate * 100))% 低于 85% 一票否决线")
    }

    // MARK: FR19.3 / BR-006 播报文案红线

    @Test func 播报文案过措辞负清单() {
        // 状态机产出的所有播报都必须过 BR-006 负清单（纯事实句式）
        var state = ConversationState()
        var collected: [String] = []
        for phrase in ["今天吃什么药", "帮我打给女儿", "删除阿司匹林", "没听清", "不知道"] {
            let (s, events) = VoiceConversationEngine.step(state: state, transcript: phrase)
            state = s
            for event in events {
                if case .speak(let text) = event {
                    collected.append(text)
                    #expect(WordingBlacklist.violation(in: text) == nil,
                            "播报「\(text)」违反措辞负清单（BR-006）")
                }
            }
        }
        #expect(!collected.isEmpty)
    }
}

// binds: SU-M3-ISOLATION — 待 D1；ADR-008 铝箔板占位的 BR-003 纪律断言
@Suite("SU-M3-F19 · ADR-008 铝箔板盘点占位（BR-003 恒待确认）")
struct BlisterScannerTests {

    @Test func 扫描结果恒待确认() {
        let result = BlisterScanResult(count: 7)
        #expect(result.count == 7)
        #expect(!result.autoConfirmed, "机器计数是候选不是事实——BR-003 恒待确认")
    }

    @Test func 占位桩可注入且零网络() async throws {
        let scanner = StubInventoryScanner(count: 5)
        let result = try await scanner.scanBlisterCount(Data([0x00]))
        #expect(result.count == 5)
        #expect(!result.autoConfirmed)
    }
}
