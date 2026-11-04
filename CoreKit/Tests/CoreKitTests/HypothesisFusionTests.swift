import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASRFUSION — round3 §3.3 七个难例 + 门控 fail-closed + 极性保护 + 评测 fixes/harms
/// 多假设融合实验室模块（round3 §6「主轨默认 · 语言感知 · 校准加权 · 带保护的 ROVER」）。
/// 纯 Domain、确定性；本套件全部可在 Linux runner 执行。
@Suite("SU-M15-ASRFUSION · 多假设融合实验室模块（主轨默认/语言感知/校准加权/保护）")
struct HypothesisFusionTests {
    typealias F = HypothesisFusionFixtures

    // MARK: round3 §3.3 七个难例

    @Test("难例 1：单引擎插入「嗯」被丢弃，「120 80」分隔符原样")
    func fillerInsertionFromOneEngineIsDropped() {
        let primary = F.hypothesis(F.primaryID, "今天血压120 80")
        let result = HypothesisFusion.fuse(
            primary: primary,
            secondaries: [F.hypothesis(F.appleZh, "今天嗯血压120 80"), F.hypothesis(F.sense, "今天血压120/80")],
            calibration: F.standard, options: F.scriptOptions)
        #expect(Array(result.text.utf8) == Array(primary.text.utf8))
        #expect(result.edits.isEmpty)
        #expect(result.disputes.isEmpty)
        #expect(result.fallback == nil)
    }

    @Test("难例 2：不/没/∅ 否定分歧 → 保留「不」并标待核（候选 没、∅）")
    func negationDisagreementKeepsPrimaryAndDisputes() {
        for mode in F.modes {
            let result = HypothesisFusion.fuse(
                primary: F.hypothesis(F.primaryID, "我不发热"),
                secondaries: [F.hypothesis(F.appleZh, "我没发热"), F.hypothesis(F.sense, "我发热")],
                calibration: F.standard, options: HypothesisFusionOptions(mode: mode))
            Self.expectNegationDispute(result)
        }
    }

    static func expectNegationDispute(_ result: FusedTranscript) {
        #expect(result.text == "我不发热")
        #expect(result.edits.isEmpty)
        #expect(result.disputes.count == 1)
        let dispute = result.disputes.first
        #expect(dispute?.reason == .protected)
        #expect(dispute?.utf16Range == 1..<2)
        let surfaces = dispute?.candidates.map { $0.surface } ?? []
        #expect(surfaces.first == "不")
        #expect(dispute?.candidates.first?.isPrimary == true)
        #expect(surfaces.contains("没"))
        #expect(surfaces.contains(nil))
    }

    @Test("难例 3：五百 ≡ 500 数值等同不报分歧，主轨写法原样保留")
    func numericEquivalenceRaisesNoDispute() {
        let primary = F.hypothesis(F.primaryID, "阿莫西林五百毫克")
        for mode in F.modes {
            let result = HypothesisFusion.fuse(
                primary: primary,
                secondaries: [F.hypothesis(F.appleZh, "阿莫西林500毫克"), F.hypothesis(F.sense, "阿莫西林 500 mg")],
                calibration: F.standard, options: HypothesisFusionOptions(mode: mode))
            #expect(result.text == primary.text)
            #expect(result.edits.isEmpty)
            let numberRange = 4..<6
            let overlapping = result.disputes.filter { $0.utf16Range.overlaps(numberRange) }
            #expect(overlapping.isEmpty)
            // 单位列（毫克 vs mg/∅）只可能是受保护待核，绝不自动改
            let reasons = result.disputes.map { $0.reason }
            #expect(reasons.allSatisfy { $0 == .protected })
        }
    }

    @Test("难例 4：Yes 与 耶斯——越语言引擎弃权，主轨 Yes 保留")
    func codeSwitchedYesSurvivesTransliteration() {
        let primary = F.hypothesis(F.primaryID, "Yes，你说的很对")
        let result = HypothesisFusion.fuse(
            primary: primary,
            secondaries: [F.hypothesis(F.appleZh, "耶斯你说的很对"),
                          F.hypothesis(F.appleEn, "Yes near show the hen dui")],
            calibration: F.standard, options: F.scriptOptions)
        #expect(result.text == "Yes，你说的很对")
        #expect(result.edits.isEmpty)
        #expect(result.disputes.isEmpty)
    }

    @Test("难例 5：主轨「历害」、两副轨「厉害」→ 自动改为「厉害」")
    func twoAgreeingSecondariesFixPrimaryTypo() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "今天头疼得历害"),
            secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.sense, "今天头疼得厉害")],
            calibration: F.standard, options: F.rewrite)
        #expect(result.text == "今天头疼得厉害")
        #expect(result.edits.count == 1)
        let edit = result.edits.first
        #expect(edit?.kind == .substitution)
        #expect(edit?.utf16Range == 5..<6)
        #expect(edit?.original == "历")
        #expect(edit?.replacement == "厉")
        #expect(edit?.supportingEngineIDs == [F.appleZh, F.sense])
        #expect((edit?.margin ?? 0) > 1)
        #expect(result.disputes.isEmpty)
    }

    @Test("难例 6：同音 是/十——候选含数字即受保护，不自动改")
    func homophoneNumberCandidateIsProtected() {
        for mode in F.modes {
            let result = HypothesisFusion.fuse(
                primary: F.hypothesis(F.primaryID, "他是岁"),
                secondaries: [F.hypothesis(F.appleZh, "他十岁"), F.hypothesis(F.sense, "他十岁")],
                calibration: F.standard, options: HypothesisFusionOptions(mode: mode))
            #expect(result.text == "他是岁")
            #expect(result.edits.isEmpty)
            #expect(result.disputes.count == 1)
            #expect(result.disputes.first?.reason == .protected)
            let alternative = result.disputes.first?.candidates.first { !$0.isPrimary }
            #expect(alternative?.surface == "十")
            #expect(alternative?.engineIDs == [F.appleZh, F.sense])
        }
    }

    @Test("难例 7：英文药名 ibuprofen 与音译「艾布洛芬」——音译余字作为单引擎插入被丢弃")
    func englishDrugNameSurvivesTransliteration() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "我吃了ibuprofen"),
            secondaries: [F.hypothesis(F.appleZh, "我吃了艾布洛芬"), F.hypothesis(F.appleEn, "I chew ibuprofen")],
            calibration: F.standard, options: F.scriptOptions)
        #expect(result.text == "我吃了ibuprofen")
        #expect(result.edits.isEmpty)
        #expect(result.disputes.isEmpty)
    }

    // MARK: 极性/方位/时序（反方辩论核验追加）

    @Test("左→右：两家一致也不得自动改，记 polarity 待核", arguments: [
        ("左腿疼得历害", "右腿疼得历害"),
        ("右腿疼得历害", "左腿疼得历害"),
        ("检查结果阴性", "检查结果阳性"),
        ("饭前服用", "饭后服用"),
        ("剂量增加", "剂量减少"),
        ("早晚各一次", "早中各一次"),
        ("chest pain on the left", "chest pain on the right"),
        ("test positive", "test negative"),
    ])
    func polarityWordsAreNeverAutoCorrected(_ pair: (String, String)) {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, pair.0),
            secondaries: [F.hypothesis(F.appleZh, pair.1), F.hypothesis(F.sense, pair.1)],
            calibration: F.standard, options: F.rewrite)
        #expect(result.text == pair.0)
        #expect(result.edits.isEmpty)
        let reasons = result.disputes.map { $0.reason }
        #expect(reasons.contains(.polarity))
    }

    @Test("极性词表是公开常量，覆盖业主核验清单且不含「上/下」")
    func polarityVocabularyIsAuditable() {
        let required = ["阴性", "阳性", "阴", "阳", "左", "右", "双侧", "前", "后", "饭前", "饭后", "餐前", "餐后",
                        "睡前", "空腹", "早", "中", "晚", "增", "减", "加", "停", "left", "right", "bilateral",
                        "positive", "negative", "before", "after", "increase", "decrease", "stop"]
        let vocabulary = Set(HypothesisFusionVocabulary.polarity)
        #expect(required.allSatisfy { vocabulary.contains($0) })
        #expect(!vocabulary.contains("上"))
        #expect(!vocabulary.contains("下"))
    }

    // MARK: 只提示不改写（辩论终裁 P2a，默认模式）

    @Test("默认模式是只提示不改写")
    func reviewOnlyIsTheDefaultMode() {
        #expect(HypothesisFusionOptions().mode == .reviewOnly)
    }

    @Test("只提示：text 逐字节等于主轨、edits 为空，本会改写的「历害/厉害」列进 disputes（reviewOnly）")
    func reviewOnlyFlagsRewritableColumnsWithoutRewriting() {
        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let result = HypothesisFusion.fuse(
            primary: primary,
            secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.sense, "今天头疼得厉害")],
            calibration: F.standard)
        #expect(Array(result.text.utf8) == Array(primary.text.utf8))
        #expect(result.edits.isEmpty)
        #expect(result.fallback == nil)
        #expect(result.disputes.count == 1)
        let dispute = result.disputes.first
        #expect(dispute?.reason == .reviewOnly)
        #expect(dispute?.utf16Range == 5..<6)
        #expect(dispute?.primarySurface == "历")
        let alternative = dispute?.candidates.first { !$0.isPrimary }
        #expect(alternative?.surface == "厉")
        #expect(alternative?.engineIDs == [F.appleZh, F.sense])
    }

    @Test("只提示：极性/保护等原因照常标注，可改写列另记 reviewOnly")
    func reviewOnlyKeepsSafetyReasons() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "左腿疼得历害"),
            secondaries: [F.hypothesis(F.appleZh, "右腿疼得厉害"), F.hypothesis(F.sense, "右腿疼得厉害")],
            calibration: F.standard)
        #expect(result.text == "左腿疼得历害")
        #expect(result.edits.isEmpty)
        #expect(result.disputes.map { $0.reason } == [.polarity, .reviewOnly])
    }

    // MARK: 门控 fail-closed

    @Test("门控：isEnabled ⟹ releasePassed；实验室开关只是必要条件")
    func gateIsFailClosed() {
        let released = F.standard
        var notReleased = F.standard
        notReleased.releasePassed = false
        #expect(HypothesisFusionGate.isEnabled(labSwitch: true, calibration: released))
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: false, calibration: released))
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: nil))
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: notReleased))
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: .empty))
        for labSwitch in [false, true] {
            for calibration in [nil, released, notReleased, HypothesisFusionCalibration.empty] {
                let enabled = HypothesisFusionGate.isEnabled(labSwitch: labSwitch, calibration: calibration)
                #expect(!enabled || (calibration?.releasePassed == true))
            }
        }
    }

    @Test("engineID 记录主轨与排序后的副轨")
    func engineIDDescribesSources() {
        let result = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "今天头疼得历害"),
            secondaries: [F.hypothesis(F.sense, "今天头疼得厉害"), F.hypothesis(F.appleZh, "今天头疼得厉害")],
            calibration: F.standard)
        #expect(result.engineID == "fusion:v1(primary=qwen3;secondaries=apple-zh,sense-voice)")
        #expect(result.sources == [F.primaryID, F.appleZh, F.sense])
    }

    // MARK: 评测 fixes / harms

    @Test("evaluate：主轨错融合对 = fix；主轨对融合错 = harm；数值等价不计")
    func evaluationCountsFixesAndHarms() {
        let fix = HypothesisFusion.evaluate(fused: "今天头疼得厉害", reference: "今天头疼得厉害", primary: "今天头疼得历害")
        #expect(fix == HypothesisFusionEvaluation(fixes: 1, harms: 0))
        let harm = HypothesisFusion.evaluate(fused: "今天头疼得历害", reference: "今天头疼得厉害", primary: "今天头疼得厉害")
        #expect(harm == HypothesisFusionEvaluation(fixes: 0, harms: 1))
        let same = HypothesisFusion.evaluate(fused: "今天血压120 80", reference: "今天血压120/80", primary: "今天血压120 80")
        #expect(same == HypothesisFusionEvaluation(fixes: 0, harms: 0))
        let removed = HypothesisFusion.evaluate(fused: "今天血压", reference: "今天血压", primary: "今天嗯血压")
        #expect(removed == HypothesisFusionEvaluation(fixes: 1, harms: 0))
        let added = HypothesisFusion.evaluate(fused: "今天嗯血压", reference: "今天血压", primary: "今天血压")
        #expect(added == HypothesisFusionEvaluation(fixes: 0, harms: 1))
        let numeric = HypothesisFusion.evaluate(fused: "阿莫西林500毫克", reference: "阿莫西林500毫克",
                                                primary: "阿莫西林五百毫克")
        #expect(numeric == HypothesisFusionEvaluation(fixes: 0, harms: 0))
        let bothWrong = HypothesisFusion.evaluate(fused: "他力岁", reference: "他十岁", primary: "他是岁")
        #expect(bothWrong == HypothesisFusionEvaluation(fixes: 0, harms: 0))
    }

    @Test("evaluate 便捷重载与融合结果对接")
    func evaluationOverloadUsesFusedText() {
        let primary = F.hypothesis(F.primaryID, "今天头疼得历害")
        let fused = HypothesisFusion.fuse(
            primary: primary,
            secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害"), F.hypothesis(F.sense, "今天头疼得厉害")],
            calibration: F.standard, options: F.rewrite)
        let evaluation = HypothesisFusion.evaluate(fused: fused, reference: "今天头疼得厉害", primary: primary)
        #expect(evaluation == HypothesisFusionEvaluation(fixes: 1, harms: 0))
    }
}

/// 本组套件共用的夹具（引擎名、校准表、脚本声明）。
enum HypothesisFusionFixtures {
    static let primaryID = "qwen3"
    static let appleZh = "apple-zh"
    static let appleEn = "apple-en"
    static let sense = "sense-voice"

    static func hypothesis(_ engineID: String, _ text: String) -> TranscriptionHypothesis {
        TranscriptionHypothesis(engineID: engineID, text: text)
    }

    /// 每个引擎在全部脚本 × 词类上以同一正确率 p 生成充分格子（10 000 token；p ≤ 0.997 时错误数 ≥ 30）。
    static func calibration(_ accuracies: [(String, Double)],
                            scripts: [HypothesisFusionScript] = HypothesisFusionScript.allCases,
                            released: Bool = true) -> HypothesisFusionCalibration {
        var cells: [HypothesisFusionCalibration.Cell] = []
        for (engine, accuracy) in accuracies {
            for script in scripts {
                for tokenClass in HypothesisFusionTokenClass.allCases {
                    cells.append(HypothesisFusionCalibration.Cell(
                        engineID: engine, script: script, tokenClass: tokenClass,
                        correct: Int((accuracy * 10_000).rounded()), total: 10_000))
                }
            }
        }
        return HypothesisFusionCalibration(version: "test", corpusSize: 600, codeSwitchedCount: 120,
                                           releasePassed: released, cells: cells)
    }

    /// 主轨 0.94、Apple 中文 0.92、Apple 英文 0.93、SenseVoice 0.93（round3 原型同口径）。
    static var standard: HypothesisFusionCalibration {
        calibration([(primaryID, 0.94), (appleZh, 0.92), (appleEn, 0.93), (sense, 0.93)])
    }

    /// 两种模式（只提示 / 门控改写）——保护类结论在两种模式下必须一致。
    static let modes: [HypothesisFusionOptions.Mode] = [.reviewOnly, .gatedRewrite]

    /// 门控改写模式（§3.3 难例按改写语义验证；默认模式是只提示）。
    static var rewrite: HypothesisFusionOptions { HypothesisFusionOptions(mode: .gatedRewrite) }

    /// 门控改写 + 脚本声明：Apple 中文只产汉字/数字/符号；Apple 英文只产拉丁/数字/符号；其余引擎全脚本。
    static var scriptOptions: HypothesisFusionOptions {
        HypothesisFusionOptions(mode: .gatedRewrite, producibleScripts: [appleZh: [.han, .digit, .other],
                                                                         appleEn: [.latin, .digit, .other]])
    }
}
