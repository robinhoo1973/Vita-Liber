import Testing
import Foundation
@testable import Domain
@testable import Protocols

// binds: SU-M15-TREND — TC-M15 F7 退出准则（三医院同图 / 空心实心 / 软删恢复 / 换算）
/// dev-pm §3.3 F7 验收的 Domain 半场。落库半场在 iOS 的 M15AcceptanceTests。
@Suite("SU-M15-TREND · F7 双来源趋势与多参考带（FR7.2 一票否决）")
struct SUM15TrendTests {

    private func hospitalPoint(_ label: String, value: Double, lo: Double, hi: Double,
                               dayOffset: Int) -> TrendPoint {
        TrendPoint(id: UUID(),
                   measuredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(dayOffset) * 86400),
                   value: value, unit: "mmol/L", origin: .hospital,
                   sourceRef: "doc-\(label)", refLow: lo, refHigh: hi, refSourceLabel: label)
    }

    /// **一票否决**：三家医院血糖同图，参考范围各自成带、绝不合并（FR7.2）。
    @Test func 三医院参考范围各自成带且不合并() {
        let points = [
            hospitalPoint("市一医院", value: 6.1, lo: 3.9, hi: 6.1, dayOffset: 0),
            hospitalPoint("协和医院", value: 5.8, lo: 4.1, hi: 5.9, dayOffset: 1),
            hospitalPoint("社区卫生中心", value: 6.4, lo: 3.6, hi: 6.5, dayOffset: 2),
        ]
        let bands = TrendRules.resolveBands(points: points)
        #expect(bands.count == 3, "三家医院必须产出三条独立参考带，合并即违反 FR7.2")
        #expect(Set(bands.map(\.sourceLabel)) == ["市一医院", "协和医院", "社区卫生中心"])
        #expect(bands.allSatisfy { $0.grade == .A }, "报告自带范围一律 A 级")
        // 反向断言：不得出现任何跨来源的合并区间（取并集会得到 3.6–6.5 的单一条带）
        #expect(!bands.contains { $0.lower == 3.6 && $0.upper == 6.5 && $0.sourceLabel == "合并" })
    }

    /// 区间数值恰好相同的两家医院，仍按来源分开——来源是分组键，不是装饰
    @Test func 同区间不同医院不得去重合并() {
        let points = [
            hospitalPoint("A 医院", value: 5.5, lo: 3.9, hi: 6.1, dayOffset: 0),
            hospitalPoint("B 医院", value: 5.6, lo: 3.9, hi: 6.1, dayOffset: 1),
        ]
        let bands = TrendRules.resolveBands(points: points)
        #expect(bands.count == 2, "区间相同但来源不同，合并会让用户误以为存在统一正常值")
    }

    /// 同一医院多次报告、区间一致 → 只画一条（去重按「来源+区间」三元组）
    @Test func 同医院同区间多次报告只成一带() {
        let points = (0..<5).map { hospitalPoint("市一医院", value: 6.0, lo: 3.9, hi: 6.1, dayOffset: $0) }
        #expect(TrendRules.resolveBands(points: points).count == 1)
    }

    /// FR16.4 优先级铁律：存在 A 级带时不得混入 B 级信源库缺省带
    @Test func A级存在时不混入B级() {
        let fallback = ReferenceBand(sourceLabel: "信源库缺省", lower: 3.9, upper: 6.1, grade: .B)
        let withA = TrendRules.resolveBands(
            points: [hospitalPoint("市一医院", value: 6.0, lo: 3.9, hi: 6.1, dayOffset: 0)],
            libraryFallback: fallback)
        #expect(withA.count == 1 && withA[0].grade == .A)
        // 无 A 级时才回落 B 级
        let selfOnly = [TrendPoint(id: UUID(), measuredAt: Date(), value: 5.5, unit: "mmol/L", origin: .manual)]
        let withB = TrendRules.resolveBands(points: selfOnly, libraryFallback: fallback)
        #expect(withB.count == 1 && withB[0].grade == .B)
        // 两者皆无 = 范围不可用（独立渲染状态，不显示通用范围）
        #expect(TrendRules.resolveBands(points: selfOnly).isEmpty)
    }

    /// 空心=自测/设备，实心=医院（ui-ux 4.7 一眼可辨）
    @Test func 空心实心按来源区分() {
        #expect(TrendPoint(id: UUID(), measuredAt: Date(), value: 1, origin: .hospital).isHollow == false)
        #expect(TrendPoint(id: UUID(), measuredAt: Date(), value: 1, origin: .manual).isHollow)
        #expect(TrendPoint(id: UUID(), measuredAt: Date(), value: 1, origin: .device).isHollow)
    }

    /// FR7.4 排除点软删：聚合默认剔除，原值保留可恢复
    @Test func 排除点软删且原值保留() {
        let kept = TrendPoint(id: UUID(), measuredAt: Date(), value: 6.0, origin: .manual)
        var dropped = TrendPoint(id: UUID(), measuredAt: Date(), value: 99.9, origin: .manual)
        dropped.excluded = true
        let visible = TrendRules.visible([kept, dropped])
        #expect(visible.count == 1 && visible[0].value == 6.0)
        #expect(dropped.value == 99.9, "软删必须保留原值以便恢复")
    }

    /// 排除点携带的参考范围不得继续参与成带（排除点通常是 OCR 错值）
    @Test func 排除点的参考范围不入带() {
        var bad = hospitalPoint("误识别医院", value: 999, lo: 0, hi: 999, dayOffset: 0)
        bad.excluded = true
        let good = hospitalPoint("市一医院", value: 6.0, lo: 3.9, hi: 6.1, dayOffset: 1)
        let bands = TrendRules.resolveBands(points: TrendRules.visible([bad, good]))
        #expect(bands.count == 1 && bands[0].sourceLabel == "市一医院")
    }

    /// FR7.8 换算留痕：**参考带必须随点同步换算**，否则量纲不一致会读出错误结论
    @Test func 换算同时作用于点与参考带() {
        let series = TrendSeries(
            metricType: .glucose,
            points: [hospitalPoint("市一医院", value: 6.0, lo: 3.9, hi: 6.1, dayOffset: 0)],
            referenceBands: [ReferenceBand(sourceLabel: "市一医院", lower: 3.9, upper: 6.1, grade: .A)])
        let conv = UnitConversion(fromUnit: "mmol/L", toUnit: "mg/dL", factor: 18.0, note: "mmol/L")
        let out = TrendRules.converted(series, using: conv)
        #expect(abs(out.points[0].value - 108.0) < 0.001)
        #expect(abs(out.referenceBands[0].lower - 70.2) < 0.001, "参考带未换算会造成误判超标")
        #expect(abs(out.referenceBands[0].upper - 109.8) < 0.001)
        #expect(out.points[0].unit == "mg/dL")
        #expect(abs((out.points[0].refLow ?? 0) - 70.2) < 0.001)
    }
}

// binds: SU-M15-VOICE — TC-M15-02/03/04/06 + FR17.13 回读三态 + BR-003/006 拒绝卡
@Suite("SU-M15-VOICE · 语音包退出准则（音频零落盘/模板复用/双轨/拒绝卡）")
struct SUM15VoiceTests {

    // MARK: TC-M15-02 音频零落盘（类型级断言）

    /// 转写端口的入参与出参**不得出现任何文件/字节容器**——音频无处交出，
    /// 「零落盘」因此在编译期成立，而不只是运行期没触发写盘。
    @Test func 转写协议不暴露任何文件或字节通道() {
        // 反射三个值对象的字段类型：出现 URL/Data 即视为可落盘通道
        let mirrors: [Mirror] = [
            Mirror(reflecting: TranscriptionRequest(localeIdentifier: "zh-Hans-CN")),
            Mirror(reflecting: TranscriptionResult(text: "", confidence: 0,
                                                   resolvedLocale: "zh-Hans-CN", segmented: false)),
            Mirror(reflecting: TranscriptionCapability.baseline()),
        ]
        for mirror in mirrors {
            for child in mirror.children {
                let type = String(describing: type(of: child.value))
                #expect(!type.contains("URL"), "转写值对象出现 URL 字段 = 音频落盘通道")
                #expect(!type.contains("Data"), "转写值对象出现 Data 字段 = 音频字节通道")
            }
        }
    }

    // MARK: TC-M15-03 模板复用（Domain 半场；静态半场在 L0 [9/9]）

    @Test func 语音草稿一律经统一模板且为待确认态() {
        let set = VoiceInputTemplate.confirmationSet(drafts: [
            FieldDraft(key: "glucose", value: "6.2", unit: "mmol/L", confidence: 0.93),
            FieldDraft(key: "note", value: "餐后两小时", confidence: 0.81),
        ])
        #expect(set.fields.count == 2)
        #expect(set.fields.allSatisfy { $0.grade == .ocrUnconfirmed }, "BR-003：语音草稿一律待确认")
        #expect(set.isUsableInTimeline == false, "未确认不得入时间轴正式区")
    }

    /// 回读脚本只含**已确认**字段——未确认内容不得被当作事实播报（BR-003）
    @Test func 回读脚本只含已确认字段() {
        var set = VoiceInputTemplate.confirmationSet(drafts: [
            FieldDraft(key: "name", value: "王女士", confidence: 0.95),
            FieldDraft(key: "birth", value: "1962年3月", confidence: 0.6),
        ])
        #expect(ReadbackPolicy.readbackScript(set) == nil, "全未确认时无可播报内容")
        _ = set.fields[0].confirm()
        let script = ReadbackPolicy.readbackScript(set)
        #expect(script?.contains("王女士") == true)
        #expect(script?.contains("1962年3月") == false, "未确认字段不得进入回读")
    }

    // MARK: FR17.13 回读三态 + 🔊 朗读出口

    @Test func 有耳机一律回读() {
        for pref in ReadbackPreference.allCases {
            for care in [true, false] {
                #expect(ReadbackPolicy.decide(route: .headphones, preference: pref, careMode: care)
                        == .readAloud(warnBystanders: false))
            }
        }
    }

    @Test func 无耳机三态决策正确() {
        #expect(ReadbackPolicy.decide(route: .speaker, preference: .never, careMode: false)
                == .screenConfirm(offerSpeakButton: true))
        #expect(ReadbackPolicy.decide(route: .speaker, preference: .ask, careMode: false)
                == .askFirst)
        // 「总是」仅关怀模式成立；非关怀模式保守回落询问
        #expect(ReadbackPolicy.decide(route: .speaker, preference: .alwaysInCareMode, careMode: true)
                == .readAloud(warnBystanders: true))
        #expect(ReadbackPolicy.decide(route: .speaker, preference: .alwaysInCareMode, careMode: false)
                == .askFirst)
    }

    /// 🔊 朗读出口是无障碍出口——任何偏好下都不得被关闭（FR17.13 / F18）
    @Test func 朗读出口不受偏好关闭() {
        if case .screenConfirm(let offer) = ReadbackPolicy.decide(
            route: .speaker, preference: .never, careMode: false) {
            #expect(offer, "偏好为『从不』时仍须提供 [🔊 朗读] 手动出口")
        } else {
            Issue.record("从不 + 无耳机应为屏幕核对态")
        }
    }

    @Test func 总是选项仅关怀模式可设() {
        #expect(ReadbackPolicy.isSelectable(.alwaysInCareMode, careMode: true))
        #expect(!ReadbackPolicy.isSelectable(.alwaysInCareMode, careMode: false))
        #expect(ReadbackPolicy.isSelectable(.never, careMode: false))
        #expect(ReadbackPolicy.isSelectable(.ask, careMode: false))
    }

    /// 录入过程中拔/插耳机 → 即时重判；未变化则不打断
    @Test func 耳机拔插即时切换策略() {
        #expect(ReadbackPolicy.rerouted(from: .speaker, to: .speaker,
                                        preference: .ask, careMode: false) == nil)
        #expect(ReadbackPolicy.rerouted(from: .speaker, to: .headphones,
                                        preference: .never, careMode: false)
                == .readAloud(warnBystanders: false))
        #expect(ReadbackPolicy.rerouted(from: .headphones, to: .speaker,
                                        preference: .never, careMode: false)
                == .screenConfirm(offerSpeakButton: true))
    }

    // MARK: BR-003/006 语音受限修改拒绝卡（负样本参数化）

    @Test(arguments: [
        "把阿司匹林改成每天两片", "剂量加到 100 毫克", "这个药减量吧",
        "阿司匹林停药", "以后不吃了", "二甲双胍改为每天三次", "把频次改一下",
    ])
    func 剂量频次停用一律拒绝(sample: String) {
        let r = VoiceModificationGuard.evaluate(sample, isExistingPlanContext: true)
        #expect(r != nil, "「\(sample)」必须被语音通道拒绝（BR-003/006）")
    }

    /// 拒绝卡文案过 BR-006 措辞负清单（不得出现建议/应该/遵医嘱等判断性措辞）
    @Test func 拒绝卡文案过负清单() {
        let banned = ["建议", "应该", "需遵医嘱", "推荐", "最好", "可能是"]
        for category in VoiceModificationGuard.Category.allCases {
            let r = VoiceModificationGuard.rejection(category: category, phrase: "测试")
            for word in banned {
                #expect(!r.title.contains(word) && !r.body.contains(word),
                        "拒绝卡出现负清单词「\(word)」：\(r.body)")
            }
            #expect(!r.actionLabel.isEmpty, "拒绝必须给出触屏替代路径，不能只说不行")
        }
    }

    /// 反向断言：非计划语境下不得误拦——否则用户连备忘都记不了
    @Test func 非计划语境不误拦() {
        #expect(VoiceModificationGuard.evaluate("记一条：医生说以后不吃了",
                                                isExistingPlanContext: false) == nil)
    }

    // MARK: TC-M15-04 双轨门控与分段策略（ADR-023 / §11 清偿项）

    @Test func 升级轨长音频免分段() {
        let plan = TranscriptionSegmentation.plan(durationSeconds: 300,
                                                  capability: .longForm())
        #expect(plan.count == 1 && plan[0].lengthSeconds == 300)
    }

    @Test func 基线轨长音频按窗切分且留安全余量() {
        let cap = TranscriptionCapability.baseline()
        let plan = TranscriptionSegmentation.plan(durationSeconds: 300, capability: cap)
        #expect(plan.count > 1, "基线轨 300s 录音必须分段，否则被系统 60s 截断丢字")
        #expect(plan.allSatisfy { $0.lengthSeconds <= cap.maxSegmentSeconds - 5 },
                "必须留 5s 余量，卡着 60s 切会与系统截断竞态")
        #expect(plan[0].startSeconds == 0)
        // 窗口重叠：下一窗起点早于上一窗终点，避免切点落在字中间丢字
        #expect(plan[1].startSeconds < plan[0].startSeconds + plan[0].lengthSeconds)
        // 覆盖完整时长
        let last = plan[plan.count - 1]
        #expect(last.startSeconds + last.lengthSeconds >= 300)
    }

    @Test func 短音频两轨均单窗() {
        #expect(TranscriptionSegmentation.plan(durationSeconds: 20, capability: .baseline()).count == 1)
        #expect(TranscriptionSegmentation.plan(durationSeconds: 20, capability: .longForm()).count == 1)
        #expect(TranscriptionSegmentation.plan(durationSeconds: 0, capability: .baseline()).isEmpty)
    }

    /// 两轨经同一协议后**行为一致**（同一语料同一产出），差异只在 segmented 标志
    @Test func 双轨同协议行为一致() async throws {
        let sample = "血糖六点二"
        let baseline = StubTranscriptionEngine(capability: .baseline(), scripted: [sample])
        let upgraded = StubTranscriptionEngine(capability: .longForm(), scripted: [sample])
        let req = TranscriptionRequest(localeIdentifier: "zh-Hans-CN", expectedDurationSeconds: 300)
        let a = try await baseline.transcribe(req, onPartial: nil)
        let b = try await upgraded.transcribe(req, onPartial: nil)
        #expect(a.text == b.text, "两轨对同一语料必须产出相同文本")
        #expect(a.segmented && !b.segmented, "差异只应体现在是否分段")
    }

    /// 方言无引擎时回落普通话并如实回报（FR17.15「尽力识别」，零静默）
    @Test func 方言不可用时回落普通话且留痕() async throws {
        let engine = StubTranscriptionEngine(
            capability: .baseline(locales: ["zh-Hans-CN"]), scripted: ["测试"])
        let result = try await engine.transcribe(
            TranscriptionRequest(localeIdentifier: "yue-Hans-CN"), onPartial: nil)
        #expect(result.resolvedLocale == TranscriptionSegmentation.fallbackLocale)
    }

    // MARK: TC-M15-06 输出语言指定与发声回退

    @Test func 发声回退链与轻提示标志() {
        let has = SpeechFallback.resolve(requested: "zh-Hans-CN",
                                         availableVoices: ["zh-Hans-CN", "en-US"])
        #expect(has.spokenLocale == "zh-Hans-CN" && !has.didFallback)
        let missing = SpeechFallback.resolve(requested: "yue-Hans-CN",
                                             availableVoices: ["zh-Hans-CN"])
        #expect(missing.spokenLocale == "zh-Hans-CN")
        #expect(missing.didFallback, "回退必须留痕，UI 据此显示当前发声语言轻提示")
    }

    @Test func TTS替身记录播报内容与语言() {
        let tts = RecordingSpeechSynthesizer(availableVoices: ["zh-Hans-CN"])
        tts.speak("已录入：王女士。对吗？", localeIdentifier: "yue-Hans-CN")
        #expect(tts.spoken.count == 1)
        #expect(tts.spoken[0].outcome.didFallback)
        #expect(tts.spoken[0].text.contains("王女士"))
    }

    // MARK: 文法子集单一事实源

    /// 生产文法必须来自 Domain 的 `VoiceGrammarDefaults`——规则表若只存在于测试里，
    /// 金样定标测的就是另一套语法，对生产无效。
    @Test func 生产文法规则表非空且可用() {
        #expect(!VoiceGrammarDefaults.metricRules.isEmpty)
        #expect(!VoiceGrammarDefaults.reminderRules.isEmpty)
        #expect(!VoiceGrammarDefaults.profileRules.isEmpty)
        let drafts = VoiceStructuringEngine.extractMetric(
            "血糖6.2", rules: VoiceGrammarDefaults.metricRules)
        #expect(drafts.contains { $0.key == "glucose" && $0.value == "6.2" })
    }

    /// FR10.2：模糊时间不落具体日期即不产出——绝不猜时间
    @Test func 提醒时间不明确即不产出() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(VoiceReminderRules.resolveDate(
            from: [FieldDraft(key: "time", value: "周末")], now: now) == nil)
        #expect(VoiceReminderRules.resolveDate(
            from: [FieldDraft(key: "time", value: "明天")], now: now) != nil)
        let withHour = VoiceReminderRules.resolveDate(
            from: [FieldDraft(key: "time", value: "明天"), FieldDraft(key: "hour", value: "8")],
            now: now, calendar: Calendar(identifier: .gregorian))
        #expect(withHour != nil)
    }
}

// binds: SU-M15-VOICE — TC-M15-01 语音金样定标放行线（FR17.4 一票否决）
/// **不变量断言**（而非恒红断言，理由见 VoiceCalibration 头注）：
///     语音结构化路径已启用 ⟹ 定标已通过
/// 真人语料未交付时，本套件强制 `voiceStructuringEnabled == false`，
/// 于是「未达标仍放行」在产品行为层面不可能发生。
@Suite("SU-M15-VOICE · TC-M15-01 金样定标放行线")
struct SUM15CalibrationTests {

    /// `.copy("Fixtures")` 保留目录结构，资源落在 bundle 的 Fixtures 子目录下，
    /// 故按路径取而不是 `Bundle.module.url(forResource:)`（后者只搜 bundle 根，取不到）。
    /// 与 GoldenMigrationTests 的取法保持一致。
    private func loadCorpus() throws -> VoiceCalibration.Corpus {
        let path = Bundle.module.bundlePath + "/Fixtures/voice-corpus.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw CalibrationFixtureError.missing
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(VoiceCalibration.Corpus.self, from: data)
    }

    enum CalibrationFixtureError: Error { case missing }

    /// 语料库必须存在且可解析——**文件缺席不得被当成「无需定标」**（ERR#27）
    @Test func 语料库存在且可解析() throws {
        let corpus = try loadCorpus()
        #expect(!corpus.samples.isEmpty, "空集不得判过")
        #expect(corpus.samples.allSatisfy { !$0.expected.isEmpty }, "每条语料必须带期望抽取结果")
    }

    /// 放行线不变量：未达标 ⟹ 语音结构化开关必须关闭
    @Test func 未达标则语音结构化必须关闭() throws {
        let corpus = try loadCorpus()
        let report = VoiceCalibration.evaluate(corpus: corpus) { sample in
            var out: [String: String] = [:]
            let drafts: [FieldDraft]
            switch sample.kind {
            case "metric":   drafts = VoiceStructuringEngine.extractMetric(sample.transcript, rules: VoiceGrammarDefaults.metricRules)
            case "reminder": drafts = VoiceStructuringEngine.extractReminder(sample.transcript, rules: VoiceGrammarDefaults.reminderRules)
            default:         drafts = VoiceStructuringEngine.extractProfile(sample.transcript, rules: VoiceGrammarDefaults.profileRules)
            }
            for d in drafts { out[d.key] = d.value }
            return out
        }
        FeatureFlags.applyCalibration(report)

        if report.passesReleaseLine {
            #expect(FeatureFlags.voiceStructuringEnabled)
        } else {
            #expect(!FeatureFlags.voiceStructuringEnabled,
                    "定标未过（\(report.blockingReasons.joined(separator: "；"))）时不得启用语音结构化路径")
            #expect(!report.blockingReasons.isEmpty, "未达标必须给出可读原因，便于台账与 Gate Review")
        }
    }

    /// 放行线常量必须与 FR17.4 一致——阈值被悄悄调低比不达标更危险
    @Test func 放行线阈值锁定为FR17_4规定值() {
        #expect(VoiceCalibration.requiredHumanSamples == 500)
        #expect(VoiceCalibration.requiredNumericAccuracy == 0.90)
        #expect(VoiceCalibration.requiredStructureRate == 0.85)
    }

    /// 反向自检：构造一份「满配且全对」的语料，放行线必须能真的转绿——
    /// 否则本门禁只会永远说不行，等同于坏掉的秤（ERR#32「检查存在但无效」同族）。
    @Test func 满配全对时放行线可通过() {
        let samples = (0..<VoiceCalibration.requiredHumanSamples).map {
            VoiceCalibration.Sample(id: "h-\($0)", transcript: "血糖6.2", kind: "metric",
                                    locale: "zh-Hans-CN", isHumanRecorded: true,
                                    expected: ["glucose": "6.2"])
        }
        let report = VoiceCalibration.evaluate(
            corpus: VoiceCalibration.Corpus(version: "test", samples: samples)) { _ in
                ["glucose": "6.2"]
            }
        #expect(report.humanSampleCount == 500)
        #expect(report.numericAccuracy == 1.0)
        #expect(report.structureRate == 1.0)
        #expect(report.passesReleaseLine, "满配全对必须能放行，否则门禁是坏的")
        #expect(report.localeQuota["zh-Hans-CN"] == 500, "六语种配额账必须如实统计")
    }
}
