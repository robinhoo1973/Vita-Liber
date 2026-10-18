import Foundation

/// FR17.19 语音/文本任务助手的可执行契约（B1 确定性路径）。
///
/// 本文件只放纯类型与纯函数（Domain 仅 import Foundation）：
/// - 意图目录的槽位 schema（数量、必填、优先级）；
/// - 一次理解结果生成的 `VoiceActionPlan`（全 D 级草稿，BR-003）；
/// - 用户显式确认后才可生成的 `VerifiedAction`（模型永不直接执行）；
/// - 补槽最多一次的脚本化规则（FR17.5/FR17.8，不构成自由对话）。
///
/// UI 仍以 `OcrConfirmationSet` 为唯一确认映射（FR17.13）；本契约不新建确认 UI，
/// 也不替代 `VoiceInputTemplate.confirmationSet`。

/// 意图的落点路由（App 层映射到 `AppRoute`；Domain 不依赖导航类型）。
public enum VoiceActionRoute: String, Sendable, Equatable, CaseIterable, Codable {
    case metric
    case observation
    case reminder
    case appointment
    case profile
    case medDraft
    case question
    case note
}

/// 槽位值类型（仅用于校验与呈现提示，不做隐式单位换算）。
public enum VoiceSlotValueType: String, Sendable, Equatable, Codable {
    case text
    case number
    case date
    case time
    case enumeration
}

/// 意图目录中的槽位定义（FR17.19「槽位 schema + 校验 + 确认标签 + 落库路由」）。
public struct VoiceSlotSpec: Sendable, Equatable, Codable {
    public var key: String
    public var type: VoiceSlotValueType
    /// 必填槽位缺失时允许一次脚本化追问；非必填缺失进确认卡空字段。
    public var required: Bool
    /// 追问优先级：数值小者先问（同一计划最多追问一次）。
    public var priority: Int
    /// 槽位显示标签（L10n 键语义，App 层映射）。
    public var displayLabelKey: String

    public init(key: String, type: VoiceSlotValueType, required: Bool,
                priority: Int, displayLabelKey: String) {
        self.key = key; self.type = type; self.required = required
        self.priority = priority; self.displayLabelKey = displayLabelKey
    }
}

/// 计划来源：三入口共用同一文本理解层（FR17.18）。
public enum VoiceActionSource: String, Sendable, Equatable, Codable {
    case voice
    case text
    case ocr
}

/// 计划阶段徽章：确认前恒 D，确认后升 C（BR-003；本契约不产生别的级别）。
public enum VoicePlanGrade: String, Sendable, Equatable, Codable {
    case draft
    case confirmed
}

/// 风险标记：只做「不生成可执行动作」的降级，不做医学判断。
public enum VoiceRiskFlag: String, Sendable, Equatable, Codable {
    /// BR-012：急救关键词命中 → 走急救卡，不生成动作。
    case emergency
    /// BR-006：停药/调量/换药类 → 拒识，不生成动作。
    case highRiskTopic
    /// 目录外意图/资格不足 → 不生成动作。
    case forbiddenAction
}

/// 计划中的槽位值（保留原文与来源，BR-002/BR-003）。
public struct VoiceSlotValue: Sendable, Equatable {
    public var key: String
    public var value: String
    public var unit: String?
    /// 识别原文（nil 时等于 value）；拒绝字段不得进入任何事实链。
    public var rawText: String
    public var confidence: Double
    public var isValid: Bool

    public init(key: String, value: String, unit: String? = nil,
                rawText: String, confidence: Double, isValid: Bool = true) {
        self.key = key; self.value = value; self.unit = unit
        self.rawText = rawText; self.confidence = confidence; self.isValid = isValid
    }
}

/// 一次理解的完整草稿（确认前 D 级；不可直接执行）。
public struct VoiceActionPlan: Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var planId: UUID
    public var patientId: UUID
    public var source: VoiceActionSource
    public var intent: VoiceIntentKey
    public var transcript: String
    public var slots: [VoiceSlotValue]
    /// 必填槽位缺失键（按追问优先级排序；含 requiredAnyOf 组的代表键）。
    public var missingRequiredKeys: [String]
    /// 已发起的脚本化追问次数（硬上限 1，FR17.5/FR17.8）。
    public var clarificationCount: Int
    public var grade: VoicePlanGrade
    public var confirmationId: UUID?
    public var riskFlags: Set<VoiceRiskFlag>
    public var createdAt: Date
    public var expiresAt: Date

    public init(schemaVersion: Int = VoiceActionPlan.currentSchemaVersion,
                planId: UUID, patientId: UUID, source: VoiceActionSource,
                intent: VoiceIntentKey, transcript: String,
                slots: [VoiceSlotValue], missingRequiredKeys: [String],
                clarificationCount: Int, grade: VoicePlanGrade,
                confirmationId: UUID? = nil, riskFlags: Set<VoiceRiskFlag>,
                createdAt: Date, expiresAt: Date) {
        self.schemaVersion = schemaVersion; self.planId = planId
        self.patientId = patientId; self.source = source; self.intent = intent
        self.transcript = transcript; self.slots = slots
        self.missingRequiredKeys = missingRequiredKeys
        self.clarificationCount = clarificationCount; self.grade = grade
        self.confirmationId = confirmationId; self.riskFlags = riskFlags
        self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    public var isExpired: Bool { Date() >= expiresAt }

    /// 可执行资格：确认后、无缺失、无红线风险、未过期。
    public func canExecute(at now: Date = Date()) -> Bool {
        grade == .confirmed && missingRequiredKeys.isEmpty
            && !riskFlags.contains(.emergency)
            && !riskFlags.contains(.highRiskTopic)
            && !riskFlags.contains(.forbiddenAction)
            && now < expiresAt
    }

    public func slotValue(for key: String) -> VoiceSlotValue? {
        slots.first { $0.key == key }
    }

    /// 计划槽位 → 确认卡草稿（FR17.13 唯一映射入口仍由
    /// `VoiceInputTemplate.confirmationSet` 承担；此处只做形态转换）。
    public var fieldDrafts: [FieldDraft] {
        slots.map { slot in
            FieldDraft(key: slot.key, value: slot.value, unit: slot.unit,
                       confidence: slot.confidence, rawText: slot.rawText)
        }
    }
}

/// 已确认、可交给仓储执行的单一动作（模型无权直接生成）。
public struct VerifiedAction: Sendable, Equatable {
    public var actionId: UUID
    public var kind: VoiceActionKind
    public var patientId: UUID
    public var sourcePlanId: UUID
    public var confirmationId: UUID
    public var idempotencyKey: String
    public var slotValues: [String: String]
    public var rawTranscript: String
    public var actor: String

    public init(actionId: UUID = UUID(), kind: VoiceActionKind, patientId: UUID,
                sourcePlanId: UUID, confirmationId: UUID, idempotencyKey: String,
                slotValues: [String: String], rawTranscript: String, actor: String) {
        self.actionId = actionId; self.kind = kind; self.patientId = patientId
        self.sourcePlanId = sourcePlanId; self.confirmationId = confirmationId
        self.idempotencyKey = idempotencyKey; self.slotValues = slotValues
        self.rawTranscript = rawTranscript; self.actor = actor
    }
}

/// 动作执行审计载荷（V11–V16）：只记结构性元数据，零 PHI。
/// 由确认后的 `VerifiedAction` 构造；仓储在同一事务内写入 `audit_event`。
public struct VoiceExecutionAudit: Sendable, Equatable {
    public let planId: UUID
    public let confirmationId: UUID
    public let intent: VoiceIntentKey
    public let actionKind: VoiceActionKind
    public let idempotencyKey: String
    public let actorLocal: String
    public let slotKeys: [String]
    public let source: VoiceActionSource

    public init(plan: VoiceActionPlan, action: VerifiedAction, actor: String) {
        self.planId = plan.planId
        self.confirmationId = action.confirmationId
        self.intent = plan.intent
        self.actionKind = action.kind
        self.idempotencyKey = action.idempotencyKey
        self.actorLocal = actor
        self.slotKeys = plan.slots.map(\.key).sorted()
        self.source = plan.source
    }

    /// 审计 meta：intent/actionKind/slotKeys/candidateCount/来源/计划与确认 ID。
    /// 不含转写全文、药名、数值、患者姓名或任何自由文本。
    public var metaJSON: String {
        let object: [String: Any] = [
            "intent": intent.rawValue,
            "actionKind": actionKind.rawValue,
            "slotKeys": slotKeys,
            "candidateCount": 0,
            "source": source.rawValue,
            "planId": planId.uuidString,
            "confirmationId": confirmationId.uuidString,
            "idempotencyKey": idempotencyKey,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), // try?-ok: 纯字符串/整数元数据编码不可抛
              let text = String(data: data, encoding: .utf8) else { return "{}" } // 纯结构编码，失败按空元数据
        return text
    }
}

/// 动作闭集：与意图目录一一对应；`unknown` 只能落速记。
public enum VoiceActionKind: String, Sendable, Equatable, CaseIterable, Codable {
    case recordMetric
    case recordObservation
    case createReminder
    case createAppointment
    case appendProfile
    case appendMedDraft
    case appendNote
    case createQuestion
}

/// 计划器：理解结果 → 计划 → 补槽 → 确认 → VerifiedAction。
/// 全部纯函数；不触碰仓储、不读时钟以外的外部状态（now 由调用方注入）。
public enum VoiceActionPlanner {
    /// 计划有效期：跨页面/跨确认卡停留的短窗口，过期即不可执行。
    public static let planTTL: TimeInterval = 600
    /// 脚本化追问硬上限（FR17.5、FR17.8）。
    public static let maxClarifications = 1

    public static func plan(intentKey: String, transcript: String,
                            drafts: [FieldDraft], patientId: UUID,
                            source: VoiceActionSource,
                            clarificationCount: Int = 0,
                            now: Date = Date()) -> VoiceActionPlan {
        let intent = VoiceIntentKey(rawValue: intentKey) ?? .unknown
        let entry = VoiceIntentCatalog.entry(for: intent)
        var slots = drafts.map { draft in
            VoiceSlotValue(key: draft.key, value: draft.value, unit: draft.unit,
                           rawText: draft.rawText ?? draft.value,
                           confidence: draft.confidence,
                           isValid: !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // 速记/未知：整句原文进 note 槽（绝不静默丢弃，FR17.19）。
        if intent == .unknown || intent == .appendNote, slots.isEmpty {
            slots = [VoiceSlotValue(key: "note", value: transcript,
                                    rawText: transcript, confidence: 1.0)]
        }
        // 整句原文可直填的主文本槽（观察描述/问诊问题/用药草稿）：只做键归位，
        // 不做结构化改写；预约医院/科室等不允许原文冒充（primaryTextSlotKey=nil）。
        if let primary = entry.primaryTextSlotKey,
           !slots.contains(where: { $0.key == primary }),
           let noteIndex = slots.firstIndex(where: { $0.key == "note" }) {
            slots[noteIndex].key = primary
        }
        var risk: Set<VoiceRiskFlag> = []
        if EmergencyKeywordRules.match(transcript) { risk.insert(.emergency) }
        if HighRiskTopicRules.match(transcript) { risk.insert(.highRiskTopic) }
        // 确认值可能被编辑（用户改字/改类后重建）：槽值也要复扫，
        // 不能只信原始 transcript（BR-006 纵深防御）。
        let slotText = slots.map { "\($0.value)\n\($0.rawText)" }.joined(separator: "\n")
        if EmergencyKeywordRules.match(slotText) { risk.insert(.emergency) }
        if HighRiskTopicRules.match(slotText) { risk.insert(.highRiskTopic) }
        var missing = missingRequiredKeys(entry: entry, slots: slots)
        // 缺失必填以空槽进入确认卡（用户可手填，手填即确认，FR6.9④）。
        for key in missing where !slots.contains(where: { $0.key == key }) {
            slots.append(VoiceSlotValue(key: key, value: "", unit: nil, rawText: "",
                                        confidence: 0, isValid: false))
        }
        missing = missingRequiredKeys(entry: entry, slots: slots)
        return VoiceActionPlan(planId: UUID(), patientId: patientId, source: source,
                               intent: intent, transcript: transcript, slots: slots,
                               missingRequiredKeys: missing,
                               clarificationCount: min(clarificationCount, maxClarifications),
                               grade: .draft, riskFlags: risk,
                               createdAt: now, expiresAt: now.addingTimeInterval(planTTL))
    }

    /// 脚本化补槽：是否有资格追问 + 问哪一个（最高优先级的缺失必填槽）。
    public static func nextClarification(for plan: VoiceActionPlan) -> VoiceSlotSpec? {
        guard plan.grade == .draft, plan.clarificationCount < maxClarifications,
              let key = plan.missingRequiredKeys.first else { return nil }
        return VoiceIntentCatalog.entry(for: plan.intent).slots.first { $0.key == key }
    }

    /// 用户回答追问：只补一个槽位，然后重算缺失（不改变意图、不追加第二个追问）。
    public static func filling(_ plan: VoiceActionPlan, key: String,
                               value: String, now: Date = Date()) -> VoiceActionPlan {
        var updated = plan
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = updated.slots.firstIndex(where: { $0.key == key }) {
            updated.slots[index] = VoiceSlotValue(key: key, value: trimmed,
                                                  unit: updated.slots[index].unit,
                                                  rawText: trimmed, confidence: 1.0,
                                                  isValid: !trimmed.isEmpty)
        } else {
            updated.slots.append(VoiceSlotValue(key: key, value: trimmed, rawText: trimmed,
                                                confidence: 1.0, isValid: !trimmed.isEmpty))
        }
        updated.clarificationCount = min(updated.clarificationCount + 1, maxClarifications)
        updated.missingRequiredKeys = missingRequiredKeys(
            entry: VoiceIntentCatalog.entry(for: plan.intent), slots: updated.slots)
        updated.createdAt = now
        updated.expiresAt = now.addingTimeInterval(planTTL)
        return updated
    }

    /// 显式确认（确认卡唯一出口）：D → C。确认 ID 由调用方提供，用于审计串联。
    /// **过期计划不得确认**：TTL 是防「确认卡长时间停留后被旧计划执行」的硬门；
    /// 确认不重置 TTL（重新理解/重新编辑才产生新计划）。
    public static func confirming(_ plan: VoiceActionPlan, confirmationId: UUID,
                                  now: Date = Date()) -> VoiceActionPlan {
        guard now < plan.expiresAt else { return plan }
        var updated = plan
        updated.grade = .confirmed
        updated.confirmationId = confirmationId
        return updated
    }

    /// 确认后生成唯一动作；任何资格不足都返回空数组（宁可不执行）。
    /// 动作 + 审计必须在同一事务内（由仓储层落实，见 tech-spec ADR-035）。
    public static func verifiedActions(for plan: VoiceActionPlan,
                                       confirmationId: UUID,
                                       actor: String = "owner",
                                       now: Date = Date()) -> [VerifiedAction] {
        guard plan.canExecute(at: now), plan.confirmationId == confirmationId,
              let kind = actionKind(for: plan.intent) else { return [] }
        var values: [String: String] = [:]
        for slot in plan.slots where slot.isValid {
            values[slot.key] = slot.value
        }
        return [VerifiedAction(kind: kind, patientId: plan.patientId,
                               sourcePlanId: plan.planId, confirmationId: confirmationId,
                               idempotencyKey: "\(plan.planId.uuidString):\(kind.rawValue)",
                               slotValues: values,
                               rawTranscript: plan.transcript, actor: actor)]
    }

    public static func actionKind(for intent: VoiceIntentKey) -> VoiceActionKind? {
        switch intent {
        case .recordMetric: return .recordMetric
        case .recordObservation: return .recordObservation
        case .createReminder: return .createReminder
        case .createAppointment: return .createAppointment
        case .appendProfile: return .appendProfile
        case .appendMedDraft: return .appendMedDraft
        case .appendNote: return .appendNote
        case .createQuestion: return .createQuestion
        case .unknown: return .appendNote
        }
    }

    /// 缺失必填：逐槽 required + requiredAnyOf 组（组内全缺时以组首键代表）。
    static func missingRequiredKeys(entry: VoiceIntentEntry,
                                    slots: [VoiceSlotValue]) -> [String] {
        var missing: [String] = []
        for spec in entry.slots where spec.required {
            let present = slots.contains { $0.key == spec.key && $0.isValid }
            if !present { missing.append(spec.key) }
        }
        if !entry.requiredAnyOfKeys.isEmpty {
            let present = entry.requiredAnyOfKeys.contains { key in
                slots.contains { $0.key == key && $0.isValid }
            }
            if !present, let first = entry.requiredAnyOfKeys.first {
                missing.append(first)
            }
        }
        let order = Dictionary(uniqueKeysWithValues:
            entry.slots.enumerated().map { ($0.element.key, $0.element.priority) })
        return missing.sorted { (order[$0] ?? Int.max) < (order[$1] ?? Int.max) }
    }
}
