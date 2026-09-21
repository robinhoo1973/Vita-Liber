import Foundation

/// F25 词表证据层——词表值类型与扫描器（2026-09-21，FR25.12⑬）。
///
/// 分层纪律：本文件只有 Foundation（L0 门禁 [5]）。词表本身不是事实来源：
/// 扫描结果只用于**生成 D 级字段建议**（BR-003 由确认卡裁决去向），且
/// 一律返回原文精确区间（grounding 可逐字定位，BR-002 不丢内容/不篡改）。

/// 词表术语类别（`lexicon_term.category` CHECK 词汇 + `metric` 自 code_alias）。
public enum LexiconCategory: String, Sendable, Codable, CaseIterable {
    case metric
    case medication
    case drugForm = "drug_form"
    case route
    case frequency
}

/// 词表条目（快照值类型）：term 为印刷原文；locale 为语区标记
/// （zh-Hans / zh-Hant / zh-Hant-TW / zh-Hant-HK / en …）。
public struct LexiconEntry: Sendable, Equatable {
    public var term: String
    public var locale: String
    public var category: LexiconCategory
    /// 有码词（code_alias 来源）才有；lexicon_term 无码（许可后补，FR25.11）。
    public var conceptId: String?
    public var priority: Int

    public init(term: String, locale: String, category: LexiconCategory,
                conceptId: String? = nil, priority: Int = 0) {
        self.term = term
        self.locale = locale
        self.category = category
        self.conceptId = conceptId
        self.priority = priority
    }
}

/// 命中：`value` 为**原文子串**（含任意内部空白），`range` 为原文区间。
public struct LexiconHit: Sendable, Equatable {
    /// exact = 原文逐字等于词条；folded = 经折叠（NFKC/大小写/有界简繁/空白）后相等。
    public enum Match: String, Sendable, Equatable { case exact, folded }
    public var value: String
    public var range: Range<String.Index>
    public var entry: LexiconEntry
    public var match: Match
}

/// 词表快照 + 行内扫描（最长匹配、非重叠、左起优先）。
///
/// 折叠口径 = NFKC 兼容分解 + 小写 + 有界繁→简（`ScriptFolding.hantToHans`）+
/// 去空白——与 `ExtractionGrounding` 的等值折叠同族（同为「匹配副本折叠、
/// 原文保真」纪律），但不含纠错折叠；近失配（编辑距离 1）只经 `nearMisses`
/// 产出**候选**，绝不自动改值（FR25.1 补注）。
public struct MedicalLexicon: Sendable {
    private let index: [String: [LexiconEntry]]
    private let maxFoldedLength: Int
    public let entryCount: Int

    public init(entries: [LexiconEntry]) {
        var index: [String: [LexiconEntry]] = [:]
        var maxLen = 0
        for entry in entries {
            let key = MedicalLexicon.fold(entry.term)
            guard !key.isEmpty else { continue }
            index[key, default: []].append(entry)
            maxLen = max(maxLen, key.count)
        }
        var sorted: [String: [LexiconEntry]] = [:]
        for (key, list) in index {
            sorted[key] = list.sorted {
                ($0.priority, $0.locale) > ($1.priority, $1.locale)
            }
        }
        self.index = sorted
        self.maxFoldedLength = maxLen
        self.entryCount = entries.count
    }

    // MARK: - 折叠

    /// 逐字符折叠（可能产出 0 字符 = 空白被丢弃，或 1 字符）。
    /// 与 `ExtractionGrounding` 的逐字符折叠同纪律；此处叠加有界简繁。
    static func fold(character: Character) -> String {
        let nfkc = String(character).precomposedStringWithCompatibilityMapping
        var out = ""
        for scalarChar in nfkc {
            let mapped = ScriptFolding.hantToHans[scalarChar] ?? scalarChar
            out.append(mapped)
        }
        return out.lowercased().filter { !$0.isWhitespace }
    }

    /// 整串折叠（词条键与查询键同一口径）。
    public static func fold(_ text: String) -> String {
        var out = ""
        for character in text { out += fold(character: character) }
        return out
    }

    // MARK: - 扫描

    /// 行内扫描：每个起点取**最长**命中，命中后跳过命中区间（非重叠）。
    /// 无命中返回空——不做任何近似（近失配走 `nearMisses` 显式 API）。
    public func hits(in line: String) -> [LexiconHit] {
        guard maxFoldedLength > 0, !line.isEmpty else { return [] }
        var folded: [Character] = []
        var origin: [String.Index] = []
        for idx in line.indices {
            for character in Self.fold(character: line[idx]) {
                folded.append(character)
                origin.append(idx)
            }
        }
        guard !folded.isEmpty else { return [] }
        var hits: [LexiconHit] = []
        var cursor = 0
        while cursor < folded.count {
            let maxLen = min(maxFoldedLength, folded.count - cursor)
            var matched = false
            var len = maxLen
            while len >= 1 {
                let key = String(folded[cursor..<(cursor + len)])
                if let entries = index[key], let entry = entries.first {
                    let start = origin[cursor]
                    let end = line.index(after: origin[cursor + len - 1])
                    let value = String(line[start..<end])
                    hits.append(LexiconHit(value: value, range: start..<end, entry: entry,
                                           match: value == entry.term ? .exact : .folded))
                    cursor += len
                    matched = true
                    break
                }
                len -= 1
            }
            if !matched { cursor += 1 }
        }
        return hits
    }

    // MARK: - 近失配（仅候选，绝不自动采用）

    /// 近失配查询：折叠后编辑距离 ≤1、首字相同、长度门槛（CJK ≥4 / 拉丁 ≥6）。
    /// 返回至多 `limit` 个条目（确定性排序）；**不做任何写回**——候选由调用方
    /// 以 `FieldDraft.Candidate` 呈现（FR25.1 补注：近失配只提示，不猜码）。
    public func nearMisses(for token: String, category: LexiconCategory,
                           limit: Int = 2) -> [LexiconEntry] {
        let foldedToken = Self.fold(token)
        guard let first = foldedToken.first else { return [] }
        let threshold = foldedToken.allSatisfy { $0.isASCII } ? 6 : 4
        guard foldedToken.count >= threshold else { return [] }
        var best: [(distance: Int, key: String, entry: LexiconEntry)] = []
        for (key, entries) in index {
            guard let entry = entries.first, entry.category == category else { continue }
            guard key.first == first else { continue }
            guard key.count == foldedToken.count || key.count == foldedToken.count + 1
                || key.count + 1 == foldedToken.count else { continue }
            guard key != foldedToken else { continue }
            guard Self.editDistance(foldedToken, key, cap: 2) <= 1 else { continue }
            best.append((1, key, entry))
        }
        best.sort { ($0.key, $0.entry.term) < ($1.key, $1.entry.term) }
        var seen = Set<String>()
        var out: [LexiconEntry] = []
        for item in best where seen.insert(item.key).inserted {
            out.append(item.entry)
            if out.count == limit { break }
        }
        return out
    }

    /// 有界编辑距离（cap 之外提前退出；两串均视为折叠后的字符序列）。
    static func editDistance(_ a: String, _ b: String, cap: Int) -> Int {
        let left = Array(a), right = Array(b)
        if left.isEmpty { return min(right.count, cap + 1) }
        if right.isEmpty { return min(left.count, cap + 1) }
        if abs(left.count - right.count) > cap { return cap + 1 }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
