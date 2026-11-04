import Foundation

/// 识别证据的纯换算（2026-11-03 round3 P0-B §8-1；tech-spec §5.13）。
///
/// 引擎适配层（SFSpeech / SpeechAnalyzer / sherpa C API）只把原生对象或 C 指针**读成 Swift 数组**，
/// 清洗、换算、时间偏移、截断与置信度性质判定都在这里：那些适配文件带平台守卫，在 Linux 上
/// 编译的是空单元，逻辑只有放在 Domain 才有本地测试信号。
///
/// 诚实口径：缺就是 nil，不补常数；平行数组长度对不上就整列弃用（错位的时间/置信度比没有更糟）；
/// 只换算引擎给出的数，不推断（例如不从相邻时间戳反推时长）。
/// FR17.7：这里的类型只含文本、时间与置信度，不含音频、样本或文件引用。
public enum TranscriptionTokenAssembly {
    /// 会话级词元上限：超出部分截断（`TranscriptionEvidenceAccumulator.isTruncated`），交付文本不受影响。
    public static let sessionTokenLimit = 4096
    /// n-best 替代全文上限（不含 1-best）。
    public static let alternativeTextLimit = 4
    /// 单个词元的替代写法上限。
    public static let tokenAlternativeLimit = 4
    /// 拼字时一组最多累积的字节数：UTF-8 一个字符至多 4 字节，超过仍未拼完即按损坏数据冲刷。
    static let pendingByteLimit = 16

    // MARK: - 时间与置信度

    /// 引擎时间（秒）加段起点 → 本次按压的相对时间；负值、NaN、无穷（含偏移本身）一律 nil。
    public static func time(_ seconds: Double?, offset: TimeInterval = 0) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds >= 0, offset.isFinite, offset >= 0 else { return nil }
        return seconds + offset
    }

    /// 时长（秒）：负值或非有限值 → nil。
    public static func duration(_ seconds: Double?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// 引擎原生 0…1 置信度：非有限值 → nil（未知，不能冒充 0），其余夹到 0…1。
    public static func confidence(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    /// 自然对数概率（sherpa `ys_log_probs` / 在线 `ys_probs`）→ exp 后夹到 0…1。
    /// -∞ 是引擎给出的零概率 → 0；NaN、+∞ 无意义 → nil；正值（数值误差）夹到 1。
    public static func confidence(logProbability: Double?) -> Double? {
        guard let logProbability, !logProbability.isNaN else { return nil }
        if logProbability == -.infinity { return 0 }
        guard logProbability.isFinite else { return nil }
        return min(1, max(0, exp(logProbability)))
    }

    // MARK: - sherpa

    /// sherpa 词元 → `TranscriptionToken`。输入是 C API `tokens_arr` 的**原始字节**——若先走
    /// `String(cString:)`，被拆在两个词元里的多字节字符会在拼回之前就被替换成 U+FFFD。
    ///
    /// - 字节回退词元 `<0xE4>`（sherpa `Convert()` 对单字节符号的回写）还原成字节；拆开的 UTF-8 字符
    ///   （字节回退 / whisper 字节级 BPE）拼回整字后算一个词元：起点取首片，时长按片求和，
    ///   置信度按链式法则取 exp(Σ log p)；
    /// - 清洗见 `cleanedText(_:)`，清洗后为空的词元丢弃（Qwen3 半字占位的空串、单独的 `▁`）；
    /// - `timestamps` / `durations` / `logProbabilities` 任一长度 ≠ 词元数即整列弃用；
    /// - `offset` = 该段在本次按压音频里的起点（秒），只加到起点上。
    public static func sherpaTokens(_ raw: [[UInt8]], timestamps: [Double]? = nil, durations: [Double]? = nil,
                                    logProbabilities: [Double]? = nil, offset: TimeInterval = 0,
                                    limit: Int = sessionTokenLimit) -> [TranscriptionToken] {
        let count = raw.count
        let starts = timestamps?.count == count ? timestamps : nil
        let lengths = durations?.count == count ? durations : nil
        let logs = logProbabilities?.count == count ? logProbabilities : nil
        let cap = max(0, limit)
        var tokens: [TranscriptionToken] = []
        var pending: [UInt8] = []
        var first = 0
        var last = 0

        func flush() {
            defer { pending.removeAll(keepingCapacity: true) }
            guard !pending.isEmpty, tokens.count < cap,
                  let text = cleanedText(String(decoding: pending, as: UTF8.self)) else { return }
            let pieces = Array(first...last)
            let start = starts.flatMap { time($0[first], offset: offset) }
            let length = lengths.flatMap { values in summedDuration(pieces.map { values[$0] }) }
            let score = logs.flatMap { values in
                confidence(logProbability: pieces.reduce(0.0) { $0 + values[$1] })
            }
            tokens.append(TranscriptionToken(text: text, start: start, duration: length, confidence: score))
        }

        for (index, piece) in raw.enumerated() {
            guard tokens.count < cap else { break }
            let bytes = byteFallbackValue(piece).map { [$0] } ?? piece
            guard !bytes.isEmpty else { continue }
            if pending.isEmpty { first = index }
            last = index
            pending.append(contentsOf: bytes)
            if !endsWithIncompleteUTF8(pending) || pending.count >= pendingByteLimit { flush() }
        }
        flush()
        return tokens
    }

    /// 词元清洗：SentencePiece 词首符 `▁`（U+2581）当空格、去掉修复残片 U+FFFD、去首尾空白；
    /// 特殊符号（`<unk>`、`<blk>`、`<|zh|>` 一类标签）与清洗后为空者返回 nil。
    public static func cleanedText(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "\u{2581}", with: " ")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSpecialSymbol(text) else { return nil }
        return text
    }

    static let specialSymbols: Set<String> = ["<unk>", "<blk>", "<blank>", "<s>", "</s>", "<sos/eos>", "<pad>", "<eps>"]

    static func isSpecialSymbol(_ text: String) -> Bool {
        specialSymbols.contains(text) || (text.count > 4 && text.hasPrefix("<|") && text.hasSuffix("|>"))
    }

    /// `<0xHH>` → 该字节；其余 nil。
    static func byteFallbackValue(_ raw: [UInt8]) -> UInt8? {
        guard raw.count == 6, raw.first == 0x3C, raw[1] == 0x30, raw[2] == 0x78 || raw[2] == 0x58,
              raw.last == 0x3E else { return nil }
        let digits = String(decoding: raw[3...4], as: UTF8.self)
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt8(digits, radix: 16)
    }

    /// 末尾是否是写了一半的多字节 UTF-8 字符（下一个词元可能补齐）。只判最后一个字符：
    /// 标准库解码器把「被截断」与「非法」都报成错误，这里需要区分二者；中间的坏字节交给
    /// `String(decoding:)` 修成 U+FFFD，再由清洗去掉。
    static func endsWithIncompleteUTF8(_ bytes: [UInt8]) -> Bool {
        var index = bytes.count - 1
        var trailing = 0
        while index >= 0, trailing < 3, UTF8.isContinuation(bytes[index]) {
            trailing += 1
            index -= 1
        }
        guard index >= 0 else { return false }
        let needed: Int
        switch bytes[index] {
        case 0xC2...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF4: needed = 4
        default: return false
        }
        return trailing + 1 < needed
    }

    static func summedDuration(_ values: [Double]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        var total = 0.0
        for value in values {
            guard let valid = duration(value) else { return nil }
            total += valid
        }
        return total
    }

    /// sherpa `lang`（SenseVoice 的 `<|zh|>`、whisper 的语种码）→ 去掉标签外壳的语种码；
    /// 空串与 SenseVoice 的 `nospeech`（没听到语音，不是语种）→ nil。
    public static func languageTag(sherpa raw: String?) -> String? {
        guard var tag = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if tag.count >= 4, tag.hasPrefix("<|"), tag.hasSuffix("|>") {
            tag = String(tag.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !tag.isEmpty, tag != "nospeech" else { return nil }
        return tag
    }

    /// 在线（流式 zipformer）结果的 C 结构没有段起点与逐词 log 概率，二者只在其 `json` 字段里：
    /// 钉版 sherpa-onnx（v1.13.4，`online-recognizer.cc` `OnlineRecognizerResult::AsJsonString`）写出
    /// `"start_time"`（本端点段相对流起点的秒数）与 `"ys_probs"`（温度缩放 log-softmax 的逐词 log 概率）。
    /// 端点复位后 C 结构的 `timestamps` 从 0 重新计，必须加上 `start_time` 才是流内时间。
    public struct SherpaOnlineMetadata: Sendable, Equatable {
        public var startTime: TimeInterval?
        public var logProbabilities: [Double]?

        public init(startTime: TimeInterval? = nil, logProbabilities: [Double]? = nil) {
            self.startTime = startTime
            self.logProbabilities = logProbabilities
        }

        /// JSON 不合法（例如 C++ 把 -inf 写成裸 `-inf`）时两项都是 nil——段起点未知，调用方必须弃用时间戳。
        public init(json: String?) {
            guard let data = json?.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { // try?-ok: 非法 JSON = 段起点未知，按 nil 弃用时间，不猜
                self.init()
                return
            }
            self.init(startTime: payload.startTime, logProbabilities: payload.logProbabilities)
        }

        private struct Payload: Decodable {
            let startTime: Double?
            let logProbabilities: [Double]?

            enum CodingKeys: String, CodingKey {
                case startTime = "start_time"
                case logProbabilities = "ys_probs"
            }
        }
    }

    // MARK: - Apple 平台识别器

    /// Apple 识别器的一个词段：SFSpeech 的 `SFTranscriptionSegment`，或 SpeechAnalyzer 结果
    /// `AttributedString` 的一个 run。时间相对该段所在识别请求的音频起点。
    public struct PlatformSegment: Sendable, Equatable {
        public var text: String
        public var start: TimeInterval?
        public var duration: TimeInterval?
        public var confidence: Double?
        public var alternatives: [String]

        public init(text: String, start: TimeInterval? = nil, duration: TimeInterval? = nil,
                    confidence: Double? = nil, alternatives: [String] = []) {
            self.text = text
            self.start = start
            self.duration = duration
            self.confidence = confidence
            self.alternatives = alternatives
        }
    }

    /// Apple 词段 → 词元：去首尾空白、丢空段。同一批段的置信度全为 0 或全缺 = 引擎没给
    /// （Apple 文档：没有识别时为 0；非 final 结果实测全 0）→ 全部 nil；否则逐段夹到 0…1，个别 0 照留。
    public static func platformTokens(_ segments: [PlatformSegment], offset: TimeInterval = 0,
                                      limit: Int = sessionTokenLimit) -> [TranscriptionToken] {
        var spoken: [(text: String, segment: PlatformSegment)] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { spoken.append((text, segment)) }
        }
        let confidenceGiven = spoken.contains { (confidence($0.segment.confidence) ?? 0) > 0 }
        var tokens: [TranscriptionToken] = []
        for entry in spoken.prefix(max(0, limit)) {
            let segment = entry.segment
            tokens.append(TranscriptionToken(
                text: entry.text,
                start: time(segment.start, offset: offset),
                duration: duration(segment.duration),
                confidence: confidenceGiven ? confidence(segment.confidence) : nil,
                alternatives: alternativeTexts(best: entry.text, candidates: segment.alternatives,
                                               limit: tokenAlternativeLimit)))
        }
        return tokens
    }

    /// n-best 整理：去首尾空白、丢空串、丢与 1-best 相同者与重复者，保持引擎排序，截到 `limit`。
    public static func alternativeTexts(best: String, candidates: [String],
                                        limit: Int = alternativeTextLimit) -> [String] {
        var seen: Set<String> = [best.trimmingCharacters(in: .whitespacesAndNewlines)]
        var out: [String] = []
        for candidate in candidates {
            guard out.count < limit else { break }
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            out.append(text)
        }
        return out
    }

    // MARK: - 汇总

    /// 置信度性质：任一词元带引擎置信度 → `.engineNative`；全部缺失 → `.unavailable`。
    public static func confidenceKind(of tokens: [TranscriptionToken]) -> TranscriptionConfidenceKind {
        tokens.contains { $0.confidence != nil } ? .engineNative : .unavailable
    }

    /// 按字数加权的平均置信度（长词比单字更重）；没有任何词元带置信度 → nil。
    public static func characterWeightedConfidence(of tokens: [TranscriptionToken]) -> Double? {
        var weighted = 0.0
        var weight = 0.0
        for token in tokens {
            guard let value = confidence(token.confidence) else { continue }
            let characters = Double(max(1, token.text.count))
            weighted += value * characters
            weight += characters
        }
        guard weight > 0 else { return nil }
        return min(1, max(0, weighted / weight))
    }

    /// 词元起点整体后移 `offset` 秒（段内时间 → 会话时间）；非法偏移让起点变为 nil。
    public static func shifted(_ tokens: [TranscriptionToken], by offset: TimeInterval) -> [TranscriptionToken] {
        guard offset != 0 else { return tokens }
        return tokens.map { token in
            var moved = token
            moved.start = time(token.start, offset: offset)
            return moved
        }
    }
}

/// 一次识别请求 / 一个 VAD 段 / 一个最终结果的引擎原生证据；词元时间相对该段音频起点。
public struct TranscriptionSegmentEvidence: Sendable, Equatable {
    public var tokens: [TranscriptionToken]
    /// 该段 n-best 中除 1-best 以外的全文，保持引擎排序。
    public var alternativeTexts: [String]
    /// 引擎原生语种标签（去掉标签外壳后）；nil = 未给。
    public var languageTag: String?

    public init(tokens: [TranscriptionToken] = [], alternativeTexts: [String] = [], languageTag: String? = nil) {
        self.tokens = tokens
        self.alternativeTexts = alternativeTexts
        self.languageTag = languageTag
    }
}

/// 把逐段证据累成一次按压的假设：sherpa 运行时按 VAD/端点段累一次（段内时间），
/// 会话协调器再按识别请求累一次（会话时间）。
///
/// `commit` 必须与交付文本的段一一对应（包括只有部分结果、没有证据的段），
/// 否则多段 n-best 拼不回交付文本的形状。
public struct TranscriptionEvidenceAccumulator: Sendable, Equatable {
    private struct Segment: Sendable, Equatable {
        var text: String
        var alternatives: [String]
    }

    public let tokenLimit: Int
    public private(set) var tokens: [TranscriptionToken] = []
    /// 词元是否因会话上限被截断（交付文本不受影响）。
    public private(set) var isTruncated = false
    private var segments: [Segment] = []
    private var languageWeights: [String: Int] = [:]
    private var languageOrder: [String] = []

    public init(tokenLimit: Int = TranscriptionTokenAssembly.sessionTokenLimit) {
        self.tokenLimit = max(0, tokenLimit)
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// 记录一段已提交文本。`evidence` 为 nil = 该段没有引擎原生证据（超时、只保留了部分结果）；
    /// `offset` = 该段音频在外层时间轴上的起点（秒）。空文本不成段。
    public mutating func commit(text: String, evidence: TranscriptionSegmentEvidence?, offset: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(Segment(text: trimmed, alternatives: evidence?.alternativeTexts ?? []))
        guard let evidence else { return }
        let room = max(0, tokenLimit - tokens.count)
        if evidence.tokens.count > room { isTruncated = true }
        tokens.append(contentsOf: TranscriptionTokenAssembly.shifted(Array(evidence.tokens.prefix(room)), by: offset))
        if let tag = evidence.languageTag {
            if languageWeights[tag] == nil { languageOrder.append(tag) }
            languageWeights[tag, default: 0] += trimmed.count
        }
    }

    /// 主导语种：按各段字数加权，平局取先出现者。
    public var languageTag: String? {
        languageOrder.max { (languageWeights[$0] ?? 0) < (languageWeights[$1] ?? 0) }
    }

    /// 整段 n-best 全文。单段 = 该段引擎原生 n-best；多段 = 每条只把**一段**换成该段的引擎原生替代、
    /// 其余段保持 1-best（先各段第 1 替代、再各段第 2 替代……）。不做多段同时替换：引擎没有给出
    /// 跨段组合的排序，拼出来就是捏造。`best` 为交付文本，用来去重。
    public func alternativeTexts(excluding best: String,
                                 limit: Int = TranscriptionTokenAssembly.alternativeTextLimit) -> [String] {
        let texts = segments.map(\.text)
        let depth = segments.map(\.alternatives.count).max() ?? 0
        var seen: Set<String> = [best.trimmingCharacters(in: .whitespacesAndNewlines)]
        var out: [String] = []
        for rank in 0..<depth {
            for (index, segment) in segments.enumerated() where rank < segment.alternatives.count {
                guard out.count < limit else { return out }
                var parts = texts
                parts[index] = segment.alternatives[rank]
                let candidate = TranscriptJoiner.join(parts).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
                out.append(candidate)
            }
        }
        return out
    }

    /// 折叠成一段证据（sherpa 运行时把一个识别请求内的 VAD/端点段交给会话协调器）。
    public var segmentEvidence: TranscriptionSegmentEvidence {
        TranscriptionSegmentEvidence(tokens: tokens,
                                     alternativeTexts: alternativeTexts(excluding: TranscriptJoiner.join(segments.map(\.text))),
                                     languageTag: languageTag)
    }

    /// 本次按压该引擎的唯一假设；`text` 为引擎原生 1-best（润色前，即交付文本）。
    public func hypothesis(engineID: String, localeIdentifier: String?, text: String) -> TranscriptionHypothesis {
        TranscriptionHypothesis(engineID: engineID, localeIdentifier: localeIdentifier, text: text, tokens: tokens,
                                confidenceKind: TranscriptionTokenAssembly.confidenceKind(of: tokens),
                                languageTag: languageTag, alternativeTexts: alternativeTexts(excluding: text))
    }
}
