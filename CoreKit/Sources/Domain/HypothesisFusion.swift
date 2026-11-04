import Foundation

/// 多假设融合实验室模块（round3 §6「主轨默认 · 语言感知 · 校准加权 · 带保护的 ROVER」）。
///
/// **定位**：纯 Domain、确定性、零持久化的实验室算法；不接入任何 App / Infrastructure 生产路径，
/// 启用与否只由 `HypothesisFusionGate`（fail-closed，含无标签漂移监测 `HypothesisFusionDriftMonitor`）决定。
/// 默认 `.reviewOnly`（辩论终裁 P2a：只提示不改写先于任何自动改写上线）。
///
/// **只选不生成**：输出中每个不同于主轨的片段都是某个副轨的原样词元；在主轨原字符串上按
/// UTF-16 区间就地替换，分隔符/标点逐字节保留（round3 §3.3：重新拼接曾把「120 80」写成「12080」）。
///
/// **保护策略由调用方注入**：数字/单位等受保护词类、调用方词表标出的否定/对立语义词与受保护词条，
/// 以及冻结子句内的列一律不自动改，只标「待核」并附候选。内核不做领域判断——医疗语义由
/// `HypothesisFusionPolicy`（Infrastructure 的医疗预设 / App 调用方）提供。融合不等于确认：
/// 结果仍是 D 级识别草稿，须经人工确认才进 D→C 流程。
public enum HypothesisFusion {
    /// 融合输出 engineID 的版本段。
    public static let formatVersion = "v1"
    /// 单次对齐 DP 的格子上限（≈ 9 MB）；超出即只用主轨（端侧内存防护）。
    public static let maximumAlignmentCells = 1_000_000

    /// 融合一次按压（或一个 VAD 段）的主轨与副轨假设。
    ///
    /// - 校准表未过放行线 / 为空 / 结构非法、主轨引擎不在校准表、无（有词元的）副轨、输入超长 →
    ///   原样返回主轨（`text` 与 `primary.text` 逐字节一致、`edits` 为空），`fallback` 注明原因。
    /// - 副轨先按 engineID（及其余字段）排序并按 engineID 去重——输入顺序不影响结果。
    /// - 默认 `.reviewOnly`（辩论终裁 P2a）：只标待核、`text` 恒等于主轨；`.gatedRewrite` 才就地改写。
    public static func fuse(primary: TranscriptionHypothesis, secondaries: [TranscriptionHypothesis],
                            calibration: HypothesisFusionCalibration,
                            options: HypothesisFusionOptions = HypothesisFusionOptions()) -> FusedTranscript {
        let others = orderedSecondaries(secondaries, primaryEngineID: primary.engineID)
        let sources = [primary.engineID] + others.map(\.engineID)
        let engineID = "fusion:\(formatVersion)(primary=\(primary.engineID);secondaries="
            + others.map(\.engineID).joined(separator: ",") + ")"
        func unchanged(_ reason: HypothesisFusionFallback) -> FusedTranscript {
            FusedTranscript(text: primary.text, edits: [], disputes: [], engineID: engineID, sources: sources,
                            fallback: reason)
        }
        guard calibration.releasePassed else { return unchanged(.calibrationNotReleased) }
        guard !calibration.cells.isEmpty else { return unchanged(.calibrationEmpty) }
        guard calibration.isWellFormed else { return unchanged(.calibrationMalformed) }
        let index = HypothesisFusionCalibrationIndex(calibration)
        guard index.knows(primary.engineID) else { return unchanged(.primaryUncalibrated) }
        guard !others.isEmpty else { return unchanged(.noSecondaries) }

        let lexicon = HypothesisFusionLexicon(policy: options.policy)
        lexicon.prefetchPinyin(([primary] + others).map(\.text))
        let terms = lexicon.termKeySequences(options.policy.protectedTerms + options.protectedTerms)
        let primaryTokens = lexicon.tokens(for: primary, protectedTerms: terms)
        // 没有任何词元的副轨（空文本/只有标点 ≈ 引擎失败）整体弃权：否则其 ∅ 票会投向删除主轨内容。
        let voters = others.map { (hypothesis: $0, tokens: lexicon.tokens(for: $0, protectedTerms: terms)) }
            .filter { !$0.tokens.isEmpty }
        guard !voters.isEmpty else { return unchanged(.noSecondaries) }
        var columns = HypothesisFusionAligner.skeleton(primaryTokens)
        for (offset, voter) in voters.enumerated() {
            guard (columns.count + 1) * (voter.tokens.count + 1) <= maximumAlignmentCells else {
                return unchanged(.inputTooLong)
            }
            columns = HypothesisFusionAligner.merge(columns, engineIndex: offset + 1, tokens: voter.tokens)
        }
        let voterIDs = [primary.engineID] + voters.map(\.hypothesis.engineID)
        let decider = HypothesisFusionDecider(
            primaryText: primary.text, primaryTokens: primaryTokens, engineIDs: voterIDs,
            producibleScripts: voterIDs.map { options.scripts(for: $0) },
            columns: columns, calibration: index, options: options)
        let decision = decider.decide()
        let assembled = HypothesisFusionDecider.apply(decision.edits, to: primary.text)
        return FusedTranscript(text: assembled.text, edits: assembled.edits, disputes: decision.disputes,
                               engineID: engineID, sources: sources, fallback: nil,
                               pairObservations: decider.pairObservations())
    }

    /// 副轨确定性排序（engineID → locale → 文本 → 其余字段，均按 UTF-8 字节序）并按 engineID 去重
    /// （与主轨同名者剔除）——重复引擎会重复计权。
    static func orderedSecondaries(_ secondaries: [TranscriptionHypothesis],
                                   primaryEngineID: String) -> [TranscriptionHypothesis] {
        let sorted = secondaries.sorted { lhs, rhs in
            for (left, right) in zip(sortKey(lhs), sortKey(rhs)) where !left.utf8.elementsEqual(right.utf8) {
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
            return false
        }
        var seen: Set<String> = [primaryEngineID]
        return sorted.filter { seen.insert($0.engineID).inserted }
    }

    private static func sortKey(_ hypothesis: TranscriptionHypothesis) -> [String] {
        [
            hypothesis.engineID,
            hypothesis.localeIdentifier ?? "",
            hypothesis.text,
            hypothesis.languageTag ?? "",
            hypothesis.confidenceKind.rawValue,
            hypothesis.tokens.map { "\($0.text)\u{1F}\($0.confidence.map { "\($0)" } ?? "-")" }
                .joined(separator: "\u{1E}"),
            hypothesis.alternativeTexts.joined(separator: "\u{1E}"),
        ]
    }
}

/// 融合参数。默认值是实验室起点，须在开发集上调参（τ 可为 ∞ = 永远保留主轨）。
public struct HypothesisFusionOptions: Sendable, Equatable {
    /// 运行模式（2026-11-03 辩论终裁：只提示不改写先于任何自动改写上线）。
    public enum Mode: String, Sendable, Equatable, Codable {
        /// 只提示不改写（终裁 P2a，默认）：`text` 恒等于 `primary.text`、`edits` 恒空；所有实质分歧列都进
        /// `disputes`——本会自动改写的列记 `.reviewOnly`，保护/极性/否定辖域/门槛/校准不足等原因照常。
        case reviewOnly
        /// 门控改写：仅非保护列、证据过门槛时在主轨上就地改写。
        case gatedRewrite
    }

    public var mode: Mode
    /// 替换门槛 τ：仅当 (最佳候选得分 − 主轨候选得分) > τ 才自动改。NaN 按 ∞ 处理，负值按 0。
    public var tau: Double
    /// 删除主轨内容的附加边际：删除需 > τ + 本值。NaN 按 ∞ 处理，负值按 0。
    public var deletionMargin: Double
    /// 插入所需的最少不同引擎数（下限 2，只能调严：单引擎多出的词元永不插入）。
    public var minimumInsertionEngines: Int
    /// 调用方受保护词条（药名等）：命中区段不自动改（与 `policy.protectedTerms` 合并）。
    public var protectedTerms: [String]
    /// 各引擎可产出的脚本（键 = engineID）；未声明 = 全部脚本。引擎在不能产出的脚本上弃权。
    public var producibleScripts: [String: Set<HypothesisFusionScript>]
    /// 调用方语言/领域策略（词表、保护类、归一化、源权重）。默认空词表，不假设任何领域。
    public var policy: HypothesisFusionPolicy

    public init(mode: Mode = .reviewOnly, tau: Double = 1.0, deletionMargin: Double = 1.0,
                minimumInsertionEngines: Int = 2, protectedTerms: [String] = [],
                producibleScripts: [String: Set<HypothesisFusionScript>] = [:],
                policy: HypothesisFusionPolicy = .generic) {
        self.mode = mode
        self.tau = tau
        self.deletionMargin = deletionMargin
        self.minimumInsertionEngines = minimumInsertionEngines
        self.protectedTerms = protectedTerms
        self.producibleScripts = producibleScripts
        self.policy = policy
    }

    var effectiveTau: Double { tau.isNaN ? .infinity : max(0, tau) }
    var effectiveDeletionMargin: Double { deletionMargin.isNaN ? .infinity : max(0, deletionMargin) }
    var effectiveMinimumInsertionEngines: Int { max(2, minimumInsertionEngines) }

    func scripts(for engineID: String) -> Set<HypothesisFusionScript> {
        producibleScripts[engineID] ?? Set(HypothesisFusionScript.allCases)
    }
}

/// 融合结果（全部仅在内存；与 `TranscriptionHypothesis` 同为零持久化值对象）。
public struct FusedTranscript: Sendable, Equatable {
    /// 主轨原字符串就地修正后的文本。
    public var text: String
    /// 实际应用的修改（按位置升序，区间均相对 `primary.text`）。
    public var edits: [HypothesisFusionEdit]
    /// 保留主轨但存在候选分歧的列（「待核」）。
    public var disputes: [HypothesisFusionDispute]
    /// `fusion:v1(primary=…;secondaries=…)`（副轨按排序后顺序）。
    public var engineID: String
    /// 输入的引擎：主轨在前，其后为排序去重后的副轨（无词元的副轨列出但整体弃权）。
    public var sources: [String]
    /// 非 nil = 整体回退到主轨的原因。
    public var fallback: HypothesisFusionFallback?
    /// 本次主轨 × 各副轨的分歧计数（无标签漂移监测的输入，见 `HypothesisFusionDriftMonitor`）；回退时为空。
    public var pairObservations: [HypothesisFusionPairObservation]
    /// 各源来源组（与 `sources` 一一对应）；旧入口（无组信息）为空。
    public var sourceGroups: [String]

    public init(text: String, edits: [HypothesisFusionEdit], disputes: [HypothesisFusionDispute],
                engineID: String, sources: [String], fallback: HypothesisFusionFallback?,
                pairObservations: [HypothesisFusionPairObservation] = [], sourceGroups: [String] = []) {
        self.text = text
        self.edits = edits
        self.disputes = disputes
        self.engineID = engineID
        self.sources = sources
        self.fallback = fallback
        self.pairObservations = pairObservations
        self.sourceGroups = sourceGroups
    }
}

/// 整体回退到主轨的原因。
public enum HypothesisFusionFallback: String, Sendable, Equatable, Codable {
    case calibrationNotReleased
    case calibrationEmpty
    case calibrationMalformed
    /// 主轨引擎不在校准表（round3 §6.1 步骤 5「未知模型/系统版本组合 → 只用主轨」）。
    case primaryUncalibrated
    case noSecondaries
    case inputTooLong
    /// 多源入口：没有任何源声明为 `.primary`。
    case noPrimarySource
    /// 多源入口：多于一个源声明为 `.primary`（调用方契约错误，fail-closed）。
    case ambiguousPrimary
}

/// 一处已应用的修改。
public struct HypothesisFusionEdit: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case substitution
        case deletion
        case insertion
    }

    public var kind: Kind
    /// `primary.text` 中的 UTF-16 区间（插入为插入点处的空区间）。
    public var utf16Range: Range<Int>
    /// 被替换/删除的主轨原文（插入为空串）。
    public var original: String
    /// 实际写入的文本（删除为空串；插入在拉丁/数字相邻处可带一个分隔空格）。
    public var replacement: String
    /// 投票支持该修改的引擎（引擎顺序）。
    public var supportingEngineIDs: [String]
    /// 胜出候选得分 − 主轨候选得分（> τ，删除另加边际）。
    public var margin: Double

    public init(kind: Kind, utf16Range: Range<Int>, original: String, replacement: String,
                supportingEngineIDs: [String], margin: Double) {
        self.kind = kind
        self.utf16Range = utf16Range
        self.original = original
        self.replacement = replacement
        self.supportingEngineIDs = supportingEngineIDs
        self.margin = margin
    }
}

/// 一处「待核」：保留主轨，并附该列全部候选及来源/得分。
public struct HypothesisFusionDispute: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable, Codable {
        /// 列内任一候选（含主轨）为数字/单位/否定词或命中受保护词条。
        case protected
        /// 列内任一候选（含主轨）为调用方词表标出的对立语义词（左右/正负/增减等）。
        case polarity
        /// 所在子句（按主轨句读切分）任一列含否定词候选。
        case negationScope
        /// 证据未过门槛（得分差 ≤ τ、删除未过附加边际、插入不足最少引擎数）。
        case belowGate
        /// 主轨或全部异议候选在此列缺可用校准数据，无法比较。
        case insufficientCalibration
        /// 只提示模式（`.reviewOnly`）：证据已过门槛、门控改写模式下会自动改写的列。
        case reviewOnly
    }

    public struct Candidate: Sendable, Equatable {
        /// 候选原文；nil = ∅（删除 / 不插入）。
        public var surface: String?
        public var engineIDs: [String]
        public var score: Double
        public var isPrimary: Bool

        public init(surface: String?, engineIDs: [String], score: Double, isPrimary: Bool) {
            self.surface = surface
            self.engineIDs = engineIDs
            self.score = score
            self.isPrimary = isPrimary
        }
    }

    /// `primary.text` 中的 UTF-16 区间（插入列为插入点处的空区间）。
    public var utf16Range: Range<Int>
    /// 主轨在此的原文；nil = 插入列（主轨无内容）。
    public var primarySurface: String?
    /// 主轨候选在前，其余按得分降序。
    public var candidates: [Candidate]
    public var reason: Reason

    public init(utf16Range: Range<Int>, primarySurface: String?, candidates: [Candidate], reason: Reason) {
        self.utf16Range = utf16Range
        self.primarySurface = primarySurface
        self.candidates = candidates
        self.reason = reason
    }
}
