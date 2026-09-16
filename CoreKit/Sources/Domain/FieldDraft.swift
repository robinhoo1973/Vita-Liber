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

    /// 同键**多候选**（2026-09-17 业主定案「多个语义正确的识别结果交用户选」）。
    /// 每项均已 grounding（逐字锚定原文）；`confidence` 保持原值，**不因并置而提高**
    /// （并置不是证据）。空 = 单候选（胜出值即 `value`）——既有调用点零改。
    ///
    /// 此前同键第二个值在 `CardTemplateMatcher` 被**静默丢弃**（「同键首个非空值胜出」，
    /// 叙事键除外）；本字段即那条丢掉的候选集的落地。
    public var candidates: [Candidate] = []

    /// 用户已在该字段的多候选里做过显式选择（下拉里点过）。
    ///
    /// **与 `isConfirmed` 正交**：选另一候选会写 `value` → 经 `didSet` 触发
    /// `invalidateReview()` → 字段退回未确认（BR-003：换了值必须重新确认）。
    /// 所以「已消歧」不能用 `isConfirmed` 表达——先消歧，**再**确认，是两步。
    public private(set) var candidateChosen: Bool = false

    /// 待定歧义：有多个候选而用户尚未选择。此类字段**不参与卡级批量确认**
    /// （业主 2026-09-17 同批裁定「挡」——有歧义就必须做选择）。
    public var hasUnresolvedCandidates: Bool { candidates.count >= 2 && !candidateChosen }

    public struct Candidate: Codable, Sendable, Equatable, Identifiable {
        public var value: String
        public var unit: String?
        public var confidence: Double
        /// 该候选锚定的**原文行**——用户据此判断语义（不是看模型意见）。
        public var rawText: String?
        public var sourceLineIndex: Int?
        public var source: UnderstandingSource?
        public var id: String { "\(sourceLineIndex ?? -1)|\(value)|\(unit ?? "")" }

        public init(value: String, unit: String? = nil, confidence: Double,
                    rawText: String? = nil, sourceLineIndex: Int? = nil,
                    source: UnderstandingSource? = nil) {
            self.value = value; self.unit = unit; self.confidence = confidence
            self.rawText = rawText; self.sourceLineIndex = sourceLineIndex; self.source = source
        }
    }

    /// 用户从下拉里选定一个候选：写值 + 单位 + 标记已消歧。
    /// 写值经 `value.didSet` 使字段退回未确认——这是**正确**行为（BR-003）。
    public mutating func chooseCandidate(_ candidate: Candidate) {
        revise(to: candidate.value)
        unit = candidate.unit
        candidateChosen = true
    }

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
        case candidates, candidateChosen
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
        // 可选默认，向后兼容：旧草稿无此两键 → 空候选集 / 未消歧（既有行为不变）。
        candidates = try c.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        candidateChosen = try c.decodeIfPresent(Bool.self, forKey: .candidateChosen) ?? false
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
        // 仅在非空/已消歧时写出——单候选字段（绝大多数）的编码形态**逐字不变**，
        // 既有导出信封与金样不受影响。
        if !candidates.isEmpty { try c.encode(candidates, forKey: .candidates) }
        if candidateChosen { try c.encode(candidateChosen, forKey: .candidateChosen) }
    }
}
