import Foundation
import Testing
@testable import Domain

// binds: SU-M15-ASRFUSION — 无标签漂移报警：未漂移通过 / 显著漂移回落 / 样本不足不判 / 系统版本不一致回落 / 缺基线回落
/// Apple 识别模型随系统静默更新、旧校准会让门控变差：设备上没有金样标签，只能监测引擎间分歧率
/// 是否显著超出校准包记录的基线（二项分布单侧 99% 上界）。
@Suite("SU-M15-ASRFUSION · 无标签漂移监测与门控回落")
struct HypothesisFusionDriftTests {
    typealias F = HypothesisFusionFixtures
    typealias Monitor = HypothesisFusionDriftMonitor

    static func calibration(osBuild: String? = nil,
                            baselines: [(String, Double)] = [(F.appleZh, 0.10)]) -> HypothesisFusionCalibration {
        var calibration = F.standard
        calibration.baselineDisagreementRates = baselines.map {
            HypothesisFusionDisagreementBaseline(primaryEngineID: F.primaryID, secondaryEngineID: $0.0, rate: $0.1)
        }
        calibration.osBuild = osBuild
        return calibration
    }

    static func observation(_ secondary: String, _ disagreements: Int,
                            _ columns: Int) -> HypothesisFusionPairObservation {
        HypothesisFusionPairObservation(primaryEngineID: F.primaryID, secondaryEngineID: secondary,
                                        disagreements: disagreements, columns: columns)
    }

    @Test("上界是精确的单侧 99% 分位：P(X > U) ≤ 1% < P(X ≥ U)")
    func upperBoundIsExactOneSidedQuantile() {
        // 与精确二项分布逐项求和（Python 有理数核对）一致：U(1000, 0.1) = 123，U(210, 0.1) = 32。
        let bound = Monitor.upperBound(columns: 1_000, baselineRate: 0.10) ?? -1
        #expect(bound == 123)
        #expect(Monitor.upperBound(columns: 210, baselineRate: 0.10) == 32)
        #expect(Monitor.upperTail(atLeast: bound + 1, trials: 1_000, probability: 0.10) <= Monitor.significance)
        #expect(Monitor.upperTail(atLeast: bound, trials: 1_000, probability: 0.10) > Monitor.significance)
        #expect(Monitor.upperBound(columns: 500, baselineRate: 0) == 0)
        #expect(Monitor.upperBound(columns: 500, baselineRate: 1) == 500)
        #expect(Monitor.upperBound(columns: 500, baselineRate: .nan) == nil)
        #expect(Monitor.upperBound(columns: 500, baselineRate: 1.5) == nil)
        #expect(Monitor.upperBound(columns: -1, baselineRate: 0.1) == nil)
        // 远尾下溢到 0 仍判为显著（不会因下溢误判为不显著）
        #expect(Monitor.upperTail(atLeast: 90_000, trials: 100_000, probability: 0.1) == 0)
    }

    @Test("未漂移：观测分歧率在上界内 → 稳定，门控照常")
    func stableWindowKeepsGateOpen() {
        let calibration = Self.calibration()
        let report = Monitor.assess(calibration: calibration, currentOSBuild: nil,
                                    observations: [Self.observation(F.appleZh, 110, 1_000)])
        #expect(report.pairs.map { $0.verdict } == [.stable])
        #expect(!report.requiresFallback)
        #expect(HypothesisFusionGate.isEnabled(labSwitch: true, calibration: calibration, drift: report))
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: false, calibration: calibration, drift: report))
    }

    @Test("显著漂移：观测分歧率超出基线上界 → 门控回落主轨")
    func significantDriftClosesGate() {
        let calibration = Self.calibration()
        let report = Monitor.assess(calibration: calibration, currentOSBuild: nil,
                                    observations: [Self.observation(F.appleZh, 200, 1_000)])
        #expect(report.pairs.map { $0.verdict } == [.drifted])
        #expect(report.pairs.first?.upperBound.map { $0 < 200 } == true)
        #expect(report.requiresFallback)
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: calibration, drift: report))
        // 基线为 0 的引擎对：样本足够时任何分歧都算漂移
        let zero = Self.calibration(baselines: [(F.appleZh, 0)])
        let zeroReport = Monitor.assess(calibration: zero, currentOSBuild: nil,
                                        observations: [Self.observation(F.appleZh, 1, 400)])
        #expect(zeroReport.pairs.map { $0.verdict } == [.drifted])
    }

    @Test("样本不足：窗口列数 < 最小样本数，不判漂移、不回落")
    func insufficientSamplesNeverFlagDrift() {
        let calibration = Self.calibration()
        let columns = Monitor.minimumWindowColumns - 1
        let report = Monitor.assess(calibration: calibration, currentOSBuild: nil,
                                    observations: [Self.observation(F.appleZh, columns, columns)])
        #expect(report.pairs.map { $0.verdict } == [.insufficientSamples])
        #expect(!report.requiresFallback)
        #expect(HypothesisFusionGate.isEnabled(labSwitch: true, calibration: calibration, drift: report))
    }

    @Test("系统版本与校准记录不一致 → 回落；取不到当前版本按不一致处理")
    func osBuildMismatchClosesGate() {
        let pinned = Self.calibration(osBuild: "23A344")
        let mismatch = Monitor.assess(calibration: pinned, currentOSBuild: "23B74", observations: [])
        #expect(!mismatch.osBuildMatches)
        #expect(mismatch.requiresFallback)
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: pinned, drift: mismatch))
        let unknown = Monitor.assess(calibration: pinned, currentOSBuild: nil, observations: [])
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: pinned, drift: unknown))
        let same = Monitor.assess(calibration: pinned, currentOSBuild: "23A344", observations: [])
        #expect(HypothesisFusionGate.isEnabled(labSwitch: true, calibration: pinned, drift: same))
        // 钉了系统版本的校准包不能走无法核对版本的基础门控
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: pinned))
        #expect(Monitor.osBuildMatches(calibration: Self.calibration(), currentOSBuild: nil))
    }

    @Test("缺基线（样本已足）/ 计数非法 / 报告出自别的校准包 → 回落")
    func unverifiableStatesFailClosed() {
        let calibration = Self.calibration()
        let missing = Monitor.assess(calibration: calibration, currentOSBuild: nil,
                                     observations: [Self.observation(F.sense, 10, 500)])
        #expect(missing.pairs.map { $0.verdict } == [.missingBaseline])
        #expect(missing.requiresFallback)
        let invalid = Monitor.assess(calibration: calibration, currentOSBuild: nil,
                                     observations: [Self.observation(F.appleZh, 501, 500)])
        #expect(invalid.pairs.map { $0.verdict } == [.invalidObservation])
        #expect(invalid.requiresFallback)
        let stable = Monitor.assess(calibration: calibration, currentOSBuild: nil,
                                    observations: [Self.observation(F.appleZh, 100, 1_000)])
        var other = calibration
        other.version = "other"
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: other, drift: stable))
        var unreleased = calibration
        unreleased.releasePassed = false
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: unreleased, drift: stable))
        #expect(!HypothesisFusionGate.isEnabled(labSwitch: true, calibration: nil, drift: stable))
    }

    @Test("窗口内同一引擎对的观测求和，输出按引擎对字节序排列")
    func observationsAggregatePerPair() {
        let calibration = Self.calibration(baselines: [(F.appleZh, 0.10), (F.sense, 0.10)])
        let report = Monitor.assess(calibration: calibration, currentOSBuild: nil, observations: [
            Self.observation(F.sense, 5, 150), Self.observation(F.appleZh, 50, 300),
            Self.observation(F.appleZh, 60, 300),
        ])
        #expect(report.pairs.map { $0.secondaryEngineID } == [F.appleZh, F.sense])
        #expect(report.pairs.first?.disagreements == 110)
        #expect(report.pairs.first?.columns == 600)
        #expect(report.pairs.map { $0.verdict } == [.drifted, .insufficientSamples])
    }

    @Test("融合输出逐次给出主轨 × 副轨分歧计数（与基线同一口径）")
    func fusionEmitsPairObservations() {
        let filler = HypothesisFusion.fuse(
            primary: F.hypothesis(F.primaryID, "今天血压120 80"),
            secondaries: [F.hypothesis(F.appleZh, "今天嗯血压120 80"), F.hypothesis(F.sense, "今天血压120/80")],
            calibration: F.standard, options: F.scriptOptions)
        #expect(filler.pairObservations == [Self.observation(F.appleZh, 1, 7), Self.observation(F.sense, 0, 6)])
        let fallback = HypothesisFusion.fuse(primary: F.hypothesis(F.primaryID, "今天"), secondaries: [],
                                             calibration: F.standard)
        #expect(fallback.pairObservations.isEmpty)
    }

    @Test("端到端：逐次融合累积窗口 → 漂移评估（同一窗口，基线高则稳定、基线低则回落）")
    func endToEndWindowAssessment() {
        var window: [HypothesisFusionPairObservation] = []
        for _ in 0..<30 {
            let result = HypothesisFusion.fuse(
                primary: F.hypothesis(F.primaryID, "今天头疼得历害"),
                secondaries: [F.hypothesis(F.appleZh, "今天头疼得厉害")], calibration: F.standard)
            window += result.pairObservations
        }
        let tolerant = Monitor.assess(calibration: Self.calibration(baselines: [(F.appleZh, 0.10)]),
                                      currentOSBuild: nil, observations: window)
        #expect(tolerant.pairs.first?.columns == 210)
        #expect(tolerant.pairs.first?.disagreements == 30)
        #expect(tolerant.pairs.map { $0.verdict } == [.stable])
        let strict = Monitor.assess(calibration: Self.calibration(baselines: [(F.appleZh, 0.02)]),
                                    currentOSBuild: nil, observations: window)
        #expect(strict.pairs.map { $0.verdict } == [.drifted])
    }

    @Test("校准包 JSON：基线与系统版本字段可选（旧包缺省 = 无基线、未钉版本），非法基线拒收")
    func calibrationDriftFieldsDecode() throws {
        let legacy = """
        {"version":"v1","corpus_size":1,"code_switched_count":0,"release_passed":true,"confidence_bin_count":10,
         "cells":[{"engine_id":"qwen3","script":"han","token_class":"word","correct":9,"total":10}]}
        """
        let decodedLegacy = try JSONDecoder().decode(HypothesisFusionCalibration.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.baselineDisagreementRates.isEmpty)
        #expect(decodedLegacy.osBuild == nil)
        let current = """
        {"version":"v2","corpus_size":1,"code_switched_count":0,"release_passed":true,"confidence_bin_count":10,
         "cells":[],"os_build":"23A344","baseline_disagreement_rates":[
          {"primary_engine_id":"qwen3","secondary_engine_id":"apple-zh","rate":0.12}]}
        """
        let decoded = try JSONDecoder().decode(HypothesisFusionCalibration.self, from: Data(current.utf8))
        #expect(decoded.osBuild == "23A344")
        #expect(decoded.baselineDisagreementRate(primaryEngineID: "qwen3", secondaryEngineID: "apple-zh") == 0.12)
        #expect(decoded.isWellFormed)
        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(HypothesisFusionCalibration.self, from: encoded)
        #expect(roundTrip == decoded)
        var outOfRange = decoded
        outOfRange.baselineDisagreementRates[0].rate = 1.5
        #expect(!outOfRange.isWellFormed)
        var duplicated = decoded
        duplicated.baselineDisagreementRates.append(decoded.baselineDisagreementRates[0])
        #expect(!duplicated.isWellFormed)
    }
}
