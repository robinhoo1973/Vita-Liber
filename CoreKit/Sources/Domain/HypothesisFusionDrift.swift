import Foundation

/// 校准包记录的一条基线：主轨 × 副轨在金样上的分歧率（与 `FusedTranscript.pairObservations` 同一口径）。
public struct HypothesisFusionDisagreementBaseline: Sendable, Equatable, Codable {
    public var primaryEngineID: String
    public var secondaryEngineID: String
    /// 分歧列数 / 可比列数，∈ [0, 1]。
    public var rate: Double

    public init(primaryEngineID: String, secondaryEngineID: String, rate: Double) {
        self.primaryEngineID = primaryEngineID
        self.secondaryEngineID = secondaryEngineID
        self.rate = rate
    }

    enum CodingKeys: String, CodingKey {
        case primaryEngineID = "primary_engine_id"
        case secondaryEngineID = "secondary_engine_id"
        case rate
    }
}

/// 一段窗口内（或一次融合）主轨 × 某副轨的分歧观测：只含计数，不含任何文本或音频。
public struct HypothesisFusionPairObservation: Sendable, Equatable, Codable {
    public var primaryEngineID: String
    public var secondaryEngineID: String
    public var disagreements: Int
    public var columns: Int

    public init(primaryEngineID: String, secondaryEngineID: String, disagreements: Int, columns: Int) {
        self.primaryEngineID = primaryEngineID
        self.secondaryEngineID = secondaryEngineID
        self.disagreements = disagreements
        self.columns = columns
    }

    enum CodingKeys: String, CodingKey {
        case primaryEngineID = "primary_engine_id"
        case secondaryEngineID = "secondary_engine_id"
        case disagreements
        case columns
    }
}

/// 漂移评估结果。`requiresFallback` 为真时门控必须回落主轨。
public struct HypothesisFusionDriftReport: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable, Codable {
        /// 观测分歧率未超出基线的单侧 99% 上界。
        case stable
        /// 观测分歧列数超出基线二项分布的单侧 99% 上界（无标签漂移）。
        case drifted
        /// 窗口列数不足 `minimumWindowColumns`：不下结论、不回落。
        case insufficientSamples
        /// 样本已足但校准包没有该引擎对的基线：无法核对 ⟹ 回落（缺证据即关）。
        case missingBaseline
        /// 计数非法（负数、分歧数大于列数或求和溢出）⟹ 回落。
        case invalidObservation
    }

    public struct Pair: Sendable, Equatable {
        public var primaryEngineID: String
        public var secondaryEngineID: String
        public var disagreements: Int
        public var columns: Int
        public var baselineRate: Double?
        /// 基线二项分布的单侧 99% 上界（分歧列数）；样本不足或无基线 = nil。
        public var upperBound: Int?
        public var verdict: Verdict

        public init(primaryEngineID: String, secondaryEngineID: String, disagreements: Int, columns: Int,
                    baselineRate: Double?, upperBound: Int?, verdict: Verdict) {
            self.primaryEngineID = primaryEngineID
            self.secondaryEngineID = secondaryEngineID
            self.disagreements = disagreements
            self.columns = columns
            self.baselineRate = baselineRate
            self.upperBound = upperBound
            self.verdict = verdict
        }

        public var observedRate: Double? { columns > 0 ? Double(disagreements) / Double(columns) : nil }
    }

    /// 评估所依据的校准包版本（门控核对与当前校准包一致）。
    public var calibrationVersion: String
    /// 当前系统版本与校准包记录一致（校准包未钉版本时恒真）。
    public var osBuildMatches: Bool
    /// 按 (主轨, 副轨) UTF-8 字节序排列。
    public var pairs: [Pair]

    public init(calibrationVersion: String, osBuildMatches: Bool, pairs: [Pair]) {
        self.calibrationVersion = calibrationVersion
        self.osBuildMatches = osBuildMatches
        self.pairs = pairs
    }

    /// 系统版本不一致、任一引擎对漂移/缺基线/计数非法 ⟹ 必须回落主轨。
    public var requiresFallback: Bool {
        !osBuildMatches || pairs.contains { pair in
            switch pair.verdict {
            case .drifted, .missingBaseline, .invalidObservation: return true
            case .stable, .insufficientSamples: return false
            }
        }
    }
}

/// 无标签漂移监测（2026-11-03 辩论终裁）：Apple 识别模型随系统静默更新，旧校准会让门控变差；
/// 金样标签在设备上不可得，只能监测「引擎间分歧率」这一无标签统计量是否显著偏离校准时的基线。
///
/// 判据：窗口列数 ≥ `minimumWindowColumns` 且观测分歧列数 > 基线 Binomial(n, p₀) 的单侧 99% 上界
/// ⟹ 漂移。精确二项尾概率（对数伽马 + 递推求和），不用正态近似（小 p₀ 时近似偏松）。纯函数、确定性。
public enum HypothesisFusionDriftMonitor {
    /// 窗口最少可比列数（与校准格子的 token 下限同量级）；不足不判漂移。
    public static let minimumWindowColumns = 200
    /// 单侧显著性水平（99% 上界）。
    public static let significance = 0.01

    public static func assess(calibration: HypothesisFusionCalibration, currentOSBuild: String?,
                              observations: [HypothesisFusionPairObservation]) -> HypothesisFusionDriftReport {
        var order: [[String]] = []
        var totals: [[String]: (disagreements: Int, columns: Int, valid: Bool)] = [:]
        for observation in observations {
            let key = [observation.primaryEngineID, observation.secondaryEngineID]
            if totals[key] == nil { order.append(key) }
            var entry = totals[key] ?? (disagreements: 0, columns: 0, valid: true)
            let (columns, columnsOverflow) = entry.columns.addingReportingOverflow(observation.columns)
            let (disagreements, disagreementsOverflow) = entry.disagreements
                .addingReportingOverflow(observation.disagreements)
            let wellFormed = observation.columns >= 0 && observation.disagreements >= 0
                && observation.disagreements <= observation.columns
            entry = (disagreements, columns, entry.valid && wellFormed && !columnsOverflow && !disagreementsOverflow)
            totals[key] = entry
        }
        order.sort { lhs, rhs in
            for (left, right) in zip(lhs, rhs) where !left.utf8.elementsEqual(right.utf8) {
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
            return false
        }
        let pairs = order.map { key -> HypothesisFusionDriftReport.Pair in
            let entry = totals[key] ?? (disagreements: 0, columns: 0, valid: false)
            let baseline = calibration.baselineDisagreementRate(primaryEngineID: key[0], secondaryEngineID: key[1])
            var bound: Int?
            let verdict: HypothesisFusionDriftReport.Verdict
            if !entry.valid {
                verdict = .invalidObservation
            } else if entry.columns < minimumWindowColumns {
                verdict = .insufficientSamples
            } else if let baseline, let upper = upperBound(columns: entry.columns, baselineRate: baseline) {
                bound = upper
                verdict = entry.disagreements > upper ? .drifted : .stable
            } else {
                verdict = .missingBaseline
            }
            return HypothesisFusionDriftReport.Pair(primaryEngineID: key[0], secondaryEngineID: key[1],
                                                    disagreements: entry.disagreements, columns: entry.columns,
                                                    baselineRate: baseline, upperBound: bound, verdict: verdict)
        }
        return HypothesisFusionDriftReport(calibrationVersion: calibration.version,
                                           osBuildMatches: osBuildMatches(calibration: calibration,
                                                                          currentOSBuild: currentOSBuild),
                                           pairs: pairs)
    }

    /// 校准包未钉系统版本 ⟹ 恒一致；钉了版本 ⟹ 当前版本必须逐字相同（取不到当前版本按不一致处理）。
    public static func osBuildMatches(calibration: HypothesisFusionCalibration, currentOSBuild: String?) -> Bool {
        guard let pinned = calibration.osBuild else { return true }
        return currentOSBuild == pinned
    }

    /// Binomial(columns, baselineRate) 的单侧 99% 上界 U：满足 P(X > U) ≤ `significance` 的最小 U。
    /// 参数非法（列数为负、比率非有限或越出 [0,1]）= nil。
    public static func upperBound(columns: Int, baselineRate: Double) -> Int? {
        guard columns >= 0, baselineRate.isFinite, (0...1).contains(baselineRate) else { return nil }
        if baselineRate == 0 { return 0 }
        if baselineRate == 1 { return columns }
        // 下界 ⌊np⌋：u < ⌊np⌋ 时 P(X > u) ≥ P(X ≥ 中位数) ≥ 1/2，不可能 ≤ 1%。尾概率随 u 单调不增 → 二分。
        var low = Int((Double(columns) * baselineRate).rounded(.down))
        var high = columns
        while low < high {
            let middle = low + (high - low) / 2
            if upperTail(atLeast: middle + 1, trials: columns, probability: baselineRate) <= significance {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// P(X ≥ k)，X ~ Binomial(n, p)，只在 k > ⌊np⌋（众数右侧、项单调递减）精确求和；k ≤ ⌊np⌋ 返回 1（保守）。
    static func upperTail(atLeast k: Int, trials n: Int, probability p: Double) -> Double {
        guard k > 0 else { return 1 }
        guard k <= n, p > 0 else { return 0 }
        guard p < 1, Double(k) > (Double(n) * p).rounded(.down) else { return 1 }
        let logFirst = lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1))
            + Double(k) * log(p) + Double(n - k) * log1p(-p)
        var term = exp(logFirst)
        var sum = term
        var index = k
        let odds = p / (1 - p)
        while index < n, term > sum * 1e-17 {
            term *= Double(n - index) / Double(index + 1) * odds
            sum += term
            index += 1
        }
        return min(1, sum)
    }
}
