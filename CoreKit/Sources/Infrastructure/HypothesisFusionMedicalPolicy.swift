import Domain

/// 医疗领域词表（原 Domain `HypothesisFusionVocabulary`，2026-11-04 通用化后外移）。
///
/// 全部按与假设**同一分词**的键序列整段匹配（大小写、全半角不敏感），单字条目匹配该字的每一次出现。
/// 宁多勿少：误保护只少一次自动改，漏保护会翻转医疗语义。公开常量便于审计。
public enum HypothesisFusionVocabulary {
    /// 通用单位（round3 §6.1 步骤 7）：「毫克」= 毫+克，「mmol/L」= mmol+l。
    public static let units: [String] = [
        "mg", "g", "kg", "ml", "mL", "L", "dL", "μg", "mcg", "IU", "U", "mmHg", "mmol/L", "μmol/L",
        "mg/dL", "g/L", "bpm", "cm", "mm", "%", "‰", "℃", "℉", "°",
        "毫克", "克", "千克", "公斤", "斤", "毫升", "升", "微克", "毫米汞柱", "毫摩尔", "微摩尔",
        "厘米", "毫米", "度", "片", "粒", "单位", "單位",
    ]

    /// 否定词（另认以 n't 结尾的拉丁缩约）。含否定词候选的列不自动改，且冻结其所在子句（否定辖域）。
    public static let negations: [String] = [
        "不", "没", "沒", "无", "無", "未", "非", "否", "别", "別", "勿", "莫", "毋", "甭", "冇",
        "no", "not", "never", "without", "none", "nor", "neither", "nobody", "nothing", "nowhere",
        "cannot", "deny", "denies", "denied", "absent",
        "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent", "cant", "couldnt", "wont",
        "wouldnt", "shouldnt", "havent", "hasnt", "hadnt", "aint", "mustnt", "neednt",
    ]

    /// 临床极性/方位/时序/剂量动作词：列内任一候选含此类词且候选间不一致 ⟹ 不自动改、记 `.polarity` 待核
    /// （与否定词同等的列级保护；不扩展为子句辖域）。「上/下」刻意不纳入（单字方位过宽）。
    /// 繁体变体（陰/陽/雙側/後/減/飯）为 zh-Hant 对等追加。
    public static let polarity: [String] = [
        "阴性", "阳性", "阴", "阳", "陰性", "陽性", "陰", "陽",
        "左", "右", "双侧", "雙側", "前", "后", "後",
        "饭前", "饭后", "飯前", "飯後", "餐前", "餐后", "餐後", "睡前", "空腹",
        "早", "中", "晚",
        "增", "减", "減", "加", "停",
        "left", "right", "bilateral", "positive", "negative", "before", "after",
        "increase", "increases", "increased", "increasing", "decrease", "decreases", "decreased", "decreasing",
        "stop", "stops", "stopped", "stopping",
    ]
}

/// 医疗融合预设：把医疗词表、受保护词类与否定辖域打包为 Domain 通用 `HypothesisFusionPolicy`。
///
/// 调用方（App 识别调试采集）显式注入 `standard`；Domain 内核不持有任何医疗词表。
public enum HypothesisFusionMedicalPolicy {
    public static let standard = HypothesisFusionPolicy(
        vocabulary: HypothesisFusionPolicy.Vocabulary(
            unitTerms: HypothesisFusionVocabulary.units,
            negationTerms: HypothesisFusionVocabulary.negations,
            polarityTerms: HypothesisFusionVocabulary.polarity,
            negationContractionSuffixes: ["n't"]),
        // 极性词走 `hasPolarity` 的独立 `.polarity` 待核路径；若同时列入 protectedTokenClasses，
        // 决策器会先判 `.protected`，丢失既有「极性」原因（2026-11-05 复活回归）。
        protectedTokenClasses: [.number, .unit, .negation],
        clauseFreezingTokenClasses: [.negation])
}
