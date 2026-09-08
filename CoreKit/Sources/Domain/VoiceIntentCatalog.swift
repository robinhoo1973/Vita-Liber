import Foundation

/// FR17.19 语音指令意图目录（function-spec V3.40；单一事实源）：
/// 每种数据录入/创建一种意图 = 一套槽位匹配模板（槽位 schema + 校验 +
/// 确认标签 + 落库路由）。目录为单一事实源：新增录入能力 = 目录加一行 +
/// 路由加一支，禁止自建确认逻辑。
///
/// 期一兜底轨（ADR-029）：自动匹配 = 文法首命中即分类（§3.2 语义），
/// 全零命中 → unknown（整句原文进语音速记，绝不静默丢弃）。
/// 期一能力边界（诚实标注，FR17.19）：仅 metric/reminder/profile 有文法
/// 证据可自动分类；observation/appointment/medDraft/question/assistant
/// 期一无独立文法，经确认卡 Menu 显式改类到达（期二备轨补分类能力）。
public enum VoiceIntentKey: String, Sendable, Equatable, CaseIterable, Codable {
    case recordMetric
    case recordObservation
    case createReminder
    case createAppointment
    case appendProfile
    case appendMedDraft
    case appendNote
    case askAssistant
    case createQuestion
    case unknown
}

/// 意图目录条目（槽位抽取随轨分期：期一=文法/启发式；期二/三=模型）。
public struct VoiceIntentEntry: Sendable, Equatable {
    public var key: VoiceIntentKey
    /// 确认标签（L10n 键语义，App 层映射）
    public var displayLabelKey: String
    /// 期一兜底轨是否可自动分类（有文法/启发式证据）
    public var classifiableFallback: Bool
    public init(key: VoiceIntentKey, displayLabelKey: String, classifiableFallback: Bool) {
        self.key = key
        self.displayLabelKey = displayLabelKey
        self.classifiableFallback = classifiableFallback
    }
}

/// FR17.19 目录与期一兜底轨分类器（Domain 纯函数，零资产恒可用）。
public enum VoiceIntentCatalog {
    /// 目录顺序 = 呈现顺序（FR17.19 首层单一事实源；「未知」恒居末位）。
    public static let entries: [VoiceIntentEntry] = [
        .init(key: .recordMetric, displayLabelKey: "voiceIntent.recordMetric", classifiableFallback: true),
        .init(key: .recordObservation, displayLabelKey: "voiceIntent.recordObservation", classifiableFallback: false),
        .init(key: .createReminder, displayLabelKey: "voiceIntent.createReminder", classifiableFallback: true),
        .init(key: .createAppointment, displayLabelKey: "voiceIntent.createAppointment", classifiableFallback: false),
        .init(key: .appendProfile, displayLabelKey: "voiceIntent.appendProfile", classifiableFallback: true),
        .init(key: .appendMedDraft, displayLabelKey: "voiceIntent.appendMedDraft", classifiableFallback: false),
        .init(key: .appendNote, displayLabelKey: "voiceIntent.appendNote", classifiableFallback: true),
        .init(key: .askAssistant, displayLabelKey: "voiceIntent.askAssistant", classifiableFallback: false),
        .init(key: .createQuestion, displayLabelKey: "voiceIntent.createQuestion", classifiableFallback: false),
        .init(key: .unknown, displayLabelKey: "voiceIntent.unknown", classifiableFallback: true),
    ]

    /// 兜底轨自动分类：三套既有文法并行抽取、命中数多者胜（FR17.19
    /// 「文法首命中即分类」；同命中数按目录序取先——指标 > 提醒 > 档案，
    /// 与 §5.54 三文法 max-hit 语义一致）。全零命中 → unknown
    /// （整句原文进速记草稿，FR17.19 unknown 兜底语义）。
    /// 返回：意图判定 + 槽位草稿（全 D 级，source=.regex）。
    public static func classify(_ text: String, confidence: Double) -> UnderstandingResult {
        let candidates: [(VoiceIntentKey, [FieldDraft])] = [
            (.recordMetric, VoiceStructuringEngine.extractMetric(text, rules: VoiceGrammarDefaults.metricRules)),
            (.createReminder, VoiceStructuringEngine.extractReminder(text, rules: VoiceGrammarDefaults.reminderRules)),
            (.appendProfile, VoiceStructuringEngine.extractProfile(text, rules: VoiceGrammarDefaults.profileRules)),
        ]
        // 最低证据门槛（期一质量护栏）：提醒意图仅凭相对日期词「今天」等
        // 单命中不成立——「今天天气不错」不得误判为提醒（需要小时/日期/
        // 重复等具体触发键之一，或 ≥2 个槽位）。其余意图零命中即不候选。
        let scored = candidates.filter { key, fields in
            !fields.isEmpty && (key != .createReminder
                || fields.count >= 2
                || fields.contains { ["hour", "date", "repeat"].contains($0.key) })
        }
        if let best = scored.max(by: { $0.1.count < $1.1.count }) {
            let fields = best.1.map { draft -> FieldDraft in
                var d = draft
                if d.source == nil { d.source = .regex }
                return d
            }
            // 文法命中置信度与转写置信度联乘，仍落在高置信档（≥0.7 预填一档）
            return UnderstandingResult(suggestedTarget: best.0.rawValue,
                                       targetConfidence: max(0.7, 0.85 * max(confidence, 0.3)),
                                       fields: fields)
        }
        // unknown：整句原文进速记草稿（调用方经 FR17.13 确认卡可编辑补全）
        let draft = VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)
        var marked = draft
        marked.source = .unknown
        return UnderstandingResult(suggestedTarget: VoiceIntentKey.unknown.rawValue,
                                   targetConfidence: 0.6,
                                   fields: [marked])
    }

    /// 显式改类后的槽位抽取（确认卡 Menu 覆盖；FR17.19 消歧兜底语义）。
    /// 期一无独立文法的意图回落纯文本草稿（原语义不变，不静默丢内容）。
    public static func extract(for key: VoiceIntentKey, text: String, confidence: Double) -> [FieldDraft] {
        let extracted: [FieldDraft]
        switch key {
        case .recordMetric:
            extracted = VoiceStructuringEngine.extractMetric(text, rules: VoiceGrammarDefaults.metricRules)
        case .createReminder:
            extracted = VoiceStructuringEngine.extractReminder(text, rules: VoiceGrammarDefaults.reminderRules)
        case .appendProfile:
            extracted = VoiceStructuringEngine.extractProfile(text, rules: VoiceGrammarDefaults.profileRules)
        case .recordObservation, .createAppointment, .appendMedDraft,
             .appendNote, .askAssistant, .createQuestion, .unknown:
            extracted = []
        }
        guard !extracted.isEmpty else {
            let draft = VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)
            var marked = draft
            marked.source = .unknown
            return [marked]
        }
        return extracted.map { draft -> FieldDraft in
            var d = draft
            if d.source == nil { d.source = .regex }
            return d
        }
    }
}
