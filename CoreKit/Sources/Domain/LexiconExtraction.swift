import Foundation

/// 词表锚定抽取（2026-09-21，FR25.12⑬）：把 `LexiconScanner` 的词表命中转成
/// **D 级**字段建议（BR-003 由确认卡裁决去向）。
///
/// 三组规则（全部复用既有文法，零新规则族）：
/// 1. 指标行锚定：词表命中指标名（如 血红蛋白 / 血紅素）→ `raw_label`（原文精确
///    子串）+ 余文经 `RuleExtractor.classify(kind: "metric_sample")` 补
///    `value/unit/reference_range/abnormal_flag`；无值无单位即放弃（表头噪声防守）。
/// 2. 处方药名锚定：词表命中药名 → `drug_name` + 余文经
///    `RuleExtractor.classify(kind: "prescription")` 补 `spec/dosage/frequency/
///    route/quantity/days`；非处方文档需至少一个伴随键才产出（防标题行误报）。
///    line 内 剂型/途径/频次词表命中作为文法补充证据（正则漏字面时补齐）。
/// 3. 近失配：仅两处上下文（类指标行 / 处方行）产出**候选**（绝不自动改值，
///    FR25.1 补注）；候选值携带词条原文，编码建议由 App 层统一求（惰性）。
///
/// 去重纪律：既有字段已覆盖的 (键, 行号) 一律不重复建议——词表只补缺口。
public enum LexiconExtraction {

    public static func propose(lines: [String], lexicon: MedicalLexicon,
                               existing: [FieldDraft],
                               documentTypeKey: String?) -> [FieldDraft] {
        guard !lines.isEmpty, lexicon.entryCount > 0 else { return [] }
        var occupied = Set<String>()          // "key|lineIndex"
        for draft in existing {
            guard let line = draft.sourceLineIndex else { continue }
            occupied.insert("\(draft.key)|\(line)")
        }
        var out: [FieldDraft] = []
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let hits = lexicon.hits(in: line)
            for hit in hits {
                switch hit.entry.category {
                case .metric:
                    out += metricDrafts(line: line, lineIndex: index, hit: hit, occupied: &occupied)
                case .medication:
                    out += medicationDrafts(line: line, lineIndex: index, hits: hits, drugHit: hit,
                                            documentTypeKey: documentTypeKey, occupied: &occupied)
                case .drugForm, .route, .frequency:
                    continue    // 作为药名锚定的补充证据消费（独立命中不作字段）
                }
            }
            out += nearMissDrafts(line: line, lineIndex: index, lexicon: lexicon, hits: hits,
                                  documentTypeKey: documentTypeKey, occupied: &occupied)
        }
        return out
    }

    // MARK: - 指标行

    private static func metricDrafts(line: String, lineIndex: Int, hit: LexiconHit,
                                     occupied: inout Set<String>) -> [FieldDraft] {
        guard !occupied.contains("raw_label|\(lineIndex)") else { return [] }
        let parsed = RuleExtractor.classify(line, kind: "metric_sample")
        var drafts: [FieldDraft] = []
        let label = LexiconDraftFactory.slotDraft(key: "raw_label", value: hit.value,
                                                  confidence: LexiconDraftFactory.confidence(for: hit),
                                                  rawText: line, sourceLineIndex: lineIndex)
        var hasReading = false
        for (key, value) in parsed where key != "raw_label" {
            guard !occupied.contains("\(key)|\(lineIndex)") else { continue }
            if key == "value" || key == "unit" { hasReading = true }
            drafts.append(LexiconDraftFactory.slotDraft(key: key, value: value,
                                                        confidence: LexiconDraftFactory.confidence(for: hit),
                                                        rawText: line, sourceLineIndex: lineIndex))
            occupied.insert("\(key)|\(lineIndex)")
        }
        // 无值无单位 = 表头/标题噪声（词表命中不足以成行）——不产出
        guard hasReading else { return [] }
        occupied.insert("raw_label|\(lineIndex)")
        return [label] + drafts
    }

    // MARK: - 处方药名

    private static func medicationDrafts(line: String, lineIndex: Int, hits: [LexiconHit],
                                         drugHit: LexiconHit, documentTypeKey: String?,
                                         occupied: inout Set<String>) -> [FieldDraft] {
        guard !occupied.contains("drug_name|\(lineIndex)") else { return [] }
        let parsed = RuleExtractor.classify(line, kind: "prescription")
        var drafts: [FieldDraft] = []
        var companionCount = 0
        let companionKeys: Set<String> = ["spec", "dosage", "frequency", "route", "quantity", "days", "drug_form"]
        for (key, value) in parsed where key != "drug_name" {
            guard !occupied.contains("\(key)|\(lineIndex)") else { continue }
            if companionKeys.contains(key) { companionCount += 1 }
            drafts.append(LexiconDraftFactory.slotDraft(key: key, value: value,
                                                        confidence: LexiconDraftFactory.confidence(for: drugHit),
                                                        rawText: line, sourceLineIndex: lineIndex))
            occupied.insert("\(key)|\(lineIndex)")
        }
        // 剂型/途径/频次词表命中补齐文法漏项（同键不覆）
        for hit in hits {
            guard let key = lexiconKey(for: hit.entry.category) else { continue }
            guard !occupied.contains("\(key)|\(lineIndex)") else { continue }
            companionCount += 1
            drafts.append(LexiconDraftFactory.slotDraft(key: key, value: hit.value,
                                                        confidence: LexiconDraftFactory.confidence(for: hit),
                                                        rawText: line, sourceLineIndex: lineIndex))
            occupied.insert("\(key)|\(lineIndex)")
        }
        let isPrescription = documentTypeKey == "prescription"
        guard isPrescription || companionCount > 0 else { return [] }
        occupied.insert("drug_name|\(lineIndex)")
        let name = LexiconDraftFactory.slotDraft(key: "drug_name", value: drugHit.value,
                                                 confidence: LexiconDraftFactory.confidence(for: drugHit),
                                                 rawText: line, sourceLineIndex: lineIndex)
        return [name] + drafts
    }

    /// 词表类别 → 处方行键（剂型/途径/频次；药名/指标另有主规则）。
    static func lexiconKey(for category: LexiconCategory) -> String? {
        switch category {
        case .drugForm: return "drug_form"
        case .route: return "route"
        case .frequency: return "frequency"
        case .metric, .medication: return nil
        }
    }

    // MARK: - 近失配（仅候选）

    private static func nearMissDrafts(line: String, lineIndex: Int, lexicon: MedicalLexicon,
                                       hits: [LexiconHit], documentTypeKey: String?,
                                       occupied: inout Set<String>) -> [FieldDraft] {
        guard let token = leadingNameToken(in: line) else { return [] }
        let hasValue = readingTail(line: line, after: token) != nil
        let hasMetricHit = hits.contains { $0.entry.category == .metric }
        let hasDrugHit = hits.contains { $0.entry.category == .medication }
        var out: [FieldDraft] = []
        if !hasMetricHit, hasValue, !occupied.contains("raw_label|\(lineIndex)"),
           let candidates = nearMissCandidates(for: token, category: .metric, lexicon: lexicon) {
            var draft = FieldDraft(key: "raw_label", value: token, confidence: 0.5,
                                   rawText: line, source: .gazetteer, sourceLineIndex: lineIndex)
            draft.candidates = candidates
            occupied.insert("raw_label|\(lineIndex)")
            out.append(draft)
        }
        if !hasDrugHit, documentTypeKey == "prescription" || hasValue,
           !occupied.contains("drug_name|\(lineIndex)"),
           let candidates = nearMissCandidates(for: token, category: .medication, lexicon: lexicon) {
            var draft = FieldDraft(key: "drug_name", value: token, confidence: 0.5,
                                   rawText: line, source: .gazetteer, sourceLineIndex: lineIndex)
            draft.candidates = candidates
            occupied.insert("drug_name|\(lineIndex)")
            out.append(draft)
        }
        return out
    }

    private static func nearMissCandidates(for token: String, category: LexiconCategory,
                                           lexicon: MedicalLexicon) -> [FieldDraft.Candidate]? {
        let entries = lexicon.nearMisses(for: token, category: category)
        guard !entries.isEmpty else { return nil }
        return LexiconDraftFactory.candidates(for: entries)
    }

    // MARK: - 小工具（原文保真：token/值恒为 line 的精确子串）

    /// 行首名称 token：CJK/拉丁起头、2–20 字符、遇数字或空白停止。
    static func leadingNameToken(in line: String) -> String? {
        var token = ""
        for character in line {
            if character.isNumber || character == " " || character == ":" || character == "：" {
                break
            }
            token.append(character)
            if token.count > 20 { return nil }
        }
        guard token.count >= 2 else { return nil }
        guard token.first.map({ !$0.isNumber }) == true else { return nil }
        return token
    }

    /// 名称之后的「读数尾」（存在即视为类指标行）：至少一个数字。
    static func readingTail(line: String, after token: String) -> String? {
        guard let range = line.range(of: token) else { return nil }
        let tail = line[range.upperBound...]
        guard tail.contains(where: { $0.isNumber }) else { return nil }
        return String(tail)
    }
}
