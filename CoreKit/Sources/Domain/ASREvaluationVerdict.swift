import Foundation

/// 杀手实验止损判定（round3 §8 P0-A「止损条件」+ 辩论终裁两项判据；全部阈值集中于 `Thresholds`，改阈值 = 改规格）。
///
/// 五条规则逐条给出状态、动作与理由：
/// 1. **Apple-en 边际增益**：只认 **token 级**证据（含/不含该引擎的融合 MER 消融，或融合模块给出的 token 级
///    oracle；token 级对齐属融合模块，本评测层不实现）。证据的语种标签须**取自主轨**（取自参考 = 信息泄漏）。
///    留用 ⟺ 含该引擎的融合输出相对主轨 harm/fix ≤ 0.2，且边际增益 95% CI 下界 > 0；否则建议删除。
///    **只有逐句 oracle 证据时一律「证据不足（advisory）」、不建议删除**：逐句 oracle 只能整句择一，会系统性低估
///    只在句内少数英文词上起作用的引擎（模拟：逐句增益 0.00pt，token 级融合仍 6.53% → 5.63%）。
/// 2. **切段 vs 连续**：逐句 MER 差（切段 − 连续）配对 bootstrap 95% CI 下界 > 0（切段显著更差）→ 不做同段解码。
/// 3. **安全回归**：任一候选/融合系统相对主轨，在 emergencyPositive 句上丢失急救词命中、或在 negation 句上
///    丢失主轨保住的否定词 → 终止多模融合，回到「最佳单模 + 热词 + 人工确认」。
/// 4. **harm/fix**（参考锚定，相对主轨，见 `ASREvaluation.HarmFix`）：任一候选 > 0.2 → 不得放行自动改写。
/// 5. **置信度区分度**：所有置信源（带逐词置信度的系统）AUROC < 0.85 → 不做逐词自动改写，只保留不一致提示。
///
/// **缺证据 = 止损**（ERR#27 根因族「缺证据被当成有证据」的正解；同 FR17.4 `VoiceCalibration` fail-closed）：
/// 规则 2–5 无法评估时取保守动作。规则 1 例外：删除引擎本身也需要证据，缺 token 级证据时只出 advisory、维持现状。
/// 总结论只由规则 3 决定：`continue` ⟺ 规则 3 已评估且零回归；规则 1、2 只调整融合方案，规则 4、5 只决定
/// 是否放行自动改写（`automaticRewriteAllowed`），都不单独叫停融合研究（候选点选仍可做）。
///
/// **急救样本量附注**：急救阳性配对样本 n < 60 时，急救结论标为「只能发现回归、不能证明安全」——零漏报时
/// 漏报率的单侧 95% 置信上限为 1 − 0.05^(1/n)（零事件法则 ≈ 3/n；n = 20 时 ≈ 13.9%，n = 60 时 ≈ 4.9%）。
public struct ASREvaluationVerdict: Sendable, Equatable, Codable {

    /// 全部判定阈值（集中于此）。
    public enum Thresholds {
        /// 规则 1：Apple-en token 级边际增益的 95% CI 下界须**大于**此值（百分点）才留用。
        public static let appleEnglishGainLowerBoundPercentagePoints = 0.0
        /// 规则 1 前提与规则 4：harm/fix 上限（含）。
        public static let maximumHarmFixRatio = 0.2
        /// 规则 2：切段 − 连续 MER 差的 CI 下界超过此值 → 切段显著更差。
        public static let segmentedWorseLowerBound = 0.0
        /// 规则 3：可容忍的急救/否定回归数。
        public static let tolerableSafetyRegressions = 0
        /// 规则 3 附注：急救阳性样本少于此数 → 只能发现回归、不能证明安全。
        public static let minimumEmergencyPositiveSamples = 60
        /// 规则 3 附注：零漏报置信上限的单侧显著性水平（95% 置信）。
        public static let emergencyMissRateAlpha = 0.05
        /// 规则 5：置信源 AUROC 下限（含）；全部低于此值 → 只保留不一致提示。
        public static let minimumConfidenceAUROC = 0.85
        /// 配对 bootstrap 次数下限（P2 指标表：≥ 10,000）。
        public static let bootstrapIterations = ASREvaluation.minimumBootstrapIterations
    }

    public enum Decision: String, Sendable, Codable {
        case `continue`
        case stop
    }

    public enum Rule: String, Sendable, Codable, CaseIterable {
        case appleEnglishMarginalGain
        case segmentedVersusContinuous
        case safetyRegression
        case harmFixRatio
        case confidenceDiscrimination
    }

    public enum Status: String, Sendable, Codable {
        case passed
        case triggered
        /// 只有参考性证据（如逐句 oracle），不足以支持动作；维持现状。
        case advisory
        /// 缺证据，按 fail-closed 取保守动作。
        case notEvaluated
    }

    public enum Action: String, Sendable, Codable {
        case keepAppleEnglish
        case dropAppleEnglish
        /// 证据不足：不删除，待融合模块给出 token 级证据后再判。
        case awaitTokenLevelEvidence
        case allowSameSegmentDecoding
        case skipSameSegmentDecoding
        case continueFusion
        case terminateFusion
        case allowAutomaticRewrite
        case forbidAutomaticRewrite
        case allowTokenLevelRewrite
        /// 不做逐词自动改写，只保留不一致提示。
        case disagreementHintsOnly
    }

    public struct Finding: Sendable, Equatable, Codable {
        public var rule: Rule
        public var status: Status
        public var action: Action
        public var reasons: [String]

        public init(rule: Rule, status: Status, action: Action, reasons: [String]) {
            self.rule = rule
            self.status = status
            self.action = action
            self.reasons = reasons
        }
    }

    /// 规则 1 的 token 级证据（本评测层不做 token 级对齐：调用方给数，或用 `fusionAblation` 从两条融合输出计算）。
    public struct TokenLevelEvidence: Sendable, Equatable, Codable {
        /// 边际增益点估计（百分点）= 不含该引擎的 MER − 含该引擎的 MER（正 = 该引擎有用）。
        public var gainPercentagePoints: Double
        /// 边际增益 95% CI 下界（百分点）；nil = 未给 → 无法证明增益。
        public var gainLowerBoundPercentagePoints: Double?
        /// 含该引擎的融合输出相对主轨的 harm / fix 计数；nil = 未给 → 无法证明改写安全。
        public var harms: Int?
        public var fixes: Int?
        /// 语种标签（弃权依据）是否取自主轨；取自参考 = 信息泄漏，证据作废。
        public var languageFromPrimary: Bool
        /// 证据性质与来源（如「fusion:v1 消融，60 句」），原样进理由。
        public var source: String

        public init(gainPercentagePoints: Double, gainLowerBoundPercentagePoints: Double?, harms: Int?, fixes: Int?,
                    languageFromPrimary: Bool, source: String) {
            self.gainPercentagePoints = gainPercentagePoints
            self.gainLowerBoundPercentagePoints = gainLowerBoundPercentagePoints
            self.harms = harms
            self.fixes = fixes
            self.languageFromPrimary = languageFromPrimary
            self.source = source
        }

        /// 由报告中两条融合输出（含/不含该引擎）计算：增益与 CI 取配对 bootstrap 的 micro 口径（不含 − 含），
        /// harm/fix 取「含该引擎」输出相对主轨。任一系统未参与比较或无共同计分句 → nil。
        public static func fusionAblation(report: ASREvaluation.Report, primaryEngineID: String, withEngineID: String,
                                          withoutEngineID: String, languageFromPrimary: Bool,
                                          iterations: Int = Thresholds.bootstrapIterations,
                                          seed: UInt64 = ASREvaluation.defaultBootstrapSeed) -> TokenLevelEvidence? {
            guard let bootstrap = report.pairedBootstrap(withoutEngineID, withEngineID, iterations: iterations, seed: seed),
                  let harmFix = ASREvaluation.harmFix(report: report, primaryEngineID: primaryEngineID,
                                                      candidateEngineID: withEngineID) else { return nil }
            return TokenLevelEvidence(
                gainPercentagePoints: bootstrap.microDifference * 100,
                gainLowerBoundPercentagePoints: bootstrap.microLower * 100,
                harms: harmFix.harms, fixes: harmFix.fixes, languageFromPrimary: languageFromPrimary,
                source: "融合消融 \(withoutEngineID) − \(withEngineID)，\(bootstrap.utteranceCount) 句，"
                    + "bootstrap \(bootstrap.iterations) 次")
        }
    }

    /// 调用方指定参与判定的系统（engineID 与报告一致）。
    public struct Configuration: Sendable, Equatable, Codable {
        /// 主轨（默认交付的单模）。
        public var primaryEngineID: String
        /// Apple 英文识别器（如 `classic:en-US`）；nil = 未跑（只影响逐句参考信息）。
        public var appleEnglishEngineID: String?
        /// Apple-en 的 token 级证据；nil = 只有逐句证据 → 规则 1 只出 advisory。
        public var appleEnglishTokenLevelEvidence: TokenLevelEvidence?
        /// 同 VAD 切段解码的系统与其连续解码对照（如 Apple-zh 两种跑法）。
        public var segmentedEngineID: String?
        public var continuousEngineID: String?
        /// 候选/融合系统：规则 3、4 的被检对象；同时从规则 1 的单模逐句 oracle 池中剔除。
        public var candidateEngineIDs: [String]
        public var bootstrapIterations: Int
        public var bootstrapSeed: UInt64

        public init(primaryEngineID: String, appleEnglishEngineID: String? = nil,
                    appleEnglishTokenLevelEvidence: TokenLevelEvidence? = nil, segmentedEngineID: String? = nil,
                    continuousEngineID: String? = nil, candidateEngineIDs: [String] = [],
                    bootstrapIterations: Int = Thresholds.bootstrapIterations,
                    bootstrapSeed: UInt64 = ASREvaluation.defaultBootstrapSeed) {
            self.primaryEngineID = primaryEngineID
            self.appleEnglishEngineID = appleEnglishEngineID
            self.appleEnglishTokenLevelEvidence = appleEnglishTokenLevelEvidence
            self.segmentedEngineID = segmentedEngineID
            self.continuousEngineID = continuousEngineID
            self.candidateEngineIDs = candidateEngineIDs
            self.bootstrapIterations = bootstrapIterations
            self.bootstrapSeed = bootstrapSeed
        }

        /// 去重、剔除主轨后的候选（保持调用方顺序）。
        var distinctCandidates: [String] {
            var seen = Set<String>()
            return candidateEngineIDs.filter { $0 != primaryEngineID && seen.insert($0).inserted }
        }
    }

    /// 某候选相对主轨的安全回归明细（规则 3）。
    public struct Regression: Sendable, Equatable, Codable {
        public var candidateEngineID: String
        /// 两者都已计分的 emergencyPositive 句数。
        public var emergencyPairs: Int
        /// 主轨命中急救词、候选未命中的句子。
        public var lostEmergencyUtteranceIDs: [String]
        /// 两者都已计分的 negation 句中的否定区间数。
        public var negationSpans: Int
        /// 主轨原样保留、候选未保留的否定区间数及所在句。
        public var lostNegationSpans: Int
        public var lostNegationUtteranceIDs: [String]

        public var hasRegression: Bool { !lostEmergencyUtteranceIDs.isEmpty || lostNegationSpans > 0 }
        public var hasEvidence: Bool { emergencyPairs > 0 && negationSpans > 0 }
    }

    /// 急救结论的样本量充分性（规则 3 附注）。
    public struct EmergencySampleAdequacy: Sendable, Equatable, Codable {
        /// 急救阳性配对样本数：有被检候选时取各候选与主轨共同计分的最小值，否则取主轨已计分的阳性句数。
        public var positiveSamples: Int
        public var minimumForSafetyClaim: Int
        /// 零漏报时漏报率的单侧 95% 置信上限 1 − 0.05^(1/n)；n = 0 → 1。
        public var missRateUpperBound: Double
        /// n < 下限：只能发现回归、不能证明安全。
        public var canOnlyDetectRegressions: Bool
    }

    /// 理由中最多列出的句子 ID 数。
    static let listedUtteranceLimit = 5

    // MARK: - 判定结果

    public var decision: Decision
    public var configuration: Configuration
    public var findings: [Finding]
    /// 规则 2 的 bootstrap（未评估 → nil）。
    public var segmentedVersusContinuous: ASREvaluation.PairedBootstrap?
    /// 规则 3 的逐候选明细（参与的候选才有）。
    public var regressions: [Regression]
    /// 规则 4 的逐候选 harm/fix（参与的候选才有）。
    public var harmFixByCandidate: [ASREvaluation.HarmFix]
    public var emergencySampleAdequacy: EmergencySampleAdequacy
    /// 是否放行逐词自动改写：规则 3 判继续，且规则 4、5 均通过。
    public var automaticRewriteAllowed: Bool

    public func finding(_ rule: Rule) -> Finding? { findings.first(where: { $0.rule == rule }) }

    public static func evaluate(report: ASREvaluation.Report, configuration: Configuration) -> ASREvaluationVerdict {
        let appleEnglish = appleEnglishFinding(report: report, configuration: configuration)
        let segmentation = segmentationFinding(report: report, configuration: configuration)
        let safety = safetyFinding(report: report, configuration: configuration)
        let rewrite = harmFixFinding(report: report, configuration: configuration)
        let discrimination = confidenceFinding(report: report)
        let adequacy = measureEmergencySampleAdequacy(report: report, configuration: configuration,
                                                      regressions: safety.regressions)
        var finalSafety = safety.finding
        finalSafety.reasons.append(adequacyNote(adequacy))
        let decision: Decision = finalSafety.action == .continueFusion ? .continue : .stop
        return ASREvaluationVerdict(
            decision: decision,
            configuration: configuration,
            findings: [appleEnglish, segmentation.finding, finalSafety, rewrite.finding, discrimination],
            segmentedVersusContinuous: segmentation.bootstrap,
            regressions: safety.regressions,
            harmFixByCandidate: rewrite.harmFix,
            emergencySampleAdequacy: adequacy,
            automaticRewriteAllowed: decision == .continue && rewrite.finding.status == .passed
                && discrimination.status == .passed)
    }

    // MARK: - 规则 1

    static func appleEnglishFinding(report: ASREvaluation.Report, configuration: Configuration) -> Finding {
        let sentenceLevel = sentenceLevelNote(report: report, configuration: configuration)
        let engine = configuration.appleEnglishEngineID.map { "Apple-en（\($0)）" } ?? "Apple-en"
        func advisory(_ reason: String) -> Finding {
            Finding(rule: .appleEnglishMarginalGain, status: .advisory, action: .awaitTokenLevelEvidence,
                    reasons: [reason + "——证据不足（advisory），不建议删除 \(engine)；"
                              + "逐句 oracle 只能整句择一，会系统性低估只在句内少数英文词上起作用的引擎，"
                              + "去留须由融合模块提供 token 级证据（语种取自主轨）",
                              sentenceLevel])
        }
        guard let evidence = configuration.appleEnglishTokenLevelEvidence else {
            return advisory("未提供 token 级证据")
        }
        guard evidence.languageFromPrimary else {
            return advisory("token 级证据的语种标签未取自主轨（取自参考即信息泄漏），不可用于去留")
        }
        guard evidence.gainPercentagePoints.isFinite else {
            return advisory("token 级证据无效（增益非有限值）")
        }
        let maximumRatio = Thresholds.maximumHarmFixRatio
        let lowerThreshold = Thresholds.appleEnglishGainLowerBoundPercentagePoints
        var failures: [String] = []
        var lowerText = "—"
        if let lower = evidence.gainLowerBoundPercentagePoints, lower.isFinite {
            lowerText = ASREvaluation.formatSigned(lower, digits: 2)
            if !(lower > lowerThreshold) {
                failures.append("CI 下界 \(lowerText) ≤ \(ASREvaluation.formatFixed(lowerThreshold, digits: 2))，增益不显著")
            }
        } else {
            failures.append("未提供边际增益的 95% CI 下界，无法证明增益")
        }
        var harmFixText = "—"
        if let harms = evidence.harms, let fixes = evidence.fixes {
            harmFixText = "\(harms)/\(fixes)"
            if Double(harms) > maximumRatio * Double(fixes) {
                failures.append("harm/fix \(harmFixText) > \(ASREvaluation.formatFixed(maximumRatio, digits: 2))")
            }
        } else {
            failures.append("未提供 harm/fix，无法证明改写安全")
        }
        let detail = "\(engine) token 级边际增益 \(ASREvaluation.formatSigned(evidence.gainPercentagePoints, digits: 2)) "
            + "个百分点（95% CI 下界 \(lowerText)；harm/fix \(harmFixText)；\(evidence.source)）"
        if failures.isEmpty {
            return Finding(rule: .appleEnglishMarginalGain, status: .passed, action: .keepAppleEnglish,
                           reasons: [detail + "：harm/fix ≤ \(ASREvaluation.formatFixed(maximumRatio, digits: 2)) "
                                     + "且 CI 下界 > 0，保留 \(engine)", sentenceLevel])
        }
        return Finding(rule: .appleEnglishMarginalGain, status: .triggered, action: .dropAppleEnglish,
                       reasons: [detail + "：" + failures.joined(separator: "；") + "——建议删除 \(engine)", sentenceLevel])
    }

    /// 逐句 oracle 增益——只作参考信息，不参与规则 1 的动作。
    static func sentenceLevelNote(report: ASREvaluation.Report, configuration: Configuration) -> String {
        guard let apple = configuration.appleEnglishEngineID else { return "逐句参考：未指定 Apple-en 系统" }
        guard report.includedEngineIDs.contains(apple) else {
            return "逐句参考：\(apple) 未参与比较（\(skipDescription(report, apple))）"
        }
        let candidates = Set(configuration.candidateEngineIDs)
        let pool = report.includedEngineIDs.filter { $0 == apple || !candidates.contains($0) }
        guard let gain = report.oracleGain(of: apple, pool: pool), let points = gain.microGainPercentagePoints,
              let withoutRate = gain.withoutSystem.micro, let withRate = gain.withSystem.micro else {
            return "逐句参考：单模池中没有可与 \(apple) 对照的其他系统"
        }
        return "逐句参考：\(apple) 逐句 oracle 增益 \(ASREvaluation.formatFixed(points, digits: 2)) 个百分点"
            + "（不含 \(ASREvaluation.formatPercent(withoutRate)) → 含 \(ASREvaluation.formatPercent(withRate))，"
            + "\(gain.withSystem.utteranceCount) 句，池 \(gain.pool.joined(separator: ", "))；只作参考，不据此删除）"
    }

    // MARK: - 规则 2

    static func segmentationFinding(report: ASREvaluation.Report, configuration: Configuration)
        -> (finding: Finding, bootstrap: ASREvaluation.PairedBootstrap?) {
        func notEvaluated(_ reason: String) -> (finding: Finding, bootstrap: ASREvaluation.PairedBootstrap?) {
            (Finding(rule: .segmentedVersusContinuous, status: .notEvaluated, action: .skipSameSegmentDecoding,
                     reasons: [reason + "——切段无证据，按止损不做同段解码"]), nil)
        }
        guard let segmented = configuration.segmentedEngineID, let continuous = configuration.continuousEngineID,
              segmented != continuous else {
            return notEvaluated("未指定切段/连续两个不同系统")
        }
        for engineID in [segmented, continuous] where !report.includedEngineIDs.contains(engineID) {
            return notEvaluated("\(engineID) 未参与比较（\(skipDescription(report, engineID))）")
        }
        guard let bootstrap = report.pairedBootstrap(segmented, continuous, iterations: configuration.bootstrapIterations,
                                                     seed: configuration.bootstrapSeed) else {
            return notEvaluated("\(segmented) 与 \(continuous) 没有共同计分的句子")
        }
        let detail = "切段（\(segmented)）− 连续（\(continuous)）逐句 MER 差均值 "
            + "\(ASREvaluation.formatSigned(bootstrap.meanDifference * 100, digits: 2)) 个百分点，"
            + "95% CI [\(ASREvaluation.formatSigned(bootstrap.lower * 100, digits: 2)), "
            + "\(ASREvaluation.formatSigned(bootstrap.upper * 100, digits: 2))]"
            + "（\(bootstrap.utteranceCount) 句，bootstrap \(bootstrap.iterations) 次，种子 \(bootstrap.seed)）"
        if bootstrap.lower > Thresholds.segmentedWorseLowerBound {
            return (Finding(rule: .segmentedVersusContinuous, status: .triggered, action: .skipSameSegmentDecoding,
                            reasons: [detail + "；CI 下界 > 0，切段显著更差：不做同段解码"]), bootstrap)
        }
        return (Finding(rule: .segmentedVersusContinuous, status: .passed, action: .allowSameSegmentDecoding,
                        reasons: [detail + "；CI 下界 ≤ 0，切段未显著劣于连续：同段解码可继续评估"]), bootstrap)
    }

    // MARK: - 规则 3

    static func safetyFinding(report: ASREvaluation.Report, configuration: Configuration)
        -> (finding: Finding, regressions: [Regression]) {
        let primary = configuration.primaryEngineID
        func notEvaluated(_ reasons: [String], _ regressions: [Regression]) -> (finding: Finding, regressions: [Regression]) {
            (Finding(rule: .safetyRegression, status: .notEvaluated, action: .terminateFusion,
                     reasons: reasons + ["急救/否定回归缺证据——按止损终止多模融合（缺证据不得判继续）"]), regressions)
        }
        guard report.includedEngineIDs.contains(primary) else {
            return notEvaluated(["主轨 \(primary) 未参与比较（\(skipDescription(report, primary))）"], [])
        }
        let candidates = configuration.distinctCandidates
        guard !candidates.isEmpty else {
            return notEvaluated(["未指定候选/融合系统"], [])
        }
        var reasons: [String] = []
        var regressions: [Regression] = []
        var missingEvidence = false
        for candidate in candidates {
            guard report.includedEngineIDs.contains(candidate) else {
                missingEvidence = true
                reasons.append("候选 \(candidate) 未参与比较（\(skipDescription(report, candidate))）")
                continue
            }
            let regression = Self.regression(of: candidate, against: primary, in: report)
            regressions.append(regression)
            if !regression.hasEvidence {
                missingEvidence = true
                reasons.append("候选 \(candidate)：与主轨共同计分的 emergencyPositive 句 \(regression.emergencyPairs) 句、"
                               + "negation 否定区间 \(regression.negationSpans) 处——缺任一类即无法判定")
            }
            if regression.hasRegression {
                reasons.append("候选 \(candidate) 相对主轨 \(primary)：急救词命中丢失 "
                               + "\(regression.lostEmergencyUtteranceIDs.count) 句\(listed(regression.lostEmergencyUtteranceIDs))，"
                               + "否定丢失 \(regression.lostNegationSpans) 处\(listed(regression.lostNegationUtteranceIDs))")
            } else if regression.hasEvidence {
                reasons.append("候选 \(candidate) 相对主轨 \(primary)：急救 \(regression.emergencyPairs) 句、"
                               + "否定 \(regression.negationSpans) 处均无回归")
            }
        }
        let regressionCount = regressions.reduce(0) { $0 + $1.lostEmergencyUtteranceIDs.count + $1.lostNegationSpans }
        if regressionCount > Thresholds.tolerableSafetyRegressions {
            return (Finding(rule: .safetyRegression, status: .triggered, action: .terminateFusion,
                            reasons: reasons + ["出现 \(regressionCount) 处急救/否定回归：终止多模融合，回到最佳单模 + 热词 + 人工确认"]),
                    regressions)
        }
        if missingEvidence { return notEvaluated(reasons, regressions) }
        return (Finding(rule: .safetyRegression, status: .passed, action: .continueFusion,
                        reasons: reasons + ["零急救/否定回归：多模融合可继续进入 P1"]), regressions)
    }

    static func regression(of candidate: String, against primary: String,
                           in report: ASREvaluation.Report) -> Regression {
        var result = Regression(candidateEngineID: candidate, emergencyPairs: 0, lostEmergencyUtteranceIDs: [],
                                negationSpans: 0, lostNegationSpans: 0, lostNegationUtteranceIDs: [])
        for detail in report.utterances {
            guard let base = detail.score(for: primary), let other = detail.score(for: candidate),
                  base.isScored, other.isScored else { continue }
            if detail.has(.emergencyPositive) {
                result.emergencyPairs += 1
                if base.emergencyMatch == true && other.emergencyMatch != true {
                    result.lostEmergencyUtteranceIDs.append(detail.utteranceID)
                }
            }
            guard detail.has(.negation) else { continue }
            var lostHere = 0
            for (index, span) in detail.protectedSpans.enumerated() where span.kind == .negation {
                result.negationSpans += 1
                if !base.isHarmed(spanIndex: index) && other.isHarmed(spanIndex: index) { lostHere += 1 }
            }
            if lostHere > 0 {
                result.lostNegationSpans += lostHere
                result.lostNegationUtteranceIDs.append(detail.utteranceID)
            }
        }
        return result
    }

    // MARK: - 规则 4

    static func harmFixFinding(report: ASREvaluation.Report, configuration: Configuration)
        -> (finding: Finding, harmFix: [ASREvaluation.HarmFix]) {
        let primary = configuration.primaryEngineID
        let maximumRatio = Thresholds.maximumHarmFixRatio
        let limit = ASREvaluation.formatFixed(maximumRatio, digits: 2)
        func notEvaluated(_ reasons: [String], _ list: [ASREvaluation.HarmFix]) -> (finding: Finding, harmFix: [ASREvaluation.HarmFix]) {
            (Finding(rule: .harmFixRatio, status: .notEvaluated, action: .forbidAutomaticRewrite,
                     reasons: reasons + ["harm/fix 缺证据——不得放行自动改写"]), list)
        }
        guard report.includedEngineIDs.contains(primary) else {
            return notEvaluated(["主轨 \(primary) 未参与比较（\(skipDescription(report, primary))）"], [])
        }
        let candidates = configuration.distinctCandidates
        guard !candidates.isEmpty else { return notEvaluated(["未指定候选/融合系统"], []) }
        var reasons: [String] = []
        var list: [ASREvaluation.HarmFix] = []
        var exceeded = false
        var missingEvidence = false
        for candidate in candidates {
            guard let harmFix = ASREvaluation.harmFix(report: report, primaryEngineID: primary,
                                                      candidateEngineID: candidate) else {
                missingEvidence = true
                reasons.append("候选 \(candidate) 未参与比较（\(skipDescription(report, candidate))）")
                continue
            }
            list.append(harmFix)
            let detail = "候选 \(candidate) 相对主轨 \(primary)（\(harmFix.utteranceCount) 句）：fix \(harmFix.fixes)"
                + "（词 \(harmFix.tokenFixes) + 插入 \(harmFix.insertionFixes)），harm \(harmFix.harms)"
                + "（词 \(harmFix.tokenHarms) + 插入 \(harmFix.insertionHarms)），harm/fix \(ratioText(harmFix))"
            if harmFix.exceeds(maximumRatio) {
                exceeded = true
                reasons.append(detail + " > \(limit)")
            } else if harmFix.fixes == 0 {
                missingEvidence = true
                reasons.append(detail + "：无任何修正，harm/fix 无定义")
            } else {
                reasons.append(detail + " ≤ \(limit)")
            }
        }
        if exceeded {
            return (Finding(rule: .harmFixRatio, status: .triggered, action: .forbidAutomaticRewrite,
                            reasons: reasons + ["harm/fix 超过 \(limit)：不得放行自动改写"]), list)
        }
        if missingEvidence { return notEvaluated(reasons, list) }
        return (Finding(rule: .harmFixRatio, status: .passed, action: .allowAutomaticRewrite,
                        reasons: reasons + ["harm/fix 均 ≤ \(limit)：本判据不阻拦自动改写"]), list)
    }

    static func ratioText(_ harmFix: ASREvaluation.HarmFix) -> String {
        if let ratio = harmFix.harmFixRatio { return ASREvaluation.formatFixed(ratio, digits: 2) }
        return harmFix.harms > 0 ? "∞" : "—"
    }

    // MARK: - 规则 5

    static func confidenceFinding(report: ASREvaluation.Report) -> Finding {
        let minimum = Thresholds.minimumConfidenceAUROC
        let limit = ASREvaluation.formatFixed(minimum, digits: 2)
        var lines: [String] = []
        var qualified: [String] = []
        for system in report.systems where system.isIncluded {
            guard let auroc = system.confidence.auroc else { continue }
            lines.append("\(system.engineID) AUROC \(ASREvaluation.formatFixed(auroc, digits: 3))"
                         + "（\(system.confidence.sampleCount) 词，错 \(system.confidence.incorrectCount)）")
            if auroc >= minimum { qualified.append(system.engineID) }
        }
        guard !lines.isEmpty else {
            return Finding(rule: .confidenceDiscrimination, status: .notEvaluated, action: .disagreementHintsOnly,
                           reasons: ["没有可用置信源（无逐词置信度，或对/错单类）——不做逐词自动改写，只保留不一致提示"])
        }
        guard !qualified.isEmpty else {
            return Finding(rule: .confidenceDiscrimination, status: .triggered, action: .disagreementHintsOnly,
                           reasons: lines + ["所有置信源 AUROC < \(limit)：不做逐词自动改写，只保留不一致提示"])
        }
        return Finding(rule: .confidenceDiscrimination, status: .passed, action: .allowTokenLevelRewrite,
                       reasons: lines + ["可用置信源（AUROC ≥ \(limit)）：\(qualified.joined(separator: ", "))"])
    }

    // MARK: - 急救样本量附注

    /// 零漏报时漏报率的单侧置信上限：1 − α^(1/n)（Clopper–Pearson 零事件精确式；零事件法则 ≈ 3/n）。n ≤ 0 → 1。
    public static func zeroEventMissRateUpperBound(samples: Int,
                                                   alpha: Double = Thresholds.emergencyMissRateAlpha) -> Double {
        guard samples > 0 else { return 1 }
        return 1 - pow(alpha, 1 / Double(samples))
    }

    static func measureEmergencySampleAdequacy(report: ASREvaluation.Report, configuration: Configuration,
                                               regressions: [Regression]) -> EmergencySampleAdequacy {
        let samples = regressions.map { $0.emergencyPairs }.min()
            ?? report.system(configuration.primaryEngineID)?.emergency.positiveCount ?? 0
        let minimum = Thresholds.minimumEmergencyPositiveSamples
        return EmergencySampleAdequacy(positiveSamples: samples, minimumForSafetyClaim: minimum,
                                       missRateUpperBound: zeroEventMissRateUpperBound(samples: samples),
                                       canOnlyDetectRegressions: samples < minimum)
    }

    static func adequacyNote(_ adequacy: EmergencySampleAdequacy) -> String {
        let bound = ASREvaluation.formatFixed(adequacy.missRateUpperBound * 100, digits: 1) + "%"
        let samples = "急救阳性样本 n=\(adequacy.positiveSamples)"
        if adequacy.canOnlyDetectRegressions {
            return "\(samples) < \(adequacy.minimumForSafetyClaim)：急救结论只能发现回归、不能证明安全"
                + "（零漏报时漏报率 95% 置信上限 ≈ \(bound)）"
        }
        return "\(samples) ≥ \(adequacy.minimumForSafetyClaim)（零漏报时漏报率 95% 置信上限 ≈ \(bound)）"
    }

    // MARK: - 辅助

    private static func skipDescription(_ report: ASREvaluation.Report, _ engineID: String) -> String {
        guard let system = report.system(engineID) else { return "报告中无此系统" }
        return system.skipReason.map { "已跳过：\($0)" } ?? "参与中"
    }

    private static func listed(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "" }
        let shown = ids.prefix(listedUtteranceLimit).joined(separator: ", ")
        return ids.count > listedUtteranceLimit ? "（\(shown) 等 \(ids.count) 句）" : "（\(shown)）"
    }
}
