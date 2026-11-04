import Foundation

/// 评测统计：确定性随机源、分位数、配对 bootstrap。
///
/// ADR-025 / FR0.1 审查：标准库 `SystemRandomNumberGenerator` 不可设种子；`Int.random(in:using:)`
/// 的取值算法不承诺跨 Swift 版本稳定；Foundation 无 bootstrap/分位数 API——为「同种子同报告」
/// 的可复核性，随机源（SplitMix64，Steele/Lea/Flood 2014 公开常数）与有界取整（Lemire 乘高位）自研。
extension ASREvaluation {

    /// SplitMix64：64 位状态、确定性，用作 bootstrap 重采样随机源。
    public struct SplitMix64: RandomNumberGenerator, Sendable, Equatable {
        public private(set) var state: UInt64

        public init(seed: UInt64) { state = seed }

        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// `[0, bound)` 均匀整数：取 `next() × bound` 的高 64 位（偏差 < bound / 2⁶⁴，可忽略）。
        public mutating func nextIndex(below bound: Int) -> Int {
            precondition(bound > 0, "bound 必须为正")
            return Int(next().multipliedFullWidth(by: UInt64(bound)).high)
        }
    }

    /// 最近秩分位数（nearest-rank）：`sorted[ceil(p·n) − 1]`，p ∈ (0, 1]；空数组 → nil。
    /// 取值恒为观测值之一，无插值浮点尾差，渲染稳定；`p·n` 先减 1e-9 再取整，防 0.025×10000
    /// 之类乘积的浮点尾差把秩推高一位。
    public static func nearestRankPercentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count) - 1e-9).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// 配对 bootstrap 最少重采样次数（P2 指标表：≥ 10,000）。传入更小值按此值执行。
    public static let minimumBootstrapIterations = 10_000
    /// 默认种子（< 2⁵³，JSON 往返无精度损失）。
    public static let defaultBootstrapSeed: UInt64 = 20_261_103
    /// 置信水平（双侧百分位区间）与其上下分位（字面常量，避免 (1−0.95)/2 的浮点尾差）。
    public static let bootstrapConfidenceLevel = 0.95
    public static let bootstrapLowerQuantile = 0.025
    public static let bootstrapUpperQuantile = 0.975

    /// 两系统逐句 MER 差的配对 bootstrap 结果；差值方向恒为 **A − B**（正 = A 更差），单位为比例（×100 = 百分点）。
    public struct PairedBootstrap: Sendable, Equatable, Codable {
        public var engineA: String
        public var engineB: String
        /// 两系统都已计分（recognized/failed）的句数。
        public var utteranceCount: Int
        public var iterations: Int
        public var seed: UInt64
        public var confidenceLevel: Double
        /// 逐句 MER 差的均值（macro）。
        public var meanDifference: Double
        public var lower: Double
        public var upper: Double
        /// 语料级（micro：Σ错误/Σ参考）MER 差，同一组重采样下的点估计与区间。
        public var microDifference: Double
        public var microLower: Double
        public var microUpper: Double

        public init(engineA: String, engineB: String, utteranceCount: Int, iterations: Int, seed: UInt64,
                    confidenceLevel: Double, meanDifference: Double, lower: Double, upper: Double,
                    microDifference: Double, microLower: Double, microUpper: Double) {
            self.engineA = engineA
            self.engineB = engineB
            self.utteranceCount = utteranceCount
            self.iterations = iterations
            self.seed = seed
            self.confidenceLevel = confidenceLevel
            self.meanDifference = meanDifference
            self.lower = lower
            self.upper = upper
            self.microDifference = microDifference
            self.microLower = microLower
            self.microUpper = microUpper
        }
    }

    /// 一对逐句观测：两系统的错误数与共同的参考 token 数。
    public struct PairedObservation: Sendable, Equatable {
        public var errorsA: Int
        public var errorsB: Int
        public var referenceLength: Int
        public var rateA: Double
        public var rateB: Double

        public init(errorsA: Int, errorsB: Int, referenceLength: Int, rateA: Double, rateB: Double) {
            self.errorsA = errorsA
            self.errorsB = errorsB
            self.referenceLength = referenceLength
            self.rateA = rateA
            self.rateB = rateB
        }
    }

    /// 配对 bootstrap 核心：有放回重采样 n 句 × `iterations` 次，取均值差与语料级差的 2.5%/97.5% 最近秩分位。
    /// 空观测 → nil。同（观测、次数、种子）恒得同一结果。
    public static func pairedBootstrap(engineA: String, engineB: String, observations: [PairedObservation],
                                       iterations: Int = minimumBootstrapIterations,
                                       seed: UInt64 = defaultBootstrapSeed) -> PairedBootstrap? {
        let count = observations.count
        guard count > 0 else { return nil }
        let rounds = max(iterations, minimumBootstrapIterations)
        let differences = observations.map { $0.rateA - $0.rateB }
        var generator = SplitMix64(seed: seed)
        var means = [Double](repeating: 0, count: rounds)
        var micros = [Double](repeating: 0, count: rounds)
        for round in 0..<rounds {
            var sum = 0.0
            var errorDelta = 0
            var length = 0
            for _ in 0..<count {
                let pick = generator.nextIndex(below: count)
                sum += differences[pick]
                errorDelta += observations[pick].errorsA - observations[pick].errorsB
                length += observations[pick].referenceLength
            }
            means[round] = sum / Double(count)
            micros[round] = length > 0 ? Double(errorDelta) / Double(length) : 0
        }
        means.sort()
        micros.sort()
        let totalLength = observations.reduce(0) { $0 + $1.referenceLength }
        let totalDelta = observations.reduce(0) { $0 + $1.errorsA - $1.errorsB }
        return PairedBootstrap(
            engineA: engineA, engineB: engineB, utteranceCount: count, iterations: rounds, seed: seed,
            confidenceLevel: bootstrapConfidenceLevel,
            meanDifference: differences.reduce(0, +) / Double(count),
            lower: nearestRankPercentile(means, bootstrapLowerQuantile) ?? 0,
            upper: nearestRankPercentile(means, bootstrapUpperQuantile) ?? 0,
            microDifference: totalLength > 0 ? Double(totalDelta) / Double(totalLength) : 0,
            microLower: nearestRankPercentile(micros, bootstrapLowerQuantile) ?? 0,
            microUpper: nearestRankPercentile(micros, bootstrapUpperQuantile) ?? 0)
    }
}
