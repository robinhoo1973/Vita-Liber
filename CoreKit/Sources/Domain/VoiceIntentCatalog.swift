import Foundation

/// FR17.19 语音指令意图目录（function-spec V3.40；单一事实源）：
/// 每种数据录入/创建一种意图 = 一套槽位匹配模板（槽位 schema + 校验 +
/// 确认标签 + 落库路由）。目录为单一事实源：新增录入能力 = 目录加一行 +
/// 路由加一支，禁止自建确认逻辑。
///
/// 期一兜底轨（ADR-029）：自动匹配 = 文法首命中即分类（§3.2 语义），
/// 全零命中 → unknown（整句原文进语音速记，绝不静默丢弃）。
/// 期一能力边界（诚实标注，FR17.19）：metric/reminder/profile 有文法证据
/// 可自动分类；observation/appointment/question 期一无独立文法，经确认卡
/// Menu 显式改类到达（期二备轨补分类能力）。**appendMedDraft 例外
/// （2026-09-21 词表锚定轮，FR25.12⑪）**：用药草稿槽位由词表证据补齐——
/// 显式改类经 `extract(for:lexicon:)` 填药名/剂型/途径/频次；未判定/速记
/// 两态在证据充分（精确药名命中或 ≥2 伴随槽位）时经
/// `VoiceLexiconAnchoring.integrate` 自动升为用药草稿。
public enum VoiceIntentKey: String, Sendable, Equatable, CaseIterable, Codable {
    case recordMetric
    case recordObservation
    case createReminder
    case createAppointment
    case appendProfile
    case appendMedDraft
    case appendNote
    // 业主裁决 D2（2026-09-18）：F12 AI 助手永久退役——.askAssistant 意图已从
    // 目录删除；历史 rawValue 落入 unknown 兜底（速记），不再有「退役无响应」分支。
    case createQuestion
    case unknown
}

/// 意图目录条目（槽位抽取随轨分期：期一=文法/启发式；期二/三=模型）。
/// FR17.19 契约字段：槽位 schema + 落库路由 + 确认标签（`VoiceActionContract`）。
public struct VoiceIntentEntry: Sendable, Equatable {
    public var key: VoiceIntentKey
    /// 确认标签（L10n 键语义，App 层映射）
    public var displayLabelKey: String
    /// 期一兜底轨是否可自动分类（有文法/启发式证据）
    public var classifiableFallback: Bool
    /// 槽位定义（空 = 该意图无结构化槽位，仅走原文/引导）。
    public var slots: [VoiceSlotSpec]
    /// 组内至少命中一个即满足（如提醒的时间三键、指标的任一指标键）。
    public var requiredAnyOfKeys: [String]
    /// 落点路由。
    public var route: VoiceActionRoute
    /// 确认卡主按钮标签（L10n 键语义）。
    public var confirmationLabelKey: String
    /// 整句原文可直填的主文本槽（观察描述/问诊问题/用药草稿/速记）。
    /// nil = 原文不可冒充结构化槽位（如预约医院/科室）。
    public var primaryTextSlotKey: String?

    public init(key: VoiceIntentKey, displayLabelKey: String, classifiableFallback: Bool,
                slots: [VoiceSlotSpec] = [], requiredAnyOfKeys: [String] = [],
                route: VoiceActionRoute = .note,
                confirmationLabelKey: String? = nil,
                primaryTextSlotKey: String? = nil) {
        self.key = key
        self.displayLabelKey = displayLabelKey
        self.classifiableFallback = classifiableFallback
        self.slots = slots
        self.requiredAnyOfKeys = requiredAnyOfKeys
        self.route = route
        self.confirmationLabelKey = confirmationLabelKey ?? "\(displayLabelKey).confirm"
        self.primaryTextSlotKey = primaryTextSlotKey
    }
}

/// FR17.19 目录与期一兜底轨分类器（Domain 纯函数，零资产恒可用）。
public enum VoiceIntentCatalog {
    /// 槽位构造助手：优先级从 1 起，数值小者先问。
    private static func slot(_ key: String, _ type: VoiceSlotValueType,
                             required: Bool = false, priority: Int = 1,
                             label: String) -> VoiceSlotSpec {
        VoiceSlotSpec(key: key, type: type, required: required,
                      priority: priority, displayLabelKey: label)
    }

    /// 目录顺序 = 呈现顺序（FR17.19 首层单一事实源；「未知」恒居末位）。
    /// 槽位 schema 与落点路由同表定义（新增能力 = 目录加一行 + 路由加一支）。
    public static let entries: [VoiceIntentEntry] = [
        .init(key: .recordMetric, displayLabelKey: "voiceIntent.recordMetric",
              classifiableFallback: true,
              slots: [
                slot("glucose", .number, label: "voiceSlot.metric"),
                slot("blood_pressure_sys", .number, label: "voiceSlot.metric"),
                slot("blood_pressure_dia", .number, label: "voiceSlot.metric"),
                slot("heart_rate", .number, label: "voiceSlot.metric"),
                slot("weight", .number, label: "voiceSlot.metric"),
                slot("blood_oxygen", .number, label: "voiceSlot.metric"),
                slot("temperature", .number, label: "voiceSlot.metric"),
              ],
              requiredAnyOfKeys: ["glucose", "blood_pressure_sys", "blood_pressure_dia",
                                  "heart_rate", "weight", "blood_oxygen", "temperature"],
              route: .metric),
        .init(key: .recordObservation, displayLabelKey: "voiceIntent.recordObservation",
              classifiableFallback: false,
              slots: [
                slot("description", .text, required: true, priority: 1, label: "voiceSlot.description"),
                slot("observationType", .text, priority: 2, label: "voiceSlot.observationType"),
                slot("trend", .text, priority: 3, label: "voiceSlot.trend"),
              ],
              route: .observation, primaryTextSlotKey: "description"),
        .init(key: .createReminder, displayLabelKey: "voiceIntent.createReminder",
              classifiableFallback: true,
              slots: [
                slot("time", .time, priority: 1, label: "voiceSlot.time"),
                slot("date", .date, priority: 1, label: "voiceSlot.time"),
                slot("hour", .time, priority: 1, label: "voiceSlot.time"),
                slot("content", .text, required: true, priority: 2, label: "voiceSlot.content"),
                slot("repeat", .text, priority: 3, label: "voiceSlot.repeat"),
              ],
              requiredAnyOfKeys: ["time", "date", "hour"],
              route: .reminder, primaryTextSlotKey: "content"),
        .init(key: .createAppointment, displayLabelKey: "voiceIntent.createAppointment",
              classifiableFallback: false,
              slots: [
                slot("hospital", .text, required: true, priority: 1, label: "voiceSlot.hospital"),
                slot("department", .text, required: true, priority: 2, label: "voiceSlot.department"),
                slot("time", .time, priority: 3, label: "voiceSlot.time"),
                slot("date", .date, priority: 3, label: "voiceSlot.time"),
                slot("hour", .time, priority: 3, label: "voiceSlot.time"),
                slot("doctor", .text, priority: 4, label: "voiceSlot.doctor"),
                slot("content", .text, priority: 5, label: "voiceSlot.content"),
              ],
              // 时间不在计划层强制：预约表单用显式 DatePicker 落具体时刻（FR10.2），
              // time/date/hour 仅作参考槽；强制必填会制造无法确认的空占位死路。
              requiredAnyOfKeys: [],
              route: .appointment, primaryTextSlotKey: nil),
        .init(key: .appendProfile, displayLabelKey: "voiceIntent.appendProfile",
              classifiableFallback: true,
              slots: [
                slot("allergy", .text, label: "voiceSlot.allergy"),
                slot("pastHistory", .text, label: "voiceSlot.pastHistory"),
                slot("currentMeds", .text, label: "voiceSlot.currentMeds"),
                slot("emergencyContact", .text, label: "voiceSlot.emergencyContact"),
                slot("surgery", .text, label: "voiceSlot.surgery"),
                slot("familyHistory", .text, label: "voiceSlot.familyHistory"),
              ],
              requiredAnyOfKeys: ["allergy", "pastHistory", "currentMeds",
                                  "emergencyContact", "surgery", "familyHistory"],
              route: .profile),
        .init(key: .appendMedDraft, displayLabelKey: "voiceIntent.appendMedDraft",
              classifiableFallback: false,
              slots: [
                slot("medicationName", .text, required: true, priority: 1,
                     label: "voiceSlot.medicationName"),
                slot("dosageForm", .text, priority: 2, label: "voiceSlot.dosageForm"),
                slot("route", .text, priority: 3, label: "voiceSlot.route"),
                slot("frequency", .text, priority: 4, label: "voiceSlot.frequency"),
              ],
              route: .medDraft, primaryTextSlotKey: "medicationName"),
        .init(key: .appendNote, displayLabelKey: "voiceIntent.appendNote",
              classifiableFallback: true,
              slots: [slot("note", .text, required: true, label: "voiceSlot.note")],
              route: .note, primaryTextSlotKey: "note"),
        .init(key: .createQuestion, displayLabelKey: "voiceIntent.createQuestion",
              classifiableFallback: false,
              slots: [slot("question", .text, required: true, label: "voiceSlot.question")],
              route: .question, primaryTextSlotKey: "question"),
        .init(key: .unknown, displayLabelKey: "voiceIntent.unknown",
              classifiableFallback: true,
              slots: [slot("note", .text, required: true, label: "voiceSlot.note")],
              route: .note, primaryTextSlotKey: "note"),
    ]

    /// 目录查询单一出口（未登记 key → unknown 条目，绝不崩）。
    public static func entry(for key: VoiceIntentKey) -> VoiceIntentEntry {
        if let entry = entries.first(where: { $0.key == key }) { return entry }
        return entries.first(where: { $0.key == .unknown })
            ?? VoiceIntentEntry(key: .unknown, displayLabelKey: "voiceIntent.unknown",
                                classifiableFallback: true,
                                slots: [slot("note", .text, required: true, label: "voiceSlot.note")],
                                route: .note, primaryTextSlotKey: "note")
    }

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
            // 文法命中置信度与转写置信度联乘——不再设 ≥0.7 保底：实测转写
            // 置信度接入后低置信必须可落在 <0.5 档触发确认卡复核闸
            // （此前恒 0.9 输入 + 0.7 保底 = <0.5 低置信警示永远不可达，
            // BR-003 复核纪律被架空）
            return UnderstandingResult(suggestedTarget: best.0.rawValue,
                                       targetConfidence: 0.85 * max(confidence, 0.3),
                                       fields: regexMarked(best.1))
        }
        // unknown：整句原文进速记草稿（调用方经 FR17.13 确认卡可编辑补全）
        return UnderstandingResult(suggestedTarget: VoiceIntentKey.unknown.rawValue,
                                   targetConfidence: 0.6,
                                   fields: [unknownFallback(text, confidence: confidence)])
    }

    /// 文法产出槽位统一标 source=.regex（classify / extract 两处入口共用）。
    private static func regexMarked(_ drafts: [FieldDraft]) -> [FieldDraft] {
        drafts.map { draft -> FieldDraft in
            var d = draft
            if d.source == nil { d.source = .regex }
            return d
        }
    }

    /// unknown 兜底草稿（整句原文进速记、source=.unknown）——两处入口共用。
    private static func unknownFallback(_ text: String, confidence: Double) -> FieldDraft {
        var marked = VoiceInputTemplate.fallbackDraft(value: text, confidence: confidence)
        marked.source = .unknown
        return marked
    }

    /// 显式改类后的槽位抽取（确认卡 Menu 覆盖；FR17.19 消歧兜底语义）。
    /// 期一无独立文法的意图回落纯文本草稿（原语义不变，不静默丢内容）。
    /// `lexicon`（FR25.12⑪，2026-09-21）：用药草稿改类时按词表证据补槽位
    /// （此前恒回落整句原文草稿，药名/剂型/途径/频次全部丢失）；原文草稿
    /// 恒保持首位——`.anyText` 分发只取 first 落速记正文（BR-002 不丢内容）。
    public static func extract(for key: VoiceIntentKey, text: String, confidence: Double,
                               lexicon: MedicalLexicon? = nil) -> [FieldDraft] {
        let extracted: [FieldDraft]
        switch key {
        case .recordMetric:
            extracted = VoiceStructuringEngine.extractMetric(text, rules: VoiceGrammarDefaults.metricRules)
        case .createReminder:
            extracted = VoiceStructuringEngine.extractReminder(text, rules: VoiceGrammarDefaults.reminderRules)
        case .appendProfile:
            extracted = VoiceStructuringEngine.extractProfile(text, rules: VoiceGrammarDefaults.profileRules)
        case .appendMedDraft:
            // FR25.12⑪ 词表锚定：用药槽位由词表证据补齐（精确命中优先，
            // 近失配仅候选）；词表不可用或零命中 → 回落整句原文草稿。
            extracted = lexicon.map {
                VoiceLexiconAnchoring.anchor(text, lexicon: $0).drafts
            } ?? []
            if !extracted.isEmpty {
                return [unknownFallback(text, confidence: confidence)] + regexMarked(extracted)
            }
        case .recordObservation, .createAppointment,
             .appendNote, .createQuestion, .unknown:
            extracted = []
        }
        guard !extracted.isEmpty else { return [unknownFallback(text, confidence: confidence)] }
        return regexMarked(extracted)
    }
}
