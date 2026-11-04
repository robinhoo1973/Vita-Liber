import Foundation

/// 杀手实验报告（round3 §8 P0-A 产出清单）：各系统 MER（micro/macro）、按标签分层 MER、逐句 oracle 与
/// 各系统 oracle 增益、保护类伤害、BR-012 急救召回/误报、延迟 p50/p95、峰值内存、逐词置信度区分度（AUROC）。
///
/// **逐句 oracle**：每句在系统池内取错误数最小者（「任一系统整句对就算对」的整句上界）。
/// **token 级 oracle**（逐列取对）依赖融合层的多假设对齐，本期不做——见 round3 §6.1。
/// **局限**：逐句 oracle 只能整句择一，会**系统性低估**只在句内少数词上起作用的引擎（如混说句里只认得
/// 几个英文词的 Apple-en：模拟中逐句增益 0.00pt，token 级融合仍 6.53% → 5.63%）。因此逐句 oracle 增益
/// 只作参考，引擎去留由 `ASREvaluationVerdict` 只凭调用方提供的 token 级证据判定。
///
/// 计分口径：`failed` 按空假设计分（全删除）；`skipped` 不计分；系统级跳过（`skipReason`）的系统不进任何比较。
extension ASREvaluation {

    // MARK: - 汇总值类型

    /// 一组句子上的 MER 汇总。
    public struct RateSummary: Sendable, Equatable, Codable {
        public var utteranceCount: Int
        public var referenceTokenCount: Int
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        /// 语料级 MER：Σ错误 / Σ参考 token；无句 → nil。
        public var micro: Double?
        /// 逐句 MER 的算术均值；无句 → nil。
        public var macro: Double?

        public init(utteranceCount: Int, referenceTokenCount: Int, substitutions: Int, deletions: Int,
                    insertions: Int, micro: Double?, macro: Double?) {
            self.utteranceCount = utteranceCount
            self.referenceTokenCount = referenceTokenCount
            self.substitutions = substitutions
            self.deletions = deletions
            self.insertions = insertions
            self.micro = micro
            self.macro = macro
        }

        public var errorCount: Int { substitutions + deletions + insertions }
        public static let empty = RateSummary(utteranceCount: 0, referenceTokenCount: 0, substitutions: 0,
                                              deletions: 0, insertions: 0, micro: nil, macro: nil)
    }

    public struct TagCount: Sendable, Equatable, Codable {
        public var tag: Tag
        public var count: Int
    }

    public struct TagRate: Sendable, Equatable, Codable {
        public var tag: Tag
        public var rate: RateSummary
    }

    public struct ClassHarmCount: Sendable, Equatable, Codable {
        /// 参考中的保护区间数（该系统已计分的句子内）。
        public var total: Int
        /// 未原样保留的区间数。
        public var harmed: Int

        public init(total: Int = 0, harmed: Int = 0) {
            self.total = total
            self.harmed = harmed
        }
    }

    public struct ProtectionSummary: Sendable, Equatable, Codable {
        public var numeric: ClassHarmCount
        public var negation: ClassHarmCount
        public var protectedTerm: ClassHarmCount

        public init(numeric: ClassHarmCount = .init(), negation: ClassHarmCount = .init(),
                    protectedTerm: ClassHarmCount = .init()) {
            self.numeric = numeric
            self.negation = negation
            self.protectedTerm = protectedTerm
        }

        public func count(for kind: ProtectedKind) -> ClassHarmCount {
            switch kind {
            case .numeric: return numeric
            case .negation: return negation
            case .protectedTerm: return protectedTerm
            }
        }
    }

    /// BR-012 急救词（`EmergencyKeywordRules.match`）在各系统假设上的召回与误报。
    public struct EmergencySummary: Sendable, Equatable, Codable {
        /// emergencyPositive 已计分句数 / 其中假设命中数 / 其中参考自身命中数（词表覆盖自检）。
        public var positiveCount: Int
        public var positiveDetected: Int
        public var positiveReferenceMatched: Int
        /// emergencyNegative 已计分句数 / 其中假设命中数（误报）/ 其中参考自身命中数（词表本身的误触发）。
        public var negativeCount: Int
        public var negativeFlagged: Int
        public var negativeReferenceMatched: Int
        /// 召回 = 假设命中 / 阳性句；无阳性句 → nil。
        public var recall: Double?
        /// 误报率 = 假设命中 / 阴性对照句；无阴性句 → nil。
        public var falseAlarmRate: Double?

        public static let empty = EmergencySummary(positiveCount: 0, positiveDetected: 0, positiveReferenceMatched: 0,
                                                   negativeCount: 0, negativeFlagged: 0, negativeReferenceMatched: 0,
                                                   recall: nil, falseAlarmRate: nil)
    }

    /// 延迟（毫秒，只统计 recognized 句）：最近秩 p50/p95、最大值、首句（冷启动）。
    public struct LatencySummary: Sendable, Equatable, Codable {
        public var sampleCount: Int
        public var p50: Double?
        public var p95: Double?
        public var maximum: Double?
        public var first: Double?

        public static let empty = LatencySummary(sampleCount: 0, p50: nil, p95: nil, maximum: nil, first: nil)
    }

    public struct SystemSummary: Sendable, Equatable, Codable {
        public var engineID: String
        public var skipReason: String?
        public var notes: String?
        public var recognizedCount: Int
        public var failedCount: Int
        public var skippedCount: Int
        public var overall: RateSummary
        public var byTag: [TagRate]
        public var protection: ProtectionSummary
        public var emergency: EmergencySummary
        public var latency: LatencySummary
        public var peakMemoryBytes: Int64?
        /// 逐词置信度区分度（无置信度样本 → 样本数 0、AUROC nil）。
        public var confidence: ConfidenceDiscrimination

        public var isIncluded: Bool { skipReason == nil }

        public func rate(for tag: Tag) -> RateSummary {
            byTag.first(where: { $0.tag == tag })?.rate ?? .empty
        }
    }

    /// 某保护区间未被原样保留：`spanIndex` 指向所属 `UtteranceDetail.protectedSpans`，`observed` 为对齐到的假设片段。
    public struct ProtectedHarm: Sendable, Equatable, Codable {
        public var spanIndex: Int
        public var observed: String
    }

    /// 一个系统在一句上的计分。
    public struct SystemUtteranceScore: Sendable, Equatable, Codable {
        public var engineID: String
        public var status: UtteranceStatus
        /// recognized 的原文；failed/skipped 为 nil。
        public var hypothesis: String?
        public var reason: String?
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        /// 本句 MER；skipped → nil。
        public var rate: Double?
        /// `EmergencyKeywordRules.match(假设)`；skipped → nil（failed 按空串 → false）。
        public var emergencyMatch: Bool?
        public var harms: [ProtectedHarm]
        public var latencyMilliseconds: Double?
        public var peakMemoryBytes: Int64?
        /// 带置信度的假设 token 样本（对 = 匹配；错 = 替换/插入）；结果不带逐词置信度时为空。
        public var confidenceSamples: [ConfidenceSample]

        public var errorCount: Int { substitutions + deletions + insertions }
        public var isScored: Bool { status != .skipped }

        public func isHarmed(spanIndex: Int) -> Bool { harms.contains(where: { $0.spanIndex == spanIndex }) }
    }

    public struct UtteranceDetail: Sendable, Equatable, Codable {
        public var utteranceID: String
        /// 去重后按 `Tag.allCases` 次序。
        public var tags: [Tag]
        public var reference: String
        public var referenceTokenCount: Int
        public var referenceEmergencyMatch: Bool
        public var protectedSpans: [ProtectedSpan]
        /// 参与比较的系统（按 engineID 排序）。
        public var systems: [SystemUtteranceScore]
        /// 逐句 oracle（全体参与系统）：最小错误数、对应 MER 与达成者；无系统计分 → nil / 空。
        public var oracleErrorCount: Int?
        public var oracleRate: Double?
        public var oracleEngineIDs: [String]

        public func score(for engineID: String) -> SystemUtteranceScore? {
            systems.first(where: { $0.engineID == engineID })
        }

        public func has(_ tag: Tag) -> Bool { tags.contains(tag) }
    }

    public struct OracleSummary: Sendable, Equatable, Codable {
        /// 系统池（按 engineID 排序）。
        public var engineIDs: [String]
        public var rate: RateSummary
    }

    /// 某系统的逐句 oracle 增益 = 不含它的逐句 oracle MER − 含它的逐句 oracle MER（百分点，≥ 0）。
    /// 统计范围：池中**除它以外**至少一个系统已计分的句子（不含它的 oracle 才有定义）。
    /// 只作参考：会低估只在句内少数词上起作用的引擎，不得单独据此删除引擎（见文件头「局限」）。
    public struct OracleGain: Sendable, Equatable, Codable {
        public var engineID: String
        public var pool: [String]
        public var withSystem: RateSummary
        public var withoutSystem: RateSummary
        public var microGainPercentagePoints: Double?
        public var macroGainPercentagePoints: Double?
    }

    public struct Report: Sendable, Equatable, Codable {
        public var schemaVersion: Int
        public var utteranceCount: Int
        public var tagCounts: [TagCount]
        /// 全部系统（含系统级跳过者），按 engineID 排序。
        public var systems: [SystemSummary]
        /// 全体参与系统的逐句 oracle；无参与系统 → nil。
        public var oracle: OracleSummary?
        /// 各参与系统在全体池中的 oracle 增益（留一法）。
        public var oracleGains: [OracleGain]
        public var utterances: [UtteranceDetail]
        public var warnings: [String]

        public static let schemaVersion = 1

        public func system(_ engineID: String) -> SystemSummary? {
            systems.first(where: { $0.engineID == engineID })
        }

        /// 参与比较的系统（未被系统级跳过），按 engineID 排序。
        public var includedEngineIDs: [String] {
            systems.filter { $0.isIncluded }.map { $0.engineID }
        }

        public func oracleGain(of engineID: String) -> OracleGain? {
            oracleGains.first(where: { $0.engineID == engineID })
        }

        /// 逐句 oracle（池可自选，如剔除融合系统只看单模）；池内无系统计分的句子不计入。
        public func oracleRate(pool: [String]) -> RateSummary {
            let members = Set(pool)
            var accumulator = RateAccumulator()
            for detail in utterances {
                let candidates = detail.systems.filter { $0.isScored && members.contains($0.engineID) }
                if let best = ASREvaluation.bestScore(candidates) {
                    accumulator.add(best, referenceLength: detail.referenceTokenCount)
                }
            }
            return accumulator.summary
        }

        /// `engineID` 在 `pool`（缺省 = 全体参与系统）中的 oracle 增益；它不在池中、未参与或池中别无他者 → nil。
        public func oracleGain(of engineID: String, pool: [String]?) -> OracleGain? {
            let members = (pool ?? includedEngineIDs).filter { includedEngineIDs.contains($0) }
            let ordered = Array(Set(members)).sorted()
            let others = Set(ordered.filter { $0 != engineID })
            guard ordered.contains(engineID), !others.isEmpty else { return nil }
            var withTarget = RateAccumulator()
            var withoutTarget = RateAccumulator()
            for detail in utterances {
                let rest = detail.systems.filter { $0.isScored && others.contains($0.engineID) }
                guard let bestWithout = ASREvaluation.bestScore(rest) else { continue }
                let target = detail.systems.filter { $0.isScored && $0.engineID == engineID }
                let bestWith = ASREvaluation.bestScore(rest + target) ?? bestWithout
                withoutTarget.add(bestWithout, referenceLength: detail.referenceTokenCount)
                withTarget.add(bestWith, referenceLength: detail.referenceTokenCount)
            }
            let withSummary = withTarget.summary
            let withoutSummary = withoutTarget.summary
            return OracleGain(
                engineID: engineID, pool: ordered, withSystem: withSummary, withoutSystem: withoutSummary,
                microGainPercentagePoints: ASREvaluation.percentagePointGap(withoutSummary.micro, withSummary.micro),
                macroGainPercentagePoints: ASREvaluation.percentagePointGap(withoutSummary.macro, withSummary.macro))
        }

        /// 两系统都已计分的逐句配对观测（可按标签限定），供 bootstrap 与回归比对。
        public func pairedObservations(_ engineA: String, _ engineB: String,
                                       restrictedTo tag: Tag? = nil) -> [PairedObservation] {
            var pairs: [PairedObservation] = []
            for detail in utterances where tag.map({ detail.has($0) }) ?? true {
                guard let a = detail.score(for: engineA), let b = detail.score(for: engineB),
                      let rateA = a.rate, let rateB = b.rate, a.isScored, b.isScored else { continue }
                pairs.append(PairedObservation(errorsA: a.errorCount, errorsB: b.errorCount,
                                               referenceLength: detail.referenceTokenCount, rateA: rateA, rateB: rateB))
            }
            return pairs
        }

        /// 两系统逐句 MER 差（A − B）的配对 bootstrap；无共同计分句 → nil。
        public func pairedBootstrap(_ engineA: String, _ engineB: String,
                                    iterations: Int = ASREvaluation.minimumBootstrapIterations,
                                    seed: UInt64 = ASREvaluation.defaultBootstrapSeed) -> PairedBootstrap? {
            ASREvaluation.pairedBootstrap(engineA: engineA, engineB: engineB,
                                          observations: pairedObservations(engineA, engineB),
                                          iterations: iterations, seed: seed)
        }
    }

    // MARK: - 报告构建

    /// 计算报告。纯函数：同（清单、结果）恒得同一报告；系统按 engineID 排序，句子按清单顺序。
    public static func evaluate(manifest: Manifest, runs: [SystemRun]) -> Report {
        var warnings: [String] = []
        var seenEngines = Set<String>()
        var uniqueRuns: [SystemRun] = []
        for run in runs {
            if seenEngines.insert(run.engineID).inserted {
                uniqueRuns.append(run)
            } else {
                warnings.append("系统 \(run.engineID) 重复提交：只取首份结果")
            }
        }
        uniqueRuns.sort { $0.engineID < $1.engineID }
        let included = uniqueRuns.filter { $0.skipReason == nil }
        let manifestIDs = Set(manifest.utterances.map { $0.utteranceID })

        var resultMaps: [String: [String: UtteranceResult]] = [:]
        for run in included {
            var map: [String: UtteranceResult] = [:]
            for result in run.results {
                if !manifestIDs.contains(result.utteranceID) {
                    warnings.append("系统 \(run.engineID) 含清单外句子 \(result.utteranceID)：已忽略")
                } else if map[result.utteranceID] != nil {
                    warnings.append("系统 \(run.engineID) 句 \(result.utteranceID) 结果重复：只取首条")
                } else {
                    map[result.utteranceID] = result
                }
            }
            resultMaps[run.engineID] = map
        }

        var details: [UtteranceDetail] = []
        for utterance in manifest.utterances {
            let referenceTokens = MixedErrorRate.tokenize(utterance.reference)
            let spans = protectedSpans(in: referenceTokens, protectedTerms: utterance.protectedTerms ?? [])
            let tags = Tag.allCases.filter { utterance.tags.contains($0) }
            let referenceMatch = EmergencyKeywordRules.match(utterance.reference)
            if tags.contains(.emergencyPositive) && !referenceMatch {
                warnings.append("句 \(utterance.utteranceID) 标 emergencyPositive，但参考文本未命中急救词表（召回分母存疑）")
            }
            let scores = included.map { run in
                score(resultMaps[run.engineID]?[utterance.utteranceID], engineID: run.engineID,
                      referenceTokens: referenceTokens, spans: spans)
            }
            let best = bestScore(scores.filter { $0.isScored })
            let oracleIDs = best.map { winner in
                scores.filter { $0.isScored && $0.errorCount == winner.errorCount }.map { $0.engineID }
            } ?? []
            details.append(UtteranceDetail(
                utteranceID: utterance.utteranceID, tags: tags, reference: utterance.reference,
                referenceTokenCount: referenceTokens.count, referenceEmergencyMatch: referenceMatch,
                protectedSpans: spans, systems: scores, oracleErrorCount: best?.errorCount,
                oracleRate: best?.rate, oracleEngineIDs: oracleIDs))
        }

        let summaries = uniqueRuns.map { summarize($0, details: details) }
        let pool = included.map { $0.engineID }
        var report = Report(
            schemaVersion: Report.schemaVersion, utteranceCount: manifest.utterances.count,
            tagCounts: Tag.allCases.map { tag in TagCount(tag: tag, count: details.filter { $0.has(tag) }.count) },
            systems: summaries, oracle: nil, oracleGains: [], utterances: details, warnings: warnings)
        if !pool.isEmpty {
            report.oracle = OracleSummary(engineIDs: pool, rate: report.oracleRate(pool: pool))
            report.oracleGains = pool.compactMap { report.oracleGain(of: $0, pool: pool) }
        }
        return report
    }

    // MARK: - 内部

    static func score(_ result: UtteranceResult?, engineID: String, referenceTokens: [MixedErrorRate.Token],
                      spans: [ProtectedSpan]) -> SystemUtteranceScore {
        guard let result, result.status != .skipped else {
            return SystemUtteranceScore(
                engineID: engineID, status: .skipped, hypothesis: nil, reason: result?.reason ?? "无结果",
                substitutions: 0, deletions: 0, insertions: 0, rate: nil, emergencyMatch: nil, harms: [],
                latencyMilliseconds: nil, peakMemoryBytes: nil, confidenceSamples: [])
        }
        let text = result.status == .recognized ? (result.hypothesis ?? "") : ""
        let measured = MixedErrorRate.align(reference: referenceTokens, hypothesis: MixedErrorRate.tokenize(text))
        var harms: [ProtectedHarm] = []
        for (index, span) in spans.enumerated() where !measured.preserves(referenceRange: span.tokenRange) {
            harms.append(ProtectedHarm(spanIndex: index, observed: measured.hypothesisText(alignedTo: span.tokenRange)))
        }
        var samples: [ConfidenceSample] = []
        if result.status == .recognized, let tokens = result.tokens, !tokens.isEmpty {
            let confidences = tokenConfidences(hypothesis: text, tokens: tokens)
            samples = confidenceSamples(alignment: measured, confidences: confidences)
        }
        return SystemUtteranceScore(
            engineID: engineID, status: result.status, hypothesis: result.status == .recognized ? text : nil,
            reason: result.reason, substitutions: measured.substitutions, deletions: measured.deletions,
            insertions: measured.insertions, rate: measured.rate, emergencyMatch: EmergencyKeywordRules.match(text),
            harms: harms, latencyMilliseconds: result.latencyMilliseconds, peakMemoryBytes: result.peakMemoryBytes,
            confidenceSamples: samples)
    }

    static func summarize(_ run: SystemRun, details: [UtteranceDetail]) -> SystemSummary {
        var counts = [UtteranceStatus: Int]()
        var overall = RateAccumulator()
        var perTag = [Tag: RateAccumulator]()
        var harmTotals = [ProtectedKind: ClassHarmCount]()
        var emergency = EmergencySummary.empty
        var latencies: [Double] = []
        var peak: Int64?
        var samples: [ConfidenceSample] = []
        for detail in details {
            guard let score = detail.score(for: run.engineID) else { continue }
            counts[score.status, default: 0] += 1
            guard score.isScored else { continue }
            overall.add(score, referenceLength: detail.referenceTokenCount)
            for tag in detail.tags { perTag[tag, default: RateAccumulator()].add(score, referenceLength: detail.referenceTokenCount) }
            for (index, span) in detail.protectedSpans.enumerated() {
                harmTotals[span.kind, default: ClassHarmCount()].total += 1
                if score.isHarmed(spanIndex: index) { harmTotals[span.kind, default: ClassHarmCount()].harmed += 1 }
            }
            tallyEmergency(&emergency, detail: detail, score: score)
            if score.status == .recognized, let milliseconds = score.latencyMilliseconds { latencies.append(milliseconds) }
            if let bytes = score.peakMemoryBytes { peak = max(peak ?? bytes, bytes) }
            samples += score.confidenceSamples
        }
        if emergency.positiveCount > 0 {
            emergency.recall = Double(emergency.positiveDetected) / Double(emergency.positiveCount)
        }
        if emergency.negativeCount > 0 {
            emergency.falseAlarmRate = Double(emergency.negativeFlagged) / Double(emergency.negativeCount)
        }
        latencies.sort()
        let firstLatency = run.results.first(where: { $0.status == .recognized && $0.latencyMilliseconds != nil })
        return SystemSummary(
            engineID: run.engineID, skipReason: run.skipReason, notes: run.notes,
            recognizedCount: counts[.recognized] ?? 0, failedCount: counts[.failed] ?? 0,
            skippedCount: run.skipReason == nil ? (counts[.skipped] ?? 0) : details.count,
            overall: overall.summary,
            byTag: Tag.allCases.map { TagRate(tag: $0, rate: perTag[$0]?.summary ?? .empty) },
            protection: ProtectionSummary(numeric: harmTotals[.numeric] ?? ClassHarmCount(),
                                          negation: harmTotals[.negation] ?? ClassHarmCount(),
                                          protectedTerm: harmTotals[.protectedTerm] ?? ClassHarmCount()),
            emergency: emergency,
            latency: LatencySummary(sampleCount: latencies.count, p50: nearestRankPercentile(latencies, 0.5),
                                    p95: nearestRankPercentile(latencies, 0.95), maximum: latencies.last,
                                    first: run.skipReason == nil ? firstLatency?.latencyMilliseconds : nil),
            peakMemoryBytes: peak,
            confidence: ConfidenceDiscrimination(samples: samples))
    }

    private static func tallyEmergency(_ summary: inout EmergencySummary, detail: UtteranceDetail,
                                       score: SystemUtteranceScore) {
        let flagged = score.emergencyMatch == true
        if detail.has(.emergencyPositive) {
            summary.positiveCount += 1
            if flagged { summary.positiveDetected += 1 }
            if detail.referenceEmergencyMatch { summary.positiveReferenceMatched += 1 }
        }
        if detail.has(.emergencyNegative) {
            summary.negativeCount += 1
            if flagged { summary.negativeFlagged += 1 }
            if detail.referenceEmergencyMatch { summary.negativeReferenceMatched += 1 }
        }
    }

    /// 错误数最小者；平局取 engineID 字典序最小者（确定性）。
    static func bestScore(_ scores: [SystemUtteranceScore]) -> SystemUtteranceScore? {
        scores.min { lhs, rhs in
            lhs.errorCount != rhs.errorCount ? lhs.errorCount < rhs.errorCount : lhs.engineID < rhs.engineID
        }
    }

    /// (a − b) × 100；任一为 nil → nil。
    static func percentagePointGap(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return (a - b) * 100
    }

    struct RateAccumulator {
        var utterances = 0
        var referenceTokens = 0
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var rateSum = 0.0

        mutating func add(_ score: SystemUtteranceScore, referenceLength: Int) {
            utterances += 1
            referenceTokens += referenceLength
            substitutions += score.substitutions
            deletions += score.deletions
            insertions += score.insertions
            rateSum += score.rate ?? 0
        }

        var summary: RateSummary {
            guard utterances > 0 else { return .empty }
            let errors = substitutions + deletions + insertions
            return RateSummary(
                utteranceCount: utterances, referenceTokenCount: referenceTokens, substitutions: substitutions,
                deletions: deletions, insertions: insertions,
                micro: referenceTokens > 0 ? Double(errors) / Double(referenceTokens) : nil,
                macro: rateSum / Double(utterances))
        }
    }
}
