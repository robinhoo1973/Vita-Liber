import Foundation

/// BR-003 / tech-spec §5.3：机器识别的字段 = 草稿（D 级），必须逐字段确认才生效。
/// 确认后锁为 C 级；修订产生历史（FR6.4 语义的 M1a 切片：改一条留一条历史）。
public enum SourceGrade: String, Sendable, Equatable, Codable {
    case ocrUnconfirmed   // D 机器识别未确认
    case userConfirmed    // C 用户确认
    case rejected
}

public struct CandidateField: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var key: String          // 如 drug_name / dosage / frequency
    public var displayLabel: String // UI 展示键（L10n 键语义，M1a 中文直填）
    public var rawText: String      // OCR 原文（A 级素材，不可被编辑覆盖）
    public var value: String        // 确认后的取值
    public var confidence: Double   // 0..1
    public var grade: SourceGrade
    public var revisionHistory: [String]  // 旧值列表（新→旧）

    public init(id: UUID = UUID(), key: String, displayLabel: String, rawText: String,
                confidence: Double, value: String? = nil, grade: SourceGrade = .ocrUnconfirmed) {
        self.id = id
        self.key = key
        self.displayLabel = displayLabel
        self.rawText = rawText
        self.value = value ?? rawText
        self.confidence = confidence
        self.grade = grade
        self.revisionHistory = []
    }

    public var isConfirmed: Bool { grade == .userConfirmed }

    /// 确认：从 D 升格 C。已拒绝的字段不得直接确认（先重新启用语义留给完整状态机）。
    public mutating func confirm() -> Bool {
        guard grade == .ocrUnconfirmed else { return false }
        grade = .userConfirmed
        return true
    }

    /// 修订（FR6.4）：确认态字段改值 → 旧值入历史（谁改的、何时、改成什么——
    /// 历史条目格式「旧值 → 新值 · 修改人 · 时间」）。未确认字段直接改。
    public mutating func revise(to newValue: String, by actor: String = "owner",
                                at date: Date = Date()) -> Bool {
        guard newValue != value else { return false }
        if isConfirmed {
            let stamp = ISO8601DateFormatter().string(from: date)
            revisionHistory.insert("\(value) → \(newValue) · \(actor) · \(stamp)", at: 0)
        }
        value = newValue
        return true
    }

    public mutating func reject() {
        grade = .rejected
    }
}

/// 置信度三档（tech §5.2/5.3）：高/中/低，低档强制确认卡片醒目呈现。
public enum ConfidenceTier: String, Sendable, Equatable {
    case high, mid, low
    public static func tier(_ c: Double) -> ConfidenceTier {
        c >= 0.8 ? .high : (c >= 0.5 ? .mid : .low)
    }
}

/// 一份 OCR 结果的确认工作台：所有字段确认前，文档不得入时间轴正式区（BR-003）。
public struct OcrConfirmationSet: Sendable, Equatable, Codable, Identifiable {
    public var documentId: UUID
    public var fields: [CandidateField]

    public init(documentId: UUID = UUID(), fields: [CandidateField]) {
        self.documentId = documentId
        self.fields = fields
    }
    public var id: UUID { documentId }

    public var allConfirmed: Bool { !fields.isEmpty && fields.allSatisfy(\.isConfirmed) }
    public var confirmedFields: [CandidateField] { fields.filter(\.isConfirmed) }

    /// 未确认字段不得入时间轴（BR-003 最小验证的文档级版本）
    public var isUsableInTimeline: Bool { allConfirmed }

    public mutating func confirm(field id: UUID) {
        guard let i = fields.firstIndex(where: { $0.id == id }) else { return }
        _ = fields[i].confirm()
    }
}
