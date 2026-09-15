import Foundation

/// 跨切面的识别字段草稿模型（OCR 确认卡 / 语音结构化 / 理解层通用，131+ 使用点）。
/// 全部草稿待确认态（BR-003）；D→C 只经显式确认（`confirm`）。
/// 结构轮（2026-09-15）：自 VoiceGrammar.swift 迁出——本类型与语音文法无关，
/// 单独成文件（P2）。
public struct FieldDraft: Codable, Sendable, Equatable, Identifiable {
    public var key: String {
        didSet { if key != oldValue { invalidateReview() } }
    }
    public let originalValue: String
    public let originalUnit: String?
    public var value: String {
        didSet { if value != oldValue { invalidateReview() } }
    }
    public var unit: String? {
        didSet { if unit != oldValue { invalidateReview() } }
    }
    public var confidence: Double          // 0..1，低置信强制 UI 复核
    // V3.86/契约 §3.2 V1.4 扩展（可选字段默认 nil，向后兼容，既有调用点零改）：
    public var rawText: String?            // 原文（BR-002 不丢内容；nil 时 = value）
    public var suggestedLabel: String?     // 建议显示标签（L10n 键语义，nil 时 = key）
    public var source: UnderstandingSource?// 产出轨（跨轨置信度不直接比较，仅呈现标注）
    public var sourceLineIndex: Int?
    public var codeResolution: CodeResolution? { // F25 惰性建议（医疗槽位，BR-003）
        didSet { if codeResolution != oldValue { codeApproval = nil } }
    }
    public var grade: SourceGrade
    public var revisionHistory: [String]
    private var reviewedValue: String?
    private var reviewedUnit: String?
    public private(set) var codeApproval: CodeApproval?

    public struct CodeApproval: Codable, Sendable, Equatable {
        public let resolution: CodeResolution
        public let label: String
        public let unit: String
    }

    public var id: String { key }
    public init(key: String, value: String, unit: String? = nil, confidence: Double = 0.9,
                 rawText: String? = nil, suggestedLabel: String? = nil,
                 source: UnderstandingSource? = nil, codeResolution: CodeResolution? = nil,
                  grade: SourceGrade = .ocrUnconfirmed, sourceLineIndex: Int? = nil) {
        self.originalValue = value
        self.originalUnit = unit
        self.key = key; self.value = value; self.unit = unit; self.confidence = confidence
        self.rawText = rawText; self.suggestedLabel = suggestedLabel
        self.source = source; self.codeResolution = codeResolution
        self.sourceLineIndex = sourceLineIndex
        self.grade = grade; self.revisionHistory = []
        self.reviewedValue = grade == .userConfirmed ? value : nil
        self.reviewedUnit = grade == .userConfirmed ? unit : nil
    }

    public var isConfirmed: Bool {
        grade == .userConfirmed && reviewedValue == value && reviewedUnit == unit
    }

    @discardableResult
    public mutating func confirm() -> Bool {
        guard grade != .rejected, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        grade = .userConfirmed; reviewedValue = value; reviewedUnit = unit
        return true
    }

    @discardableResult
    public mutating func approveCode(unit: String) -> Bool {
        guard isConfirmed, let codeResolution, codeResolution.kind == .metric,
              !codeResolution.conceptId.isEmpty, !codeResolution.canonicalCode.isEmpty,
              self.unit == nil || self.unit?.trimmingCharacters(in: .whitespacesAndNewlines) == unit.trimmingCharacters(in: .whitespacesAndNewlines),
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        codeApproval = CodeApproval(resolution: codeResolution,
                                    label: value.trimmingCharacters(in: .whitespacesAndNewlines),
                                    unit: unit.trimmingCharacters(in: .whitespacesAndNewlines))
        return true
    }

    public mutating func reject() { grade = .rejected; codeApproval = nil }
    public mutating func reenable() { grade = .ocrUnconfirmed; reviewedValue = nil; codeApproval = nil }
    public mutating func clearCodeResolution() { codeResolution = nil; codeApproval = nil }

    public mutating func revise(to newValue: String, by actor: String = "owner", at date: Date = Date()) {
        guard value != newValue else { return }
        revisionHistory.append("\(value) -> \(newValue) | \(actor) | \(ISO8601DateFormatter().string(from: date))")
        value = newValue
    }

    private mutating func invalidateReview() {
        grade = .ocrUnconfirmed; reviewedValue = nil; reviewedUnit = nil
        codeResolution = nil; codeApproval = nil
    }

    private enum CodingKeys: String, CodingKey {
        case key, originalValue, originalUnit, value, unit, confidence, rawText, suggestedLabel, source
        case codeResolution, grade, revisionHistory, reviewedValue, reviewedUnit, codeApproval
        case sourceLineIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        let decodedValue = try c.decode(String.self, forKey: .value)
        let decodedUnit = try c.decodeIfPresent(String.self, forKey: .unit)
        value = decodedValue
        originalValue = try c.decodeIfPresent(String.self, forKey: .originalValue) ?? decodedValue
        unit = decodedUnit
        originalUnit = c.contains(.originalUnit) ? try c.decodeIfPresent(String.self, forKey: .originalUnit) : decodedUnit
        confidence = try c.decode(Double.self, forKey: .confidence)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        suggestedLabel = try c.decodeIfPresent(String.self, forKey: .suggestedLabel)
        source = try c.decodeIfPresent(UnderstandingSource.self, forKey: .source)
        sourceLineIndex = try c.decodeIfPresent(Int.self, forKey: .sourceLineIndex)
        codeResolution = try c.decodeIfPresent(CodeResolution.self, forKey: .codeResolution)
        grade = try c.decodeIfPresent(SourceGrade.self, forKey: .grade) ?? .ocrUnconfirmed
        revisionHistory = try c.decodeIfPresent([String].self, forKey: .revisionHistory) ?? []
        reviewedValue = try c.decodeIfPresent(String.self, forKey: .reviewedValue)
        reviewedUnit = try c.decodeIfPresent(String.self, forKey: .reviewedUnit)
        codeApproval = try c.decodeIfPresent(CodeApproval.self, forKey: .codeApproval)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key); try c.encode(originalValue, forKey: .originalValue)
        try c.encode(originalUnit, forKey: .originalUnit)
        try c.encode(value, forKey: .value); try c.encodeIfPresent(unit, forKey: .unit)
        try c.encode(confidence, forKey: .confidence); try c.encodeIfPresent(rawText, forKey: .rawText)
        try c.encodeIfPresent(suggestedLabel, forKey: .suggestedLabel); try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(codeResolution, forKey: .codeResolution); try c.encode(grade, forKey: .grade)
        try c.encode(revisionHistory, forKey: .revisionHistory)
        try c.encodeIfPresent(reviewedValue, forKey: .reviewedValue); try c.encodeIfPresent(reviewedUnit, forKey: .reviewedUnit)
        try c.encodeIfPresent(codeApproval, forKey: .codeApproval)
        try c.encodeIfPresent(sourceLineIndex, forKey: .sourceLineIndex)
    }
}
