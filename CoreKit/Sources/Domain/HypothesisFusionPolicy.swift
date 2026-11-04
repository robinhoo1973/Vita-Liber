import Foundation

/// 多假设融合的调用方策略（2026-11-04 通用化）：把原先硬编码在 Domain 的医疗词表
/// （单位/否定/临床极性）、保护词类、归一化选项与源权重下沉为可注入的值对象。
///
/// **分层**：Domain 只定义策略形状与通用分词机制，不含任何医学词表；医疗预设
/// `HypothesisFusionMedicalPolicy`（内含原 `HypothesisFusionVocabulary`）位于 Infrastructure，
/// 由 App 的识别调试采集显式注入。`HypothesisFusionPolicy.generic` 为空词表策略，
/// ASR 与 OCR 的通用文本融合可直接使用。
///
/// **默认值 = 既有行为**：归一化五项默认全开；数字/单位/否定/极性默认受保护；
/// 否定类默认冻结子句；源权重缺省 1（不改变校准得分）。
public struct HypothesisFusionPolicy: Sendable, Equatable {
    /// 词表：每条按与假设**同一分词**的键序列整段匹配（大小写、全半角不敏感）。
    /// 空数组 = 不识别该类；宁多勿少由调用方决定。
    public struct Vocabulary: Sendable, Equatable {
        /// 计量单位词（命中非数字词元 → `.unit`）。
        public var unitTerms: [String]
        /// 否定词（命中普通词 → `.negation`）。
        public var negationTerms: [String]
        /// 对立语义词（左右/正负/增减/停止等；命中普通词 → `.polarity`）。
        public var polarityTerms: [String]
        /// 拉丁否定缩约后缀（如 `n't`）；空 = 不识别缩约。
        public var negationContractionSuffixes: [String]

        public init(unitTerms: [String] = [], negationTerms: [String] = [], polarityTerms: [String] = [],
                    negationContractionSuffixes: [String] = []) {
            self.unitTerms = unitTerms
            self.negationTerms = negationTerms
            self.polarityTerms = polarityTerms
            self.negationContractionSuffixes = negationContractionSuffixes
        }
    }

    /// 归一化开关（默认全开 = 既有行为）。
    public struct Normalization: Sendable, Equatable {
        /// NFKC 兼容归一（全角、℃，μ 等）。
        public var appliesCompatibilityNormalization: Bool
        /// 拉丁小写折叠（严格等价键大小写不敏感）。
        public var foldsLatinCase: Bool
        /// 弯撇号折成 ASCII 撇号（don’t ≡ don't）。
        public var foldsApostrophes: Bool
        /// 汉字转拼音作为对齐软代价（只降低对齐代价，绝不作等价键）。
        public var usesPhoneticAlignment: Bool
        /// 中文数字串求值（五百 ≡ 500）；关闭后按普通汉字处理。
        public var evaluatesChineseNumerals: Bool

        public init(appliesCompatibilityNormalization: Bool = true, foldsLatinCase: Bool = true,
                    foldsApostrophes: Bool = true, usesPhoneticAlignment: Bool = true,
                    evaluatesChineseNumerals: Bool = true) {
            self.appliesCompatibilityNormalization = appliesCompatibilityNormalization
            self.foldsLatinCase = foldsLatinCase
            self.foldsApostrophes = foldsApostrophes
            self.usesPhoneticAlignment = usesPhoneticAlignment
            self.evaluatesChineseNumerals = evaluatesChineseNumerals
        }
    }

    public var vocabulary: Vocabulary
    /// 调用方受保护词条（药名等）；与 `HypothesisFusionOptions.protectedTerms` 合并。
    public var protectedTerms: [String]
    /// 命中即整列不自动改的词类（保护必须对称）。
    public var protectedTokenClasses: Set<HypothesisFusionTokenClass>
    /// 命中候选冻结其所在子句（否定辖域）；空 = 不冻结。
    public var clauseFreezingTokenClasses: Set<HypothesisFusionTokenClass>
    public var normalization: Normalization
    /// 源权重（键 = engineID），乘到该校准得分上；缺省/非法（非有限或负）= 1。
    public var sourceWeights: [String: Double]

    public init(vocabulary: Vocabulary = Vocabulary(), protectedTerms: [String] = [],
                protectedTokenClasses: Set<HypothesisFusionTokenClass> =
                    [.number, .unit, .negation, .polarity],
                clauseFreezingTokenClasses: Set<HypothesisFusionTokenClass> = [.negation],
                normalization: Normalization = Normalization(),
                sourceWeights: [String: Double] = [:]) {
        self.vocabulary = vocabulary
        self.protectedTerms = protectedTerms
        self.protectedTokenClasses = protectedTokenClasses
        self.clauseFreezingTokenClasses = clauseFreezingTokenClasses
        self.normalization = normalization
        self.sourceWeights = sourceWeights
    }

    /// 空词表通用策略：不假设任何领域，只保留数字/单位符号的通用保护。
    public static let generic = HypothesisFusionPolicy()

    /// 生效源权重：未配置、非有限或负值一律按 1（不改变校准得分）。
    public func effectiveSourceWeight(for engineID: String) -> Double {
        guard let weight = sourceWeights[engineID], weight.isFinite, weight >= 0 else { return 1 }
        return weight
    }
}
