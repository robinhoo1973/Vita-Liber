import Foundation

/// FR17.18 识别后文本共享理解层值对象（coreml-minilm-spec §3 契约单一事实源）：
/// F6 OCR 行文本与 F17 语音整句文本在识别出文本之后共用同一理解层——实体识别 +
/// 字段/意图分类 + 槽位结构化，产出统一 D 级 `FieldDraft` 汇 FR17.13 确认卡。
/// 期一（ADR-029）：端口 + 契约 + 兜底轨（正则/启发式 + F25 词表）+ 紧急前置 +
/// 负清单过滤；三轨同一端口上层零感知，识别后文本后处理两处不得独立演化。

/// 统一输入（§3.1）：一段文本 + 来源上下文。
public struct TextUnderstandingInput: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// F6：可选类型提示（仅用户显式指定时）；默认 nil——文档类型由本层
        /// 判定输出（D 级草稿），不前置指定（V1.3 去向前置）
        case ocr(documentTypeHint: String?)
        /// F17：可选意图预选 + 转写置信度（SFSpeechRecognizer 实测值 0..1；
        /// 缺省 0.9 向后兼容既有构造点。此前置信度被丢弃、引擎恒按 0.9 分类，
        /// 低置信转写永远过不了 <0.5 复核闸——BR-003 复核纪律被架空）
        case voice(intentHint: String? = nil, confidence: Double = 0.9)
    }
    /// OCR=整份拼接文本；语音=整句转写
    public var text: String
    /// OCR 专用：保留行结构（语音为 nil）
    public var lines: [String]?
    public var source: Source
    /// zh-Hans / zh-Hant / en …（显式传入，不靠自动检测——<20 字符不可靠，§8.7）
    public var locale: Locale.LanguageCode

    public init(text: String, lines: [String]? = nil, source: Source,
                locale: Locale.LanguageCode = .chinese) {
        self.text = text
        self.lines = lines
        self.source = source
        self.locale = locale
    }

    /// 语音来源携带的转写置信度（0..1；OCR 侧为 nil）
    public var transcriptionConfidence: Double? {
        switch source {
        case .voice(_, let confidence): return confidence
        case .ocr: return nil
        }
    }
}

/// 字段草稿产出轨（§3.2）：跨轨置信度不直接比较，仅作呈现标注（V1.8）。
public enum UnderstandingSource: String, Sendable, Equatable, Codable {
    case foundationModels   // 主轨：Foundation Models（iOS 26+ 门控，期三）
    case nlTagger           // 兜底轨：NaturalLanguage NER
    case nlModel            // 兜底轨：Create ML 自定义分类器（可选）
    case gazetteer          // 兜底轨：NLGazetteer 词表直配
    case f25CodeResolver    // F25 术语标准化（医疗槽位，全 iOS）
    case regex              // 兜底轨：既有正则文法（语音时间/指标）
    case heuristic          // 兜底：关键词启发式
    case unknown            // 未分类/未识别（保留原文）
}

/// 判定候选（primary/secondary 同形，§3.2 V1.8）。
public struct TargetCandidate: Sendable, Equatable {
    public var key: String                    // FR17.19 意图 key / doc_type 稳定键
    public var confidence: Double             // 0..1
    public var source: UnderstandingSource    // 产出轨
    public init(key: String, confidence: Double, source: UnderstandingSource) {
        self.key = key
        self.confidence = confidence
        self.source = source
    }
}

/// 理解层输出（§3.2 V1.4/V1.8）：会话草稿，全 D 级，BR-003 惰性。
public struct UnderstandingResult: Sendable, Equatable {
    /// 语音：意图判定候选（FR17.19 目录 key）；OCR：文档类型判定候选（稳定类型键）。
    /// nil = 无法判定（由调用方引导选择，§5「不预选数据去向」）
    public var suggestedTarget: String?
    /// 0..1；<0.5 视为低置信 → 引导选择（§3.2）
    public var targetConfidence: Double
    /// OCR 多类候选：仅作确认卡引导与识别运行记录检索标签，
    /// 不决定模板路由与 doc_type 持久化（FR6.2 V3.49）
    public var secondaryTargets: [TargetCandidate]
    /// 确认卡唯一消费形（全 D 级）
    public var fields: [FieldDraft]
    /// OCR 专用：已命中语义字段的**行下标**（供调用方对未命中行做 line_N
    /// 兜底而不必重跑启发式抽取——此前引擎算完即弃 `_ = claimed`，App 层
    /// 被迫复制同一套 guessFields 循环，两处独立演化即字段漂移）
    public var claimedLineIndices: Set<Int>

    public init(suggestedTarget: String?, targetConfidence: Double,
                secondaryTargets: [TargetCandidate] = [], fields: [FieldDraft],
                claimedLineIndices: Set<Int> = []) {
        self.suggestedTarget = suggestedTarget
        self.targetConfidence = targetConfidence
        self.secondaryTargets = secondaryTargets
        self.fields = fields
        self.claimedLineIndices = claimedLineIndices
    }
}

/// F25 医疗槽位惰性接线（coreml-minilm-spec §4.3 三纪律：BR-003 惰性 /
/// 绝不猜码 / 覆盖表恒胜）——单一实现两处受益（OCR + 语音，§6.3）。
/// 挂点纪律（§4.3）：医疗槽位在进确认卡前一律过本函数，编码挂
/// `FieldDraft.codeResolution` 惰性建议；升 C 前不入任何事实链。
public enum UnderstandingCodeResolution {
    /// 医疗槽位键族（语音文法指标键与 OCR 药名/项目键）。不在族内的
    /// 字段原样透传（非医疗槽位不引码，FR25.12 负清单纪律）。
    public static let medicalSlotKeys: Set<String> = [
        "heart_rate", "blood_oxygen", "respiratory_rate", "blood_pressure_sys",
        "blood_pressure_dia", "temperature", "drug_name", "lab_item",
    ]

    /// 逐字段解析；无命中保留原值（nil 编码建议），绝不猜码。
    public static func resolve(_ fields: [FieldDraft], locale: Locale,
                               index: any CodeIndex,
                               units: any UnitIndex) async -> [FieldDraft] {
        var out: [FieldDraft] = []
        for field in fields {
            guard Self.medicalSlotKeys.contains(field.key) else {
                out.append(field)
                continue
            }
            var resolved = field
            do {
                // lab_item 载荷为「名称 数值」合体（确认卡编辑形态）——先拆
                // 名称/数值：合体串别名不命中且 Double(合体) 恒 nil，此前
                // 接线恒空转（名称别名与读数联合解析双双落空）。
                let (name, number) = splitReading(field.value)
                if let unit = field.unit, !unit.isEmpty, let number {
                    // FR25.2 读数联合解析**优先**：单位参与定码（mmol/L 读数
                    // 必须建议 c-glu-molar 而非名称直配命中的质量码——此前
                    // resolve(name) 先命中即短路，unitSpecificConcept 永不
                    // 执行、单位特异种子成死数据）
                    let reading = try await CodeResolver.resolveReading(
                        raw: name, value: number, unit: unit,
                        locale: locale, index: index, units: units)
                    resolved.codeResolution = reading.resolution
                    if resolved.codeResolution != nil, resolved.source == nil {
                        resolved.source = .f25CodeResolver
                    }
                } else if let code = try await CodeResolver.resolve(name, locale: locale, index: index) {
                    resolved.codeResolution = code
                    if resolved.source == nil { resolved.source = .f25CodeResolver }
                }
            } catch {
                // F25 失败不阻断理解主流程：编码是惰性建议，无编码仍可确认
            }
            out.append(resolved)
        }
        return out
    }

    /// 「名称 数值」合体载荷 → (名称, 数值串)。尾段空白分隔组件可 Double
    /// 解析即视为数值；纯数值/纯名称返回 (原串, nil/原串)。
    static func splitReading(_ value: String) -> (name: String, number: String?) {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard parts.count > 1, let last = parts.last, Double(last) != nil else {
            return (value, nil)
        }
        return (parts.dropLast().joined(separator: " "), String(last))
    }
}
