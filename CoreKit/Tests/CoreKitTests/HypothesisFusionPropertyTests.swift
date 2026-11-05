import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASRFUSION — 属性：无捏造 / 确定性 / 副轨置换不变 / 空校准逐字节 / 分隔符 / 保护对称 / 否定辖域 / 插入 ≥2 引擎 / 回退层级
@Suite("SU-M15-ASRFUSION · 融合属性（无捏造/确定性/置换不变/保护/否定辖域/门槛/回退）")
struct HypothesisFusionPropertyTests {
    typealias F = HypothesisFusionFixtures

    /// 覆盖替换、删除、插入、保护、否定辖域、越语言弃权的输入集。
    static let scenarios: [(primary: String, secondaries: [(String, String)])] = [
        ("今天头疼得历害", [(F.appleZh, "今天头疼得厉害"), (F.sense, "今天头疼得厉害")]),
        ("今天血压120 80", [(F.appleZh, "今天嗯血压120 80"), (F.sense, "今天血压120/80")]),
        ("今天血压", [(F.appleZh, "今天的血压"), (F.sense, "今天的血压")]),
        ("今天嗯血压", [(F.appleZh, "今天血压"), (F.sense, "今天血压")]),
        ("我不发热", [(F.appleZh, "我没发热"), (F.sense, "我发热")]),
        ("我没有发热，头疼得历害", [(F.appleZh, "我没有发热，头疼得厉害"), (F.sense, "我没有发热头疼得厉害")]),
        ("Yes，你说的很对", [(F.appleZh, "耶斯你说的很对"), (F.appleEn, "Yes near show the hen dui")]),
        ("我吃了ibuprofen", [(F.appleZh, "我吃了艾布洛芬"), (F.appleEn, "I chew ibuprofen")]),
        ("I have pain", [(F.appleEn, "I have chest pain"), (F.sense, "I have chest pain")]),
        ("血压120 80，头疼得历害", [(F.appleZh, "血压120 80，头疼得厉害"), (F.sense, "血压120/80头疼得厉害")]),
    ]

    static func run(_ scenario: (primary: String, secondaries: [(String, String)]),
                    options: HypothesisFusionOptions = F.scriptOptions,
                    reversed: Bool = false) -> FusedTranscript {
        var secondaries = scenario.secondaries.map { F.hypothesis($0.0, $0.1) }
        if reversed { secondaries.reverse() }
        return HypothesisFusion.fuse(primary: F.hypothesis(F.primaryID, scenario.primary), secondaries: secondaries,
                                     calibration: F.standard, options: options)
    }

    // MARK: 无捏造 + 就地替换

    @Test("无捏造：每处修改都是某副轨的原样词元；按区间回放主轨即得输出")
    func everyEditComesFromASecondaryToken() {
        var editCount = 0
        for scenario in Self.scenarios {
            let result = Self.run(scenario)
            let surfaces = Set(scenario.secondaries.flatMap { secondary in
                HypothesisFusionTokenizer.tokenize(secondary.1).map { $0.surface }
            })
            var replayed = scenario.primary
            for edit in result.edits.reversed() {
                let trimmed = edit.replacement.trimmingCharacters(in: .whitespaces)
                #expect(edit.kind == .deletion ? trimmed.isEmpty : surfaces.contains(trimmed))
                let lower = String.Index(utf16Offset: edit.utf16Range.lowerBound, in: replayed)
                let upper = String.Index(utf16Offset: edit.utf16Range.upperBound, in: replayed)
                #expect(String(replayed[lower..<upper]) == edit.original)
                replayed.replaceSubrange(lower..<upper, with: edit.replacement)
                editCount += 1
            }
            #expect(Array(replayed.utf8) == Array(result.text.utf8))
        }
        #expect(editCount >= 4)
    }

    @Test("分隔符逐字节保留：「120 80」不会变成「12080」，主轨逗号原样")
    func separatorsArePreservedByteForByte() {
        let result = Self.run(("血压120 80，头疼得历害",
                               [(F.appleZh, "血压120 80，头疼得厉害"), (F.sense, "血压120/80头疼得厉害")]))
        #expect(Array(result.text.utf8) == Array("血压120 80，头疼得厉害".utf8))
        #expect(!result.text.contains("12080"))
    }

    @Test("插入的拉丁词与两侧单词之间补空格")
    func latinInsertionKeepsWordBoundary() {
        let result = Self.run(("I have pain", [(F.appleEn, "I have chest pain"), (F.sense, "I have chest pain")]))
        #expect(result.text == "I have chest pain")
        #expect(result.edits.first?.kind == .insertion)
        #expect(result.edits.first?.utf16Range == 6..<6)
    }

    // MARK: 只提示模式与门控改写的对应

    @Test("只提示 ≡ 门控改写的决策，只是不落笔：每处改写都变成同区间的 reviewOnly 待核，其余待核一致")
    func reviewOnlyMirrorsGatedRewrite() {
        var review = F.scriptOptions
        review.mode = .reviewOnly
        for scenario in Self.scenarios {
            let gated = Self.run(scenario)
            let flagged = Self.run(scenario, options: review)
            #expect(Array(flagged.text.utf8) == Array(scenario.primary.utf8))
            #expect(flagged.edits.isEmpty)
            let editRanges = gated.edits.map { $0.utf16Range }
            let reviewRanges = flagged.disputes.filter { $0.reason == .reviewOnly }.map { $0.utf16Range }
            #expect(editRanges == reviewRanges)
            let otherDisputes = flagged.disputes.filter { $0.reason != .reviewOnly }
            #expect(otherDisputes == gated.disputes)
            #expect(flagged.pairObservations == gated.pairObservations)
        }
    }

    // MARK: 确定性与置换不变

    @Test("确定性：同输入同输出；副轨顺序置换不改变结果")
    func fusionIsDeterministicAndPermutationInvariant() {
        for scenario in Self.scenarios {
            let first = Self.run(scenario)
            let second = Self.run(scenario)
            let permuted = Self.run(scenario, reversed: true)
            #expect(first == second)
            #expect(first == permuted)
        }
        let three = [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.sense, "今天头疼得厉害"),
                     F.hypothesis(F.appleEn, "today head pain")]
        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let baseline = HypothesisFusion.fuse(primary: primary, secondaries: three, calibration: F.standard,
                                             options: F.scriptOptions)
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let shuffled = order.map { three[$0] }
            let result = HypothesisFusion.fuse(primary: primary, secondaries: shuffled, calibration: F.standard,
                                               options: F.scriptOptions)
            #expect(result == baseline)
        }
    }

    @Test("副轨按 engineID 去重；与主轨同名的副轨被剔除")
    func duplicateEnginesAreDeduplicated() {
        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let result = HypothesisFusion.fuse(
            primary: primary,
            secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.appleZh, "今天头疼得厉害"),
                          F.hypothesis(F.primaryID, "今天头疼得厉害")],
            calibration: F.standard, options: F.rewrite)
        // 只剩一个 apple-zh：3.54 − 3.85 < τ，不足以推翻主轨
        #expect(result.sources == [F.primaryID, F.appleZh])
        #expect(result.text == "今天头疼得历害")
        #expect(result.disputes.first?.reason == .belowGate)
    }

    // MARK: 回退与空校准

    @Test("空校准/未过放行线/结构非法/主轨未校准/无副轨 → 与主轨逐字节一致、edits 为空")
    func fallbacksReturnPrimaryByteForByte() {
        // 含组合附加符与 emoji：String == 按规范等价比较，这里必须比字节。
        let primary = F.hypothesis(F.primaryID, "cafe\u{301} 头疼得历害😀")
        let secondaries = [F.hypothesis(F.appleZh, "café 头疼得厉害"), F.hypothesis(F.sense, "café 头疼得厉害")]
        var releasedEmpty = HypothesisFusionCalibration.empty
        releasedEmpty.releasePassed = true
        var malformed = F.standard
        malformed.cells[0].correct = malformed.cells[0].total + 1
        let noPrimary = F.calibration([(F.appleZh, 0.92), (F.sense, 0.93)])
        let cases: [(HypothesisFusionCalibration, [TranscriptionHypothesis], HypothesisFusionFallback)] = [
            (.empty, secondaries, .calibrationNotReleased),
            (releasedEmpty, secondaries, .calibrationEmpty),
            (malformed, secondaries, .calibrationMalformed),
            (noPrimary, secondaries, .primaryUncalibrated),
            (F.standard, [], .noSecondaries),
        ]
        for (calibration, others, reason) in cases {
            let result = HypothesisFusion.fuse(primary: primary, secondaries: others, calibration: calibration)
            #expect(Array(result.text.utf8) == Array(primary.text.utf8))
            #expect(result.edits.isEmpty)
            #expect(result.disputes.isEmpty)
            #expect(result.fallback == reason)
        }
    }

    // MARK: 保护对称与否定辖域

    @Test("保护对称：主轨或候选任一为数字/否定/单位/词条 → 不自动改", arguments: [
        ("他是岁", "他十岁"),
        ("他十岁", "他是岁"),
        ("我发热了", "我没热了"),
        ("我没热了", "我发热了"),
        ("五毫克", "五毫升"),
        ("吃阿莫西林", "吃阿莫西临"),
        ("吃阿莫西临", "吃阿莫西林"),
    ])
    func protectionIsSymmetric(_ pair: (String, String)) {
        let options = HypothesisFusionOptions(mode: .gatedRewrite, protectedTerms: ["阿莫西林"], policy: F.medicalPolicy)
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, pair.0),
            secondaries: [F.hypothesis(F.appleZh, pair.1), F.hypothesis(F.sense, pair.1)],
            calibration: F.standard, options: options)
        #expect(result.text == pair.0)
        #expect(result.edits.isEmpty)
        let reasons = result.disputes.map { $0.reason }
        #expect(!reasons.isEmpty)
        #expect(reasons.allSatisfy { $0 == .protected || $0 == .negationScope })
    }

    @Test("否定辖域：同一子句不自动改；逗号之后的子句照常修正")
    func negationScopeFreezesOnlyItsClause() {
        let frozen = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "我没有头疼得历害"),
            secondaries: [F.hypothesis(F.appleZh, "我没有头疼得厉害"), F.hypothesis(F.sense, "我没有头疼得厉害")],
            calibration: F.standard, options: F.rewrite)
        #expect(frozen.text == "我没有头疼得历害")
        #expect(frozen.disputes.map { $0.reason } == [.negationScope])
        let split = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "我没有发热，头疼得历害"),
            secondaries: [F.hypothesis(F.appleZh, "我没有发热，头疼得厉害"), F.hypothesis(F.sense, "我没有发热头疼得厉害")],
            calibration: F.standard, options: F.rewrite)
        #expect(split.text == "我没有发热，头疼得厉害")
        #expect(split.edits.count == 1)
    }

    @Test("否定辖域：单引擎插入的否定词也冻结子句并记受保护待核")
    func insertedNegationIsReportedAndFreezesClause() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "我发热得历害"),
            secondaries: [F.hypothesis(F.appleZh, "我不发热得厉害"), F.hypothesis(F.sense, "我发热得厉害")],
            calibration: F.standard, options: F.rewrite)
        #expect(result.text == "我发热得历害")
        let reasons = result.disputes.map { $0.reason }
        #expect(reasons.contains(.protected))
        #expect(reasons.contains(.negationScope))
        let inserted = result.disputes.first { $0.primarySurface == nil }
        #expect(inserted?.utf16Range == 1..<1)
        #expect(inserted?.candidates.contains { $0.surface == "不" } == true)
    }

    // MARK: 门槛：插入 ≥2 引擎、删除边际、τ

    @Test("插入须 ≥2 个不同引擎；最少引擎数只能调严")
    func insertionNeedsTwoEngines() {
        let two = Self.run(("今天血压", [(F.appleZh, "今天的血压"), (F.sense, "今天的血压")]))
        #expect(two.text == "今天的血压")
        #expect(two.edits.first?.kind == .insertion)
        #expect(two.edits.first?.supportingEngineIDs == [F.appleZh, F.sense])
        let one = Self.run(("今天血压", [(F.appleZh, "今天的血压"), (F.sense, "今天血压")]),
                           options: HypothesisFusionOptions(mode: .gatedRewrite, minimumInsertionEngines: 1, policy: F.medicalPolicy))
        #expect(one.text == "今天血压")
        #expect(one.edits.isEmpty)
        #expect(one.disputes.isEmpty)
        let strict = Self.run(("今天血压", [(F.appleZh, "今天的血压"), (F.sense, "今天的血压")]),
                              options: HypothesisFusionOptions(mode: .gatedRewrite, minimumInsertionEngines: 3, policy: F.medicalPolicy))
        #expect(strict.text == "今天血压")
        #expect(strict.disputes.map { $0.reason } == [.belowGate])
    }

    @Test("删除主轨内容需 > τ + 删除边际")
    func deletionNeedsExtraMargin() {
        let deleted = Self.run(("今天嗯血压", [(F.appleZh, "今天血压"), (F.sense, "今天血压")]))
        #expect(deleted.text == "今天血压")
        #expect(deleted.edits.first?.kind == .deletion)
        let kept = Self.run(("今天嗯血压", [(F.appleZh, "今天血压"), (F.sense, "今天血压")]),
                            options: HypothesisFusionOptions(mode: .gatedRewrite, deletionMargin: 5, policy: F.medicalPolicy))
        #expect(kept.text == "今天嗯血压")
        #expect(kept.disputes.map { $0.reason } == [.belowGate])
    }

    @Test("τ = ∞ 或 NaN：永远保留主轨（只标待核）", arguments: [Double.infinity, Double.nan])
    func infiniteTauNeverEdits(_ tau: Double) {
        let result = Self.run(("今天头疼得历害", [(F.appleZh, "今天头疼得厉害"), (F.sense, "今天头疼得厉害")]),
                              options: HypothesisFusionOptions(mode: .gatedRewrite, tau: tau, policy: F.medicalPolicy))
        #expect(result.text == "今天头疼得历害")
        #expect(result.disputes.map { $0.reason } == [.belowGate])
    }

    // MARK: 校准回退层级与弃权

    @Test("回退层级：(档) → (词类) → (脚本) → 无数据")
    func calibrationFallsBackLevelByLevel() {
        typealias Cell = HypothesisFusionCalibration.Cell
        let calibration = HypothesisFusionCalibration(
            version: "t", corpusSize: 10, codeSwitchedCount: 0, releasePassed: true, cells: [
                Cell(engineID: "e", script: .han, tokenClass: .word, confidenceBin: 9, correct: 950, total: 1_000),
                Cell(engineID: "e", script: .han, tokenClass: .word, confidenceBin: 1, correct: 180, total: 200),
                Cell(engineID: "e", script: .han, tokenClass: .number, correct: 990, total: 1_000),
                Cell(engineID: "e", script: .latin, tokenClass: .word, correct: 100, total: 150),
            ])
        let binned = calibration.reliability(engineID: "e", script: .han, tokenClass: .word, confidence: 0.95)
        #expect(binned?.level == .confidenceBin)
        #expect(abs((binned?.probability ?? 0) - 0.95) < 1e-12)
        #expect(abs((binned?.weight ?? 0) - log(3 * 0.95 / 0.05)) < 1e-12)
        // 档 1 只有 20 个错误 → 退到 (e, han, word) = 1130/1200
        let thinBin = calibration.reliability(engineID: "e", script: .han, tokenClass: .word, confidence: 0.15)
        #expect(thinBin?.level == .tokenClass)
        #expect(abs((thinBin?.probability ?? 0) - 1_130.0 / 1_200.0) < 1e-12)
        // 无置信度 → 直接从词类层起
        #expect(calibration.reliability(engineID: "e", script: .han, tokenClass: .word)?.level == .tokenClass)
        // (e, han, number) 只有 10 个错误 → 退到 (e, han) = 2120/2200
        let script = calibration.reliability(engineID: "e", script: .han, tokenClass: .number)
        #expect(script?.level == .script)
        #expect(abs((script?.probability ?? 0) - 2_120.0 / 2_200.0) < 1e-12)
        // latin 只有 150 token → 无数据（弃权）；未知引擎 → 弃权
        #expect(calibration.reliability(engineID: "e", script: .latin, tokenClass: .word) == nil)
        #expect(calibration.reliability(engineID: "x", script: .han, tokenClass: .word) == nil)
        // p ≤ 1/(K+1) 的弱引擎权重截为 0（不投负票）
        let weak = HypothesisFusionCalibration(
            version: "t", corpusSize: 1, codeSwitchedCount: 0, releasePassed: true,
            cells: [Cell(engineID: "w", script: .han, tokenClass: .word, correct: 100, total: 1_000)])
        #expect(weak.reliability(engineID: "w", script: .han, tokenClass: .word)?.weight == 0)
    }

    @Test("副轨不在校准表 → 该引擎弃权，单票不足以推翻主轨")
    func uncalibratedSecondaryAbstains() {
        let calibration = F.calibration([(F.primaryID, 0.94), (F.appleZh, 0.92)])
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "今天头疼得历害"),
            secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.sense, "今天头疼得厉害")],
            calibration: calibration, options: F.rewrite)
        #expect(result.text == "今天头疼得历害")
        #expect(result.disputes.map { $0.reason } == [.belowGate])
        let alternative = result.disputes.first?.candidates.first { !$0.isPrimary }
        #expect(alternative?.engineIDs == [F.appleZh, F.sense])
    }

    @Test("主轨在该脚本无校准数据 → 不比较，记 insufficientCalibration")
    func primaryWithoutScriptDataCannotBeOverridden() {
        let calibration = F.calibration([(F.primaryID, 0.94)], scripts: [.han])
        let full = F.calibration([(F.appleEn, 0.93), (F.sense, 0.93)])
        let merged = HypothesisFusionCalibration(version: "t", corpusSize: 600, codeSwitchedCount: 120,
                                                 releasePassed: true, cells: calibration.cells + full.cells)
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "我吃了ibuprofin"),
            secondaries: [F.hypothesis(F.appleEn, "我吃了ibuprofen"), F.hypothesis(F.sense, "我吃了ibuprofen")],
            calibration: merged, options: F.rewrite)
        #expect(result.text == "我吃了ibuprofin")
        #expect(result.disputes.map { $0.reason } == [.insufficientCalibration])
    }

    @Test("置信度档驱动决策：高档单票可改、低档或无置信度不可改")
    func confidenceBinsDriveTheDecision() {
        typealias Cell = HypothesisFusionCalibration.Cell
        var cells = F.calibration([(F.primaryID, 0.94)]).cells
        cells.append(Cell(engineID: F.appleZh, script: .han, tokenClass: .word, confidenceBin: 9,
                          correct: 9_900, total: 10_000))
        cells.append(Cell(engineID: F.appleZh, script: .han, tokenClass: .word, confidenceBin: 1,
                          correct: 3_000, total: 10_000))
        let calibration = HypothesisFusionCalibration(version: "t", corpusSize: 600, codeSwitchedCount: 120,
                                                      releasePassed: true, cells: cells)
        func fuse(confidence: Double?) -> FusedTranscript {
            let tokens = confidence.map { value in
                [TranscriptionToken(text: "今天", confidence: 0.99), TranscriptionToken(text: "头疼得", confidence: 0.99),
                 TranscriptionToken(text: "厉害", confidence: value)]
            } ?? []
            let secondary = TranscriptionHypothesis(engineID: F.appleZh, text: "今天头疼得厉害", tokens: tokens,
                                                    confidenceKind: confidence == nil ? .unavailable : .engineNative)
            return HypothesisFusion.fuse(primary: F.hypothesis(F.primaryID, "今天头疼得历害"),
                                         secondaries: [secondary], calibration: calibration, options: F.rewrite)
        }
        #expect(fuse(confidence: 0.95).text == "今天头疼得厉害")
        #expect(fuse(confidence: 0.15).text == "今天头疼得历害")
        #expect(fuse(confidence: nil).text == "今天头疼得历害")
    }

    @Test("越语言弃权：只产拉丁的引擎不能改汉字列")
    func latinOnlyEngineAbstainsOnHanColumns() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "你说的很对"),
            secondaries: [F.hypothesis(F.appleEn, "near show the hen dui"),
                          F.hypothesis(F.sense, "near show the hen dui")],
            calibration: F.standard,
            options: HypothesisFusionOptions(producibleScripts: [F.appleEn: [.latin, .digit, .other],
                                                                 F.sense: [.latin, .digit, .other]],
                                     policy: F.medicalPolicy))
        #expect(result.text == "你说的很对")
        #expect(result.edits.isEmpty)
        #expect(result.disputes.isEmpty)
    }

    // MARK: 退化输入

    @Test("无词元的副轨（空文本/只有标点 ≈ 引擎失败）整体弃权，绝不投票删除主轨")
    func emptySecondariesNeverDeletePrimary() {
        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let allEmpty = HypothesisFusion.fuse(primary: primary,
                                             secondaries: [F.hypothesis(F.appleZh, ""), F.hypothesis(F.sense, "。")],
                                             calibration: F.standard)
        #expect(Array(allEmpty.text.utf8) == Array(primary.text.utf8))
        #expect(allEmpty.fallback == .noSecondaries)
        let oneEmpty = HypothesisFusion.fuse(primary: primary,
                                             secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.sense, "")],
                                             calibration: F.standard, options: F.rewrite)
        #expect(oneEmpty.text == "今天头疼得历害")
        #expect(oneEmpty.edits.isEmpty)
        #expect(oneEmpty.disputes.map { $0.reason } == [.belowGate])
        #expect(oneEmpty.sources == [F.primaryID, F.appleZh, F.sense])
    }

    @Test("主轨为空：仍须 ≥2 个引擎一致才插入")
    func emptyPrimaryNeedsTwoAgreeingEngines() {
        let two = HypothesisFusion.fuse(primary: F.hypothesis(F.primaryID, ""),
                                        secondaries: [F.hypothesis(F.appleZh, "你好"), F.hypothesis(F.sense, "你好")],
                                        calibration: F.standard, options: F.rewrite)
        #expect(two.text == "你好")
        #expect(two.edits.map { $0.utf16Range } == [0..<0, 0..<0])
        let one = HypothesisFusion.fuse(primary: F.hypothesis(F.primaryID, ""),
                                        secondaries: [F.hypothesis(F.appleZh, "你好"), F.hypothesis(F.sense, "再见")],
                                        calibration: F.standard, options: F.rewrite)
        #expect(one.text == "")
        #expect(one.edits.isEmpty)
    }

    @Test("超长输入超出 DP 格子上限 → 只用主轨")
    func oversizedInputFallsBackToPrimary() {
        let primary = F.hypothesis(F.primaryID, String(repeating: "好", count: 1_001))
        let result = HypothesisFusion.fuse(primary: primary,
                                           secondaries: [F.hypothesis(F.appleZh, String(repeating: "好", count: 1_000))],
                                           calibration: F.standard)
        #expect(result.fallback == .inputTooLong)
        #expect(result.text == primary.text)
        #expect(result.edits.isEmpty)
    }

    @Test("负 τ 按 0 处理：得分不高于主轨的候选永不替换")
    func negativeTauIsClampedToZero() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "今天头疼得历害"),
            secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害")],
            calibration: F.standard,
            options: HypothesisFusionOptions(mode: .gatedRewrite, tau: -100, deletionMargin: -100, policy: F.medicalPolicy))
        #expect(result.text == "今天头疼得历害")
        #expect(result.disputes.map { $0.reason } == [.belowGate])
    }
}
