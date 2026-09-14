import Foundation

/// 子项目 D · D4-1（recognition-remediation-design §0.3 需求 1 / BR-003）：识别内容 → 个人资料的 **D 级建议**。
///
/// 只从**已确认卡的字段原文**逐项搬运：不做同义归并、不判「慢性」、不推断严重度、不切词（切分是推断）；
/// 血型只做字形归一（A/B/AB/O + Rh±），字形不可辨时保留原文由用户裁定。接受前不落任何表——本类型无 IO，
/// 落库（`patient_profile.blood_type` / `health_problem` / `allergy_event`）由 Infrastructure `ProfileSuggestionStore.accept` 在
/// 用户逐项显式接受后执行（D → C 只经显式确认）。
public struct ProfileSuggestion: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable, Equatable {
        case bloodType, chronicCondition, allergy, pastHistory
    }

    /// 来源留痕：卡类 / 回执所指实体表与实体 id / 字段键 / 文档与页 / 回执行 id。
    public struct Provenance: Sendable, Equatable, Codable {
        public var cardKind: String
        public var entityTable: String
        public var entityId: UUID
        public var fieldKey: String
        public var documentId: UUID?
        public var pageIndex: Int?
        public var rowId: UUID?

        public init(cardKind: String, entityTable: String, entityId: UUID, fieldKey: String,
                    documentId: UUID? = nil, pageIndex: Int? = nil, rowId: UUID? = nil) {
            self.cardKind = cardKind; self.entityTable = entityTable; self.entityId = entityId; self.fieldKey = fieldKey
            self.documentId = documentId; self.pageIndex = pageIndex; self.rowId = rowId
        }
    }

    /// 展示 id（会话内唯一，随机）；跨会话去重用 `dedupeKey`。
    public var id: UUID
    public var kind: Kind
    /// 原文（去首尾空白）；血型为字形归一值或原文。
    public var value: String
    /// chronicCondition：诊断行打印码原文（不推断、不 FK）。
    public var codeText: String?
    public var codeSystemText: String?
    /// chronicCondition：`diagnosed_at`；pastHistory / allergy：来源就诊或住院日期；bloodType：nil。
    public var occurredAt: Date?
    public var provenance: Provenance

    /// 恒 D（计算属性：不入 Codable，JSON 无法把建议改写为 C）。
    public var grade: SourceGrade { .ocrUnconfirmed }

    /// 稳定去重键：只依赖 kind / 来源实体 / 字段 / 归一值——store 以其哈希持久登记「已忽略 / 已处理」。
    public var dedupeKey: String {
        "\(kind.rawValue)|\(provenance.entityTable)|\(provenance.entityId.uuidString.lowercased())|\(provenance.fieldKey)|\(ProfileSuggestionExtractor.fold(value, kind: kind))"
    }

    public init(id: UUID = UUID(), kind: Kind, value: String, codeText: String? = nil, codeSystemText: String? = nil,
                occurredAt: Date? = nil, provenance: Provenance) {
        self.id = id; self.kind = kind; self.value = value; self.codeText = codeText; self.codeSystemText = codeSystemText
        self.occurredAt = occurredAt; self.provenance = provenance
    }
}

/// 抽取器（纯规则、零 IO、零医学推断）。
public enum ProfileSuggestionExtractor {
    /// 叙事字段（`encounter.past_history/allergy_history`、`hospitalization.admit/discharge_diagnosis_text`）。
    public struct NarrativeField: Sendable, Equatable {
        public var entityTable: String
        public var entityId: UUID
        public var key: String
        public var text: String
        public var occurredAt: Date?
        public init(entityTable: String, entityId: UUID, key: String, text: String, occurredAt: Date? = nil) {
            self.entityTable = entityTable; self.entityId = entityId; self.key = key; self.text = text; self.occurredAt = occurredAt
        }
    }

    /// 成员既有资料快照（去重用；大小写 / 空白不敏感，血型另忽略「型」与括号）。
    public struct ProfileSnapshot: Sendable, Equatable {
        public var bloodType: String?
        public var problemNames: [String]
        public var allergySubstances: [String]
        public init(bloodType: String? = nil, problemNames: [String] = [], allergySubstances: [String] = []) {
            self.bloodType = bloodType; self.problemNames = problemNames; self.allergySubstances = allergySubstances
        }
        public static let empty = ProfileSnapshot()
    }

    // MARK: - 词表（字符串规则，单一事实源）

    /// 叙事键 → 建议类别；未登记键不产建议。
    public static let narrativeKinds: [String: ProfileSuggestion.Kind] = [
        "past_history": .pastHistory,
        "allergy_history": .allergy,
        "admit_diagnosis_text": .chronicCondition,
        "discharge_diagnosis_text": .chronicCondition,
    ]

    /// 检验行 `item_name` 含任一（折叠后小写、去空白）即视为血型行……
    public static let bloodTypeLabels: [String] = ["血型", "abo", "rh", "bloodtype", "bloodgroup"]
    /// ……但含任一排除词的不是（血型抗体筛查 / 类风湿 / 鼻病毒 / 心律 / 出血族英文）。
    public static let bloodTypeLabelExclusions: [String] = ["抗体", "抗體", "筛查", "篩查", "antibod", "screen", "rheum", "rhino", "rhythm", "rrh"]

    /// 整词否定（去首尾空白与尾部标点、小写后精确匹配）。
    public static let negationLiterals: Set<String> = [
        "无", "无特殊", "无殊", "无异常", "无明显异常", "无过敏", "无过敏史", "无药物过敏", "无药物过敏史", "无食物过敏", "无食物过敏史",
        "无药物及食物过敏史", "无食物及药物过敏史", "无特殊病史", "无既往史", "无特殊既往史", "无重大疾病史", "不详", "未提供", "未知", "无记录", "暂无",
        "無", "無特殊", "無殊", "無異常", "無明顯異常", "無過敏", "無過敏史", "無藥物過敏", "無藥物過敏史", "無食物過敏", "無食物過敏史",
        "無藥物及食物過敏史", "無特殊病史", "無既往史", "無特殊既往史", "不詳", "無記錄", "暫無",
        "none", "n/a", "na", "nil", "no", "nkda", "nka", "nkfa", "unknown", "not available", "no known allergies",
        "no known drug allergies", "none known", "negative", "denied",
        "-", "—", "–", "/",
    ]
    /// 否定前缀：子句以其开头即为否定子句（「否认高血压、糖尿病史」整句否定）。
    public static let negationPrefixes: [String] = ["否认", "否認", "denies", "denied", "no known", "no history of"]
    static let clauseSeparators: Set<Character> = ["，", ",", "；", ";", "。"]
    static let trailingPunctuation: Set<Character> = ["。", "．", ".", "，", ",", "；", ";", "、", "!", "！", ":", "："]

    // MARK: - 抽取

    /// 已确认字段 → 建议列表（顺序：叙事 → 诊断行 → 检验行）。
    /// - narratives：登记键整段各出**一条**（不拆分、不切词）；否定陈述（`isNegation`）不产建议。
    /// - diagnoses：每行一条 chronicCondition（`HealthProblemCandidate.from` 同纪律：去空白、同名首见、空名跳过）。
    /// - labResults：血型行（`bloodTypeValue`）→ bloodType；其余检验行不产建议。
    /// - existing：与既有资料同值（折叠比较）不再建议；批内同 kind 同值只保留首见。
    /// - provenance：`(entityTable, entityId, fieldKey)` → 留痕（文档 / 页由调用方从回执补齐）。
    public static func suggestions(narratives: [NarrativeField], diagnoses: [Diagnosis], labResults: [LabResult],
                                   existing: ProfileSnapshot = .empty,
                                   provenance: (_ entityTable: String, _ entityId: UUID, _ fieldKey: String) -> ProfileSuggestion.Provenance) -> [ProfileSuggestion] {
        // 去重按**落库目标**分域（pastHistory 与 chronicCondition 同写 health_problem，同值只留首见）。
        var seen = Set<String>()
        func seedExisting(_ values: [String], _ kind: ProfileSuggestion.Kind) {
            for value in values { seen.insert("\(dedupeScope(kind))|\(fold(value, kind: kind))") }
        }
        if let bloodType = existing.bloodType { seedExisting([bloodType], .bloodType) }
        seedExisting(existing.problemNames, .chronicCondition)
        seedExisting(existing.allergySubstances, .allergy)

        var out: [ProfileSuggestion] = []
        func emit(_ kind: ProfileSuggestion.Kind, _ value: String, table: String, id: UUID, key: String,
                  codeText: String? = nil, codeSystemText: String? = nil, occurredAt: Date? = nil) {
            let folded = fold(value, kind: kind)
            guard !folded.isEmpty, seen.insert("\(dedupeScope(kind))|\(folded)").inserted else { return }
            out.append(ProfileSuggestion(kind: kind, value: value, codeText: codeText, codeSystemText: codeSystemText,
                                         occurredAt: occurredAt, provenance: provenance(table, id, key)))
        }

        for field in narratives {
            guard let kind = narrativeKinds[field.key] else { continue }
            let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNegation(text) else { continue }
            emit(kind, text, table: field.entityTable, id: field.entityId, key: field.key, occurredAt: field.occurredAt)
        }
        for candidate in HealthProblemCandidate.from(diagnoses: diagnoses) {
            emit(.chronicCondition, candidate.name, table: "diagnosis", id: candidate.diagnosisId, key: "name",
                 codeText: candidate.codeText, codeSystemText: candidate.codeSystemText, occurredAt: candidate.diagnosedAt)
        }
        for result in labResults {
            guard let value = bloodTypeValue(itemName: result.itemName, resultText: result.resultText) else { continue }
            emit(.bloodType, value, table: "lab_result", id: result.id, key: "result_text")
        }
        return out
    }

    // MARK: - 否定陈述

    /// 否定陈述判定（字符串规则）：按子句（，,；;。）切开只为**判定**——每个子句都是整词否定或以否定前缀开头 → 整段否定；
    /// 任一子句非否定（「否认食物过敏，青霉素过敏」）→ 整段交给用户裁定（值仍为整段原文）。「无」只做整词匹配（无花果过敏是正向陈述）。
    public static func isNegation(_ text: String) -> Bool {
        let clauses = text.split(whereSeparator: { clauseSeparators.contains($0) })
            .map { stripTrailingPunctuation($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return true }
        return clauses.allSatisfy { clause in
            negationLiterals.contains(clause) || negationPrefixes.contains { clause.hasPrefix($0) }
        }
    }

    static func stripTrailingPunctuation(_ text: String) -> String {
        var s = text
        while let last = s.last, trailingPunctuation.contains(last) || last.isWhitespace { s.removeLast() }
        return s
    }

    // MARK: - 血型

    /// 血型行判定 + 字形归一（纯字符映射）。
    /// - 非血型行（标签不含血型词或含排除词）→ nil；空值 → nil。
    /// - 可辨字形：ABO ∈ A/B/AB/O（「0」按 O：O 型无「0」歧义）+ Rh（RH/(D) 标记 + 阳性/阴性/±/pos/neg）→ "A" / "Rh+" / "A Rh+"。
    /// - 孤立阳性/阴性只在标签或值本身提到 Rh 时归一为 Rh±，否则视为歧义 → 原文。
    /// - 其余字形不解释 → 原文（去首尾空白），由用户裁定。
    public static func bloodTypeValue(itemName: String, resultText: String) -> String? {
        guard isBloodTypeLabel(itemName) else { return nil }
        let raw = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return normalizedBloodType(raw, labelMentionsRh: foldLabel(itemName).contains("rh")) ?? raw
    }

    static func foldLabel(_ itemName: String) -> String { itemName.lowercased().filter { !$0.isWhitespace } }

    static func isBloodTypeLabel(_ itemName: String) -> Bool {
        let label = foldLabel(itemName)
        guard !bloodTypeLabelExclusions.contains(where: { label.contains($0) }) else { return false }
        return bloodTypeLabels.contains { label.contains($0) }
    }

    /// 顺序消费：[ABO][RH][D|(D)][sign]{1,2}，须消费完整才算可辨；RH/D 标记出现则必须带 sign。
    static func normalizedBloodType(_ raw: String, labelMentionsRh: Bool) -> String? {
        var s = Substring(foldBloodValue(raw))
        guard !s.isEmpty else { return nil }
        var abo: String?
        if s.hasPrefix("AB") { abo = "AB"; s = s.dropFirst(2) }
        else if let first = s.first, let mapped = ["A": "A", "B": "B", "O": "O", "0": "O"][String(first)] { abo = mapped; s = s.dropFirst() }
        var rhMarker = false
        if s.hasPrefix("RH") { rhMarker = true; s = s.dropFirst(2) }
        if s.hasPrefix("(D)") { rhMarker = true; s = s.dropFirst(3) }
        else if s.hasPrefix("D") { rhMarker = true; s = s.dropFirst() }
        var sign: String?
        for _ in 0..<2 {
            guard let (token, value) = signTokens.first(where: { s.hasPrefix($0.0) }) else { break }
            if let sign, sign != value { return nil }
            sign = value; s = s.dropFirst(token.count)
        }
        guard s.isEmpty else { return nil }
        if rhMarker && sign == nil { return nil }
        switch (abo, sign) {
        case let (abo?, sign?): return "\(abo) Rh\(sign)"
        case let (abo?, nil): return abo
        case let (nil, sign?): return (rhMarker || labelMentionsRh) ? "Rh\(sign)" : nil
        case (nil, nil): return nil
        }
    }

    /// 长 token 在前（POSITIVE 先于 POS，(+) 先于 +）。
    static let signTokens: [(String, String)] = [
        ("POSITIVE", "+"), ("NEGATIVE", "-"), ("阳性", "+"), ("陽性", "+"), ("阴性", "-"), ("陰性", "-"),
        ("POS", "+"), ("NEG", "-"), ("(+)", "+"), ("(-)", "-"), ("+", "+"), ("-", "-"),
    ]

    static func foldBloodValue(_ raw: String) -> String {
        let map: [Character: String] = ["（": "(", "）": ")", "＋": "+", "－": "-", "−": "-", "–": "-", "—": "-",
                                        "型": "", "，": "", ",": "", "、": "", "/": "", ".": "", "·": ""]
        return raw.uppercased().compactMap { ch -> String? in
            if ch.isWhitespace { return nil }
            return map[ch] ?? String(ch)
        }.joined()
    }

    // MARK: - 折叠（去重）

    /// 去重域 = 接受后的落库目标：blood_type / health_problem（慢性病与既往史共用）/ allergy_event。
    public static func dedupeScope(_ kind: ProfileSuggestion.Kind) -> String {
        switch kind {
        case .bloodType: return "blood_type"
        case .chronicCondition, .pastHistory: return "health_problem"
        case .allergy: return "allergy_event"
        }
    }

    /// 去重折叠：小写、去全部空白；血型另去「型」/ 括号 / 全角符号（"A型" ≡ "A"、"Rh(D)阳性" ≡ "Rh+" 经 `normalizedBloodType`）。
    public static func fold(_ value: String, kind: ProfileSuggestion.Kind) -> String {
        switch kind {
        case .bloodType:
            let normalized = normalizedBloodType(value, labelMentionsRh: true) ?? value
            return foldBloodValue(normalized).lowercased().filter { $0 != "(" && $0 != ")" }
        case .chronicCondition, .allergy, .pastHistory:
            return value.lowercased().filter { !$0.isWhitespace }
        }
    }
}
