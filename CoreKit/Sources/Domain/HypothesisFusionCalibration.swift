import Foundation

/// 多假设融合的离线校准表（round3 §6.2）：macOS CI 用金样离线生成、随 App 版本固定，**不在设备上在线学习**。
///
/// **计数口径（生成器与消费方的契约）**：每个对齐列（主轨词元列，或副轨插入列——以建列词元为参照）、
/// 每个未弃权引擎记一次 `total`，其票（词元键或 ∅）等于真值时记一次 `correct`。
/// 维度全部取运行时可算的量：`script` / `tokenClass` = 该列参照词元的脚本与词类；
/// `confidenceBin` = 该引擎本列词元映射到的置信度档（∅ 票或无置信度 = nil，不分档）。
/// 各 `Cell` 是互斥计数桶；上级（不分档 / 不分词类）由消费方求和得到，生成器不得重复写汇总行。
///
/// 不变量（照搬 FR17.4 `VoiceCalibration` 的 fail-closed 写法）：
///     融合已启用  ⟹  `releasePassed`
/// 缺金样/不达标时开关强制为关（见 `HypothesisFusionGate`）。
public struct HypothesisFusionCalibration: Sendable, Equatable, Codable {
    /// 一个互斥计数桶：引擎 × 脚本 × 词类 × 置信度档。
    public struct Cell: Sendable, Equatable, Codable {
        public var engineID: String
        public var script: HypothesisFusionScript
        public var tokenClass: HypothesisFusionTokenClass
        /// 置信度档（0..<confidenceBinCount）；nil = 不分档（引擎无置信度或 ∅ 票）。
        public var confidenceBin: Int?
        public var correct: Int
        public var total: Int

        public init(engineID: String, script: HypothesisFusionScript, tokenClass: HypothesisFusionTokenClass,
                    confidenceBin: Int? = nil, correct: Int, total: Int) {
            self.engineID = engineID
            self.script = script
            self.tokenClass = tokenClass
            self.confidenceBin = confidenceBin
            self.correct = correct
            self.total = total
        }

        enum CodingKeys: String, CodingKey {
            case engineID = "engine_id"
            case script
            case tokenClass = "token_class"
            case confidenceBin = "confidence_bin"
            case correct
            case total
        }
    }

    public var version: String
    /// 金样语料规模（条）。
    public var corpusSize: Int
    /// 其中中英混说条数。
    public var codeSwitchedCount: Int
    /// 放行线是否通过（由离线生成器按金样评测写入；false ⟹ 融合必须关闭）。
    public var releasePassed: Bool
    /// 置信度等宽分档数（[0,1] 均分）。
    public var confidenceBinCount: Int
    public var cells: [Cell]
    /// 各引擎对（主轨 × 副轨）在金样上的基线分歧率（与 `FusedTranscript.pairObservations` 同一口径）；
    /// 无标签漂移监测的参照（`HypothesisFusionDriftMonitor`）。
    public var baselineDisagreementRates: [HypothesisFusionDisagreementBaseline]
    /// 生成校准时的系统版本号（Apple 识别模型随系统静默更新）；nil = 未钉系统版本。
    /// 非 nil 时只能经带漂移报告的门控启用，且当前系统版本必须逐字一致。
    public var osBuild: String?

    public init(version: String, corpusSize: Int, codeSwitchedCount: Int, releasePassed: Bool,
                confidenceBinCount: Int = 10, cells: [Cell],
                baselineDisagreementRates: [HypothesisFusionDisagreementBaseline] = [], osBuild: String? = nil) {
        self.version = version
        self.corpusSize = corpusSize
        self.codeSwitchedCount = codeSwitchedCount
        self.releasePassed = releasePassed
        self.confidenceBinCount = confidenceBinCount
        self.cells = cells
        self.baselineDisagreementRates = baselineDisagreementRates
        self.osBuild = osBuild
    }

    enum CodingKeys: String, CodingKey {
        case version
        case corpusSize = "corpus_size"
        case codeSwitchedCount = "code_switched_count"
        case releasePassed = "release_passed"
        case confidenceBinCount = "confidence_bin_count"
        case cells
        case baselineDisagreementRates = "baseline_disagreement_rates"
        case osBuild = "os_build"
    }

    /// 解码：漂移字段缺省（早期校准包）= 无基线、未钉系统版本。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        corpusSize = try container.decode(Int.self, forKey: .corpusSize)
        codeSwitchedCount = try container.decode(Int.self, forKey: .codeSwitchedCount)
        releasePassed = try container.decode(Bool.self, forKey: .releasePassed)
        confidenceBinCount = try container.decode(Int.self, forKey: .confidenceBinCount)
        cells = try container.decode([Cell].self, forKey: .cells)
        baselineDisagreementRates = try container.decodeIfPresent([HypothesisFusionDisagreementBaseline].self,
                                                                 forKey: .baselineDisagreementRates) ?? []
        osBuild = try container.decodeIfPresent(String.self, forKey: .osBuild)
    }

    /// 空表（未过放行线）：融合输出恒等于主轨。
    public static var empty: HypothesisFusionCalibration {
        HypothesisFusionCalibration(version: "none", corpusSize: 0, codeSwitchedCount: 0, releasePassed: false,
                                    cells: [])
    }

    /// 格子充分性下限（round3 §6.1 步骤 5）：错误数 < 30 或 token < 200 即逐级回退。
    public static let minimumErrors = 30
    public static let minimumTokens = 200
    /// 对数几率中假设的混淆候选数 K（候选得分 = Σ max(0, log(K·p/(1−p)))）。
    public static let alternativeCount = 3.0
    /// p 的截断区间：避免 log(0) / 除零。
    public static let probabilityFloor = 0.005
    public static let probabilityCeiling = 0.995

    /// 结构自检：计数非负、correct ≤ total、档位在界内、引擎名非空；基线分歧率在 [0,1] 且引擎对不重复。
    /// 任何一条不满足 ⟹ 整表不可用（fail-closed）。
    public var isWellFormed: Bool {
        // 计数上限同时是溢出保险：索引构建把多个 Cell 相加，接近 Int.max 的计数会在
        // 校验通过后溢出崩溃；语料规模不可能接近 10^9。
        let countCeiling = 1_000_000_000
        guard (1...1_000).contains(confidenceBinCount), (0...countCeiling).contains(corpusSize),
              (0...corpusSize).contains(codeSwitchedCount) else { return false }
        var cellKeys = Set<[String]>()
        let cellsValid = cells.allSatisfy { cell in
            guard !cell.engineID.isEmpty, cell.correct >= 0, cell.total >= 0, cell.correct <= cell.total,
                  cell.correct <= countCeiling, cell.total <= countCeiling,
                  cell.confidenceBin.map({ (0..<confidenceBinCount).contains($0) }) ?? true else { return false }
            // 各 Cell 是互斥计数桶：重复维度会在精确档首条命中、在上级回退求和，
            // 同一计数被两种口径重复解释。生成器契约要求汇总由消费方求和，整表拒收。
            let key = [cell.engineID, cell.script.rawValue, cell.tokenClass.rawValue,
                       cell.confidenceBin.map(String.init) ?? "-"]
            return cellKeys.insert(key).inserted
        }
        var pairs = Set<[String]>()
        let baselinesValid = baselineDisagreementRates.allSatisfy { baseline in
            !baseline.primaryEngineID.isEmpty && !baseline.secondaryEngineID.isEmpty
                && baseline.rate.isFinite && (0...1).contains(baseline.rate)
                && pairs.insert([baseline.primaryEngineID, baseline.secondaryEngineID]).inserted
        }
        return cellsValid && baselinesValid
    }

    /// 某引擎对的基线分歧率（无记录或记录非法 = nil）。
    public func baselineDisagreementRate(primaryEngineID: String, secondaryEngineID: String) -> Double? {
        guard let baseline = baselineDisagreementRates.first(where: {
            $0.primaryEngineID == primaryEngineID && $0.secondaryEngineID == secondaryEngineID
        }), baseline.rate.isFinite, (0...1).contains(baseline.rate) else { return nil }
        return baseline.rate
    }

    /// 置信度 → 档位（[0,1] 等宽 `binCount` 档；非有限值或档数非法 = nil）。
    public static func confidenceBin(for confidence: Double, binCount: Int) -> Int? {
        // 档数上限同时防 `Int(clamped * binCount)` 在极端 binCount 下溢出崩溃；
        // 正常校准包 10 档，1000 已是 isWellFormed 的上限。
        guard (1...10_000).contains(binCount), confidence.isFinite else { return nil }
        let clamped = min(1, max(0, confidence))
        return min(binCount - 1, Int(clamped * Double(binCount)))
    }

    /// 引擎在某列的可靠度（按 (档) → (词类) → (脚本) 逐级回退；无数据 = nil，即该引擎在此列弃权）。
    public func reliability(engineID: String, script: HypothesisFusionScript,
                            tokenClass: HypothesisFusionTokenClass,
                            confidence: Double? = nil) -> HypothesisFusionReliability? {
        HypothesisFusionCalibrationIndex(self).reliability(engineID: engineID, script: script,
                                                          tokenClass: tokenClass, confidence: confidence)
    }
}

/// 一次查表结果。
public struct HypothesisFusionReliability: Sendable, Equatable {
    /// 命中的回退层级。
    public enum Level: String, Sendable, Equatable, Codable {
        /// (引擎, 脚本, 词类, 置信度档)
        case confidenceBin
        /// (引擎, 脚本, 词类)
        case tokenClass
        /// (引擎, 脚本)
        case script
    }

    /// 截断后的校准正确率 p。
    public var probability: Double
    /// 投票权重 max(0, log(K·p/(1−p)))。
    public var weight: Double
    public var level: Level
}

/// 融合门控（fail-closed）：`isEnabled ⟹ calibration.releasePassed`。
/// 实验室开关只是必要条件；缺校准表或未过放行线时无论开关如何都为关。
public enum HypothesisFusionGate {
    /// 基础门控。钉了系统版本的校准包（`osBuild != nil`）在此**恒关**——本入口无法核对当前系统版本，
    /// 必须改走 `isEnabled(labSwitch:calibration:drift:)`（缺证据即关）。
    public static func isEnabled(labSwitch: Bool, calibration: HypothesisFusionCalibration?) -> Bool {
        guard labSwitch, let calibration else { return false }
        return calibration.releasePassed && calibration.osBuild == nil
            && calibration.corpusSize > 0 && !calibration.cells.isEmpty && calibration.isWellFormed
    }

    /// 带无标签漂移监测的门控：放行线通过 ∧ 漂移报告出自同一校准包（版本一致）∧ 系统版本一致 ∧ 无引擎对漂移。
    /// 任一不满足即回落主轨。
    public static func isEnabled(labSwitch: Bool, calibration: HypothesisFusionCalibration?,
                                 drift: HypothesisFusionDriftReport) -> Bool {
        guard labSwitch, let calibration, calibration.releasePassed,
              calibration.corpusSize > 0, !calibration.cells.isEmpty, calibration.isWellFormed else { return false }
        return drift.calibrationVersion == calibration.version && !drift.requiresFallback
    }
}

/// 校准表的查找索引（一次融合调用内构建一次；只做字典查找、从不遍历字典，保证确定性）。
struct HypothesisFusionCalibrationIndex {
    private struct BinKey: Hashable {
        var engineID: String
        var script: HypothesisFusionScript
        var tokenClass: HypothesisFusionTokenClass
        var bin: Int
    }

    private struct ClassKey: Hashable {
        var engineID: String
        var script: HypothesisFusionScript
        var tokenClass: HypothesisFusionTokenClass
    }

    private struct ScriptKey: Hashable {
        var engineID: String
        var script: HypothesisFusionScript
    }

    private struct Counts {
        var correct = 0
        var total = 0

        var isSufficient: Bool {
            total >= HypothesisFusionCalibration.minimumTokens
                && total - correct >= HypothesisFusionCalibration.minimumErrors
        }

        mutating func add(_ cell: HypothesisFusionCalibration.Cell) {
            correct += cell.correct
            total += cell.total
        }
    }

    private var binned: [BinKey: Counts] = [:]
    private var byClass: [ClassKey: Counts] = [:]
    private var byScript: [ScriptKey: Counts] = [:]
    private var engines: Set<String> = []
    private let binCount: Int

    init(_ calibration: HypothesisFusionCalibration) {
        binCount = calibration.confidenceBinCount
        for cell in calibration.cells {
            engines.insert(cell.engineID)
            if let bin = cell.confidenceBin {
                let key = BinKey(engineID: cell.engineID, script: cell.script, tokenClass: cell.tokenClass, bin: bin)
                binned[key, default: Counts()].add(cell)
            }
            byClass[ClassKey(engineID: cell.engineID, script: cell.script, tokenClass: cell.tokenClass),
                    default: Counts()].add(cell)
            byScript[ScriptKey(engineID: cell.engineID, script: cell.script), default: Counts()].add(cell)
        }
    }

    /// 校准表是否认识该引擎（不认识 ⟹ 该引擎处处弃权；主轨不认识 ⟹ 整体只用主轨）。
    func knows(_ engineID: String) -> Bool { engines.contains(engineID) }

    func reliability(engineID: String, script: HypothesisFusionScript, tokenClass: HypothesisFusionTokenClass,
                     confidence: Double?) -> HypothesisFusionReliability? {
        guard engines.contains(engineID) else { return nil }
        if let confidence, let bin = HypothesisFusionCalibration.confidenceBin(for: confidence, binCount: binCount),
           let counts = binned[BinKey(engineID: engineID, script: script, tokenClass: tokenClass, bin: bin)],
           counts.isSufficient {
            return Self.reliability(counts, level: .confidenceBin)
        }
        if let counts = byClass[ClassKey(engineID: engineID, script: script, tokenClass: tokenClass)],
           counts.isSufficient {
            return Self.reliability(counts, level: .tokenClass)
        }
        if let counts = byScript[ScriptKey(engineID: engineID, script: script)], counts.isSufficient {
            return Self.reliability(counts, level: .script)
        }
        return nil
    }

    private static func reliability(_ counts: Counts,
                                    level: HypothesisFusionReliability.Level) -> HypothesisFusionReliability {
        let raw = Double(counts.correct) / Double(counts.total)
        let probability = min(HypothesisFusionCalibration.probabilityCeiling,
                              max(HypothesisFusionCalibration.probabilityFloor, raw))
        let odds = HypothesisFusionCalibration.alternativeCount * probability / (1 - probability)
        return HypothesisFusionReliability(probability: probability, weight: max(0, log(odds)), level: level)
    }
}
