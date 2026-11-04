import Foundation

/// 多假设融合（round3 §6.1 步骤 1）词元的书写脚本——越语言弃权（步骤 4）与校准表维度（步骤 5）共用。
///
/// 中文数字串（「五百」）记 `.han`：弃权按**书写系统**判定（只产拉丁的引擎在「五百」列弃权），
/// 数值语义另由 `HypothesisFusionTokenClass.number` 表达。
public enum HypothesisFusionScript: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// 汉字（逐字；含中文数字串）。
    case han
    /// 连续拉丁字母（含全角经 NFKC、带调字母、单位前缀 μ、词内撇号）。
    case latin
    /// ASCII / 全角阿拉伯数字串（含一个小数点）。
    case digit
    /// 单位符号（% ‰ ℃ ℉ °）与其他文字的字母（假名、谚文…）。
    case other
}

/// 词类：校准表维度 + 保护判定（round3 §6.1 步骤 7；极性类为 2026-11-03 反方辩论核验追加）。
/// 判定优先级：number > unit > negation > polarity > word。
public enum HypothesisFusionTokenClass: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case word
    case number
    case unit
    case negation
    /// 临床极性/方位/时序/剂量动作词（`HypothesisFusionVocabulary.polarity`）。
    case polarity

    /// 数字/单位/否定词/极性词——列内任一候选属此类即整列不自动改（round3 §3.3「保护必须对称」）。
    public var isProtectedClass: Bool { self != .word }
}

/// 保护词表（公开常量，便于审计）。全部按与假设**同一分词**的键序列整段匹配（大小写、全半角不敏感），
/// 单字条目匹配该字的每一次出现。宁多勿少：误保护只少一次自动改，漏保护会翻转医疗语义。
public enum HypothesisFusionVocabulary {
    /// 通用单位（round3 §6.1 步骤 7）：「毫克」= 毫+克，「mmol/L」= mmol+l。
    public static let units: [String] = [
        "mg", "g", "kg", "ml", "mL", "L", "dL", "μg", "mcg", "IU", "U", "mmHg", "mmol/L", "μmol/L",
        "mg/dL", "g/L", "bpm", "cm", "mm", "%", "‰", "℃", "℉", "°",
        "毫克", "克", "千克", "公斤", "斤", "毫升", "升", "微克", "毫米汞柱", "毫摩尔", "微摩尔",
        "厘米", "毫米", "度", "片", "粒", "单位", "單位",
    ]

    /// 否定词（另认以 n't 结尾的拉丁缩约）。含否定词候选的列不自动改，且冻结其所在子句（否定辖域）。
    public static let negations: [String] = [
        "不", "没", "沒", "无", "無", "未", "非", "否", "别", "別", "勿", "莫", "毋", "甭", "冇",
        "no", "not", "never", "without", "none", "nor", "neither", "nobody", "nothing", "nowhere",
        "cannot", "deny", "denies", "denied", "absent",
        "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent", "cant", "couldnt", "wont",
        "wouldnt", "shouldnt", "havent", "hasnt", "hadnt", "aint", "mustnt", "neednt",
    ]

    /// 临床极性/方位/时序/剂量动作词：列内任一候选含此类词且候选间不一致 ⟹ 不自动改、记 `.polarity` 待核
    /// （与否定词同等的列级保护；不扩展为子句辖域）。「上/下」刻意不纳入（单字方位过宽）。
    /// 繁体变体（陰/陽/雙側/後/減/飯）为 zh-Hant 对等追加。
    public static let polarity: [String] = [
        "阴性", "阳性", "阴", "阳", "陰性", "陽性", "陰", "陽",
        "左", "右", "双侧", "雙側", "前", "后", "後",
        "饭前", "饭后", "飯前", "飯後", "餐前", "餐后", "餐後", "睡前", "空腹",
        "早", "中", "晚",
        "增", "减", "減", "加", "停",
        "left", "right", "bilateral", "positive", "negative", "before", "after",
        "increase", "increases", "increased", "increasing", "decrease", "decreases", "decreased", "decreasing",
        "stop", "stops", "stopped", "stopping",
    ]
}

/// 融合词元：原字符串中的一个投票单位。标点/空白不成词元（不投票，只在主轨原样保留）。
public struct HypothesisFusionToken: Sendable, Equatable {
    /// 原文切片（逐字，未归一）。
    public var surface: String
    /// 严格等价键：NFKC + 拉丁小写；数字为数值键（「五百」与「500」同为 `#500`）。**投票只认它**。
    public var key: String
    /// 对齐软代价用的读音形（汉字拼音去调、拉丁小写）。**只降低对齐代价，绝不作等价键**——是/十 是不同候选。
    public var phonetic: String
    public var script: HypothesisFusionScript
    public var tokenClass: HypothesisFusionTokenClass
    /// 在所属假设 `text` 中的 UTF-16 区间。
    public var utf16Range: Range<Int>
    /// 映射自引擎原生 token 的置信度（未校准；定位失败或引擎未给 = nil）。
    public var confidence: Double?
    /// 命中调用方受保护词条（药名等）。
    public var isProtectedTerm: Bool

    public init(surface: String, key: String, phonetic: String, script: HypothesisFusionScript,
                tokenClass: HypothesisFusionTokenClass, utf16Range: Range<Int>,
                confidence: Double? = nil, isProtectedTerm: Bool = false) {
        self.surface = surface
        self.key = key
        self.phonetic = phonetic
        self.script = script
        self.tokenClass = tokenClass
        self.utf16Range = utf16Range
        self.confidence = confidence
        self.isProtectedTerm = isProtectedTerm
    }

    /// 是否必须保护（数字/单位/否定词/调用方词条）。
    public var isProtected: Bool { tokenClass.isProtectedClass || isProtectedTerm }
}

/// 融合分词器（round3 §6.1 步骤 1/2）：汉字逐字；连续拉丁字母为词；数字整体
/// （ASCII/全角数字含小数点；中文数字串经 `NumberFormatter(.spellOut)` 求值）；标点/空白不投票。
///
/// 成熟实现优先（FR0.1 / ADR-025）：NFKC、拼音（`applyingTransform(.mandarinToLatin)`）、
/// 中文数字求值全部取自 Foundation，不手写拼音表或数字文法。
public enum HypothesisFusionTokenizer {
    /// 对单段文本分词；`protectedTerms` 按同一分词的键序列整段匹配（命中词元标 `isProtectedTerm`）。
    public static func tokenize(_ text: String, protectedTerms: [String] = []) -> [HypothesisFusionToken] {
        let lexicon = HypothesisFusionLexicon()
        lexicon.prefetchPinyin([text])
        return lexicon.tokenize(text, protectedTerms: lexicon.termKeySequences(protectedTerms))
    }

    /// 中文数字串求值；nil = 不是可靠的数字（交回普通汉字处理）。
    ///
    /// ICU 的 spellOut 解析会**吃前缀**（Linux 实测：「十五六」→15、「一二零」→12、口语「一百二」→102），
    /// 故必须回写校验：把解析值再用同一格式器写回中文，与原串（两→二、〇→零、繁→简归一后）
    /// 逐字一致才采纳——宁可不认作数字（保守：不报「数值相同」），也不给出错误数值。
    public static func chineseNumeralValue(_ run: String) -> Double? {
        HypothesisFusionLexicon().chineseNumeralValue(run)
    }
}

/// 一次融合调用内的 Foundation 资源与缓存（NumberFormatter、拼音）。
///
/// 刻意**不放 static let**：Linux corelibs 在静态初始化期调用 Foundation 有随机 SIGSEGV 先例
/// （ci-lessons「测试资源双布局族」坑中坑）；且 NumberFormatter 非线程安全——每次调用自建、惰性构造、
/// 只在本调用栈内使用。
final class HypothesisFusionLexicon {
    private var hansSpellOut: NumberFormatter?
    private var hantSpellOut: NumberFormatter?
    private var numeralCache: [String: Double?] = [:]
    private var pinyinCache: [Character: String] = [:]
    private var vocabularySequences: (units: [[String]], negations: [[String]], polarity: [[String]])?

    // MARK: 词表（纯字面量，无 Foundation 调用）

    /// 中文数字字符（「点/點」只在两数字之间、「负/負」只在串首成立）。
    static let numeralCharacters: Set<Character> = Set("零〇一二两兩三四五六七八九十百千万萬亿億点點负負")
    static let numeralDigits: Set<Character> = Set("零〇一二两兩三四五六七八九")
    static let decimalWords: Set<Character> = Set("点點")
    static let signWords: Set<Character> = Set("负負")

    /// 单位符号的 NFKC 小写键（℃ 经 NFKC 为「°C」）。
    static let unitSymbolKeys: Set<String> = ["%", "‰", "°c", "°f", "°"]

    /// 拉丁否定缩约（don't / can't …；撇号已归一为 ASCII）。
    static func isNegationContraction(_ token: HypothesisFusionToken) -> Bool {
        token.script == .latin && token.key.count > 3 && token.key.hasSuffix("n't")
    }
}

// MARK: - 分词

extension HypothesisFusionLexicon {
    private enum CharacterKind: Equatable {
        case digit, decimalPoint, apostrophe, numeral, han, latin, unitSymbol, otherLetter, separator
    }

    /// 分词主循环。`protectedTerms` 为已分词的词条键序列（见 `termKeySequences`）。
    func tokenize(_ text: String, protectedTerms: [[String]]) -> [HypothesisFusionToken] {
        var tokens = scan(text)
        let vocabulary = vocabularyKeySequences()
        mark(&tokens, sequences: vocabulary.units) { token in
            if token.tokenClass != .number { token.tokenClass = .unit }
        }
        mark(&tokens, sequences: vocabulary.negations) { token in
            if token.tokenClass == .word { token.tokenClass = .negation }
        }
        for index in tokens.indices where tokens[index].tokenClass == .word {
            if Self.isNegationContraction(tokens[index]) { tokens[index].tokenClass = .negation }
        }
        mark(&tokens, sequences: vocabulary.polarity) { token in
            if token.tokenClass == .word { token.tokenClass = .polarity }
        }
        mark(&tokens, sequences: protectedTerms) { $0.isProtectedTerm = true }
        return tokens
    }

    /// 词条 → 键序列（与假设同一分词，故大小写/全半角/空白差异不影响匹配；词条无需读音）。
    func termKeySequences(_ terms: [String]) -> [[String]] {
        terms.map { scan($0, phonetics: false).map(\.key) }.filter { !$0.isEmpty }
    }

    private func vocabularyKeySequences() -> (units: [[String]], negations: [[String]], polarity: [[String]]) {
        if let cached = vocabularySequences { return cached }
        let sequences = (units: termKeySequences(HypothesisFusionVocabulary.units),
                         negations: termKeySequences(HypothesisFusionVocabulary.negations),
                         polarity: termKeySequences(HypothesisFusionVocabulary.polarity))
        vocabularySequences = sequences
        return sequences
    }

    /// 键序列整段匹配：命中区间内每个词元执行 `apply`（幂等标记，匹配顺序不影响结果）。
    private func mark(_ tokens: inout [HypothesisFusionToken], sequences: [[String]],
                      apply: (inout HypothesisFusionToken) -> Void) {
        guard !tokens.isEmpty else { return }
        for sequence in sequences where sequence.count <= tokens.count {
            for start in 0...(tokens.count - sequence.count) {
                var matches = true
                for offset in sequence.indices where tokens[start + offset].key != sequence[offset] {
                    matches = false
                    break
                }
                guard matches else { continue }
                for offset in sequence.indices { apply(&tokens[start + offset]) }
            }
        }
    }

    /// 词法扫描：产出词元（类别只到 number/unit 符号/word，词表类别由 `tokenize` 再标）。
    /// `phonetics: false` 时读音取键（词表匹配只用键，免去逐字 ICU 转写）。
    private func scan(_ text: String, phonetics: Bool = true) -> [HypothesisFusionToken] {
        let characters = Array(text)
        var offsets: [Int] = []
        offsets.reserveCapacity(characters.count + 1)
        var cursor = 0
        for character in characters {
            offsets.append(cursor)
            cursor += character.utf16.count
        }
        offsets.append(cursor)
        let kinds = characters.map(kind(of:))
        var tokens: [HypothesisFusionToken] = []
        func emit(_ range: Range<Int>, key: String, script: HypothesisFusionScript,
                  tokenClass: HypothesisFusionTokenClass) {
            let surface = String(characters[range])
            let phonetic = phonetics && script == .han ? pinyin(of: surface) : key
            tokens.append(HypothesisFusionToken(surface: surface, key: key, phonetic: phonetic, script: script,
                                                tokenClass: tokenClass,
                                                utf16Range: offsets[range.lowerBound]..<offsets[range.upperBound]))
        }
        func emitHan(_ index: Int) {
            emit(index..<(index + 1), key: Self.nfkc(characters[index]), script: .han, tokenClass: .word)
        }
        var index = 0
        while index < characters.count {
            switch kinds[index] {
            case .digit:
                var end = index + 1
                var seenPoint = false
                while end < characters.count {
                    if kinds[end] == .digit { end += 1; continue }
                    if kinds[end] == .decimalPoint, !seenPoint, end + 1 < characters.count, kinds[end + 1] == .digit {
                        seenPoint = true
                        end += 2
                        continue
                    }
                    break
                }
                let literal = characters[index..<end].map(Self.nfkc).joined()
                emit(index..<end, key: Self.numberKey(literal), script: .digit, tokenClass: .number)
                index = end
            case .numeral:
                let end = numeralRunEnd(characters, from: index)
                guard end > index else {
                    emitHan(index)
                    index += 1
                    continue
                }
                if let value = chineseNumeralValue(String(characters[index..<end])) {
                    emit(index..<end, key: Self.numberKey("\(value)"), script: .han, tokenClass: .number)
                } else {
                    // 整串求值失败：逐字再试（单字「十」「五」仍是数字），仍失败按普通汉字。
                    for position in index..<end {
                        if let value = chineseNumeralValue(String(characters[position])) {
                            emit(position..<(position + 1), key: Self.numberKey("\(value)"), script: .han,
                                 tokenClass: .number)
                        } else {
                            emitHan(position)
                        }
                    }
                }
                index = end
            case .han:
                emitHan(index)
                index += 1
            case .latin:
                var end = index + 1
                while end < characters.count {
                    if kinds[end] == .latin { end += 1; continue }
                    if kinds[end] == .apostrophe, end + 1 < characters.count, kinds[end + 1] == .latin {
                        end += 2
                        continue
                    }
                    break
                }
                let folded = characters[index..<end].map(Self.nfkc).joined()
                    .replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
                emit(index..<end, key: folded, script: .latin, tokenClass: .word)
                index = end
            case .unitSymbol:
                emit(index..<(index + 1), key: Self.nfkc(characters[index]).lowercased(), script: .other,
                     tokenClass: .unit)
                index += 1
            case .otherLetter:
                emit(index..<(index + 1), key: Self.nfkc(characters[index]).lowercased(), script: .other,
                     tokenClass: .word)
                index += 1
            case .decimalPoint, .apostrophe, .separator:
                index += 1
            }
        }
        return tokens
    }

    /// 中文数字串的右端（开区间）；返回 `start` 表示此处不成串（孤立的「点」或非串首的「负」）。
    private func numeralRunEnd(_ characters: [Character], from start: Int) -> Int {
        let count = characters.count
        var index = start
        if Self.signWords.contains(characters[index]) {
            let next = index + 1
            guard next < count, Self.numeralCharacters.contains(characters[next]),
                  !Self.signWords.contains(characters[next]), !Self.decimalWords.contains(characters[next]) else {
                return start
            }
            index = next
        }
        guard !Self.decimalWords.contains(characters[index]) else { return start }
        index += 1
        var seenPoint = false
        while index < count, Self.numeralCharacters.contains(characters[index]) {
            let character = characters[index]
            if Self.signWords.contains(character) { break }
            if Self.decimalWords.contains(character) {
                guard !seenPoint, index + 1 < count, Self.numeralDigits.contains(characters[index + 1]) else { break }
                seenPoint = true
                index += 2
                continue
            }
            index += 1
        }
        return index
    }

    private func kind(of character: Character) -> CharacterKind {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            switch scalar.value {
            case 0x30...0x39, 0xFF10...0xFF19: return .digit
            case 0x2E, 0xFF0E: return .decimalPoint
            case 0x27, 0x2019: return .apostrophe
            default: break
            }
        }
        if Self.numeralCharacters.contains(character) { return .numeral }
        if let first = scalars.first, Self.isHan(first) { return .han }
        let folded = Self.nfkc(character)
        if Self.unitSymbolKeys.contains(folded.lowercased()) { return .unitSymbol }
        if Self.isLatinWord(folded) { return .latin }
        return character.isLetter ? .otherLetter : .separator
    }
}

// MARK: - 归一、数字、拼音

extension HypothesisFusionLexicon {
    static func nfkc(_ character: Character) -> String {
        character.isASCII ? String(character) : String(character).precomposedStringWithCompatibilityMapping
    }

    /// CJK 统一表意文字（基本区、扩展 A–H、兼容区）。
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF, 0x2A700...0x2EBEF,
             0x2F800...0x2FA1F, 0x30000...0x323AF:
            return true
        default:
            return false
        }
    }

    /// NFKC 后全部为拉丁字母（含带调字母、组合附加符）或单位前缀 μ。
    static func isLatinWord(_ folded: String) -> Bool {
        guard let first = folded.unicodeScalars.first, isLatinLetter(first) else { return false }
        return folded.unicodeScalars.allSatisfy { isLatinLetter($0) || (0x300...0x36F).contains($0.value) }
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x100...0x24F, 0x1E00...0x1EFF, 0x3BC:
            return true
        case 0xC0...0xFF:
            return scalar.value != 0xD7 && scalar.value != 0xF7
        default:
            return false
        }
    }

    /// 数值键：同值同键（「500」「500.0」「五百」→ `#500`），只用于判定一致，不改主轨写法。
    static func numberKey(_ literal: String) -> String {
        guard let value = Decimal(string: literal) else { return "#" + literal }
        return "#" + value.description
    }

    /// 中文数字串求值 + 回写校验（见 `HypothesisFusionTokenizer.chineseNumeralValue`）。
    func chineseNumeralValue(_ run: String) -> Double? {
        if let cached = numeralCache[run] { return cached }
        var result: Double?
        let target = Self.foldNumeral(run)
        for formatter in [spellOut(hant: false), spellOut(hant: true)] {
            guard let number = formatter.number(from: run), number.doubleValue.isFinite,
                  let rendered = formatter.string(from: number), Self.foldNumeral(rendered) == target else { continue }
            result = number.doubleValue
            break
        }
        numeralCache[run] = result
        return result
    }

    private func spellOut(hant: Bool) -> NumberFormatter {
        if let existing = hant ? hantSpellOut : hansSpellOut { return existing }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: hant ? "zh-Hant" : "zh-Hans")
        formatter.numberStyle = .spellOut
        if hant { hantSpellOut = formatter } else { hansSpellOut = formatter }
        return formatter
    }

    /// 回写比较前的写法归一：两→二、〇→零、繁→简（ICU 写回用「二」「〇」，口语/繁体用「两」「零」「萬」）。
    private static func foldNumeral(_ text: String) -> String {
        String(text.map { character -> Character in
            switch character {
            case "两", "兩": return "二"
            case "〇": return "零"
            case "萬": return "万"
            case "億": return "亿"
            case "點": return "点"
            case "負": return "负"
            default: return character
            }
        })
    }

    /// 批量预取拼音：一次 transform 处理本次调用涉及的全部汉字（逐字调用 ICU 转写器开销大）。
    /// 分隔符换行在转写中保持不变；若切分条数不符即放弃批量结果、回落逐字。
    func prefetchPinyin(_ texts: [String]) {
        var pending = Set<Character>()
        for text in texts {
            for character in text where pinyinCache[character] == nil {
                if let first = character.unicodeScalars.first, Self.isHan(first) { pending.insert(character) }
            }
        }
        guard !pending.isEmpty else { return }
        let ordered = pending.sorted { String($0).unicodeScalars.lexicographicallyPrecedes(String($1).unicodeScalars) }
        let joined = ordered.map(String.init).joined(separator: "\n")
        let parts = Self.romanize(joined).split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == ordered.count else { return }
        for (character, part) in zip(ordered, parts) {
            pinyinCache[character] = String(part).filter { !$0.isWhitespace }
        }
    }

    /// 汉字串 → 去调拼音（无空白）；只作对齐软代价。
    func pinyin(of text: String) -> String {
        var out = ""
        for character in text {
            if let cached = pinyinCache[character] {
                out += cached
                continue
            }
            let value = Self.romanize(String(character)).filter { !$0.isWhitespace }
            pinyinCache[character] = value
            out += value
        }
        return out
    }

    private static func romanize(_ text: String) -> String {
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        return (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
    }
}

// MARK: - 置信度映射（round3 §6.1 步骤 5 的置信度档来源）

extension HypothesisFusionLexicon {
    /// 假设 → 融合词元（含受保护词条标记与置信度映射）。
    func tokens(for hypothesis: TranscriptionHypothesis, protectedTerms: [[String]]) -> [HypothesisFusionToken] {
        var tokens = tokenize(hypothesis.text, protectedTerms: protectedTerms)
        Self.applyConfidences(&tokens, from: hypothesis)
        return tokens
    }

    /// 按顺序在 `hypothesis.text` 中定位引擎 token，再映射到融合词元：词元区间被**带置信度**的引擎
    /// token 连续完整覆盖时取其中最小值（保守）；否则不分档（nil）——调用方回退到不分档的上一级。
    static func applyConfidences(_ tokens: inout [HypothesisFusionToken], from hypothesis: TranscriptionHypothesis) {
        let spans = engineSpans(of: hypothesis)
        guard !spans.isEmpty else { return }
        for index in tokens.indices {
            let range = tokens[index].utf16Range
            let overlapping = spans.filter { $0.range.overlaps(range) }
            guard !overlapping.isEmpty else { continue }
            var confidences: [Double] = []
            var covered = range.lowerBound
            for span in overlapping.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                guard let confidence = span.confidence, span.range.lowerBound <= covered else {
                    confidences = []
                    covered = range.lowerBound
                    break
                }
                confidences.append(confidence)
                covered = max(covered, span.range.upperBound)
            }
            guard covered >= range.upperBound, let lowest = confidences.min() else { continue }
            tokens[index].confidence = lowest
        }
    }

    /// 引擎 token 在原文中的 UTF-16 区间（顺序定位；找不到的 token 跳过、不推进游标）。
    static func engineSpans(of hypothesis: TranscriptionHypothesis) -> [(range: Range<Int>, confidence: Double?)] {
        guard hypothesis.confidenceKind == .engineNative, !hypothesis.tokens.isEmpty else { return [] }
        let text = hypothesis.text
        var cursor = text.startIndex
        var spans: [(range: Range<Int>, confidence: Double?)] = []
        for token in hypothesis.tokens {
            let needle = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty,
                  let found = text.range(of: needle, options: .literal, range: cursor..<text.endIndex) else { continue }
            let lower = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
            let upper = text.utf16.distance(from: text.startIndex, to: found.upperBound)
            let confidence = token.confidence.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            spans.append((lower..<upper, confidence))
            cursor = found.upperBound
        }
        return spans
    }
}
