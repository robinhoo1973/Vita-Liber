import Foundation

/// F17 语音结构化抽取（§5.13）：受限文法模板引擎——Domain 纯函数，
/// 无模型训练、无网络。转写文本 → 字段草稿（全部待确认态，BR-003）。
/// 数值归一化：中文数字/小数/单位变体。
public struct FieldDraft: Sendable, Equatable, Identifiable {
    public var key: String
    public var value: String
    public var unit: String?
    public var confidence: Double          // 0..1，低置信强制 UI 复核
    public var id: String { key }
    public init(key: String, value: String, unit: String? = nil, confidence: Double = 0.9) {
        self.key = key; self.value = value; self.unit = unit; self.confidence = confidence
    }
}

public struct MetricGrammarRule: Sendable, Equatable {
    public var metricKey: String
    public var patterns: [String]          // 正则（Swift Regex 字符串）
    public var unitDefault: String
    public init(metricKey: String, patterns: [String], unitDefault: String) {
        self.metricKey = metricKey; self.patterns = patterns; self.unitDefault = unitDefault
    }
}

public struct ReminderGrammarRule: Sendable, Equatable {
    public var kind: String                // followUp / examPrep / selfTest / medLog / any
    public var timePatterns: [String]
    public var repeatPatterns: [String]
    public init(kind: String, timePatterns: [String], repeatPatterns: [String]) {
        self.kind = kind; self.timePatterns = timePatterns; self.repeatPatterns = repeatPatterns
    }
}

public struct ProfileGrammarRule: Sendable, Equatable {
    public var fieldKey: String            // allergy/pastHistory/currentMeds/emergencyContact...
    public var patterns: [String]
    public init(fieldKey: String, patterns: [String]) {
        self.fieldKey = fieldKey; self.patterns = patterns
    }
}

/// 数值归一化：中文数字与变体 → 阿拉伯数字
public enum NumberNormalizer {
    static let cnDigits: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    static let cnUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

    /// "一百三十二" → "132"；"十三" → "13"；"6.8" → "6.8"；"两" → "2"；
    /// 混合/无法归一形态（"十三点二"/"零点五"）→ 原值返回，由调用方降置信强制复核
    public static func normalize(_ text: String) -> String {
        let chars = Array(text)
        guard chars.allSatisfy({ $0.isNumber || cnDigits[$0] != nil || cnUnits[$0] != nil || $0 == "." || $0 == "点" }) else {
            return text
        }
        // 已含阿拉伯数字（如 "6.8"）直接原样返回
        if chars.contains(where: { $0.isNumber }) && !chars.contains(where: { cnDigits[$0] != nil }) {
            return text
        }
        // 纯中文数字序列归一化
        var total = 0
        var section = 0
        var hasValue = false
        for ch in chars {
            if let d = cnDigits[ch] {
                section = d
                hasValue = true
            } else if let u = cnUnits[ch] {
                section = (section == 0 ? 1 : section) * u
                total += section
                section = 0
            } else if ch == "." || ch == "点" {
                return text   // 混合形态不做归一（交由确认卡）
            }
        }
        total += section
        return hasValue ? String(total) : text
    }
}

/// 受限文法引擎（FR17.9-14 子集：指标/提醒/档案访谈）
public enum VoiceStructuringEngine {
    /// 编译缓存（并发安全）：Linux ICU 上 NSRegularExpression 首次编译非线程安全，
    /// 并发创建曾致 SIGTRAP——统一经锁缓存，生产与测试同一纪律
    private static let regexLock = NSLock()
    private static var compiledCache: [String: NSRegularExpression] = [:]
    static func compiled(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock()
        defer { regexLock.unlock() }
        if let cached = compiledCache[pattern] { return cached }
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern) }
        catch { return nil }   // §7 禁 try?：非法 pattern 返回 nil 由调用侧跳过
        compiledCache[pattern] = regex
        return regex
    }
    /// 指标抽取：转写文本 → 字段草稿（数值归一化；单位变体归一）
    public static func extractMetric(_ transcript: String,
                                     rules: [MetricGrammarRule]) -> [FieldDraft] {
        var drafts: [FieldDraft] = []
        for rule in rules {
            for pattern in rule.patterns {
                guard let regex = compiled(pattern) else { continue }
                let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                guard let match = regex.firstMatch(in: transcript, range: range),
                      match.numberOfRanges > 1,    // Linux ICU：无捕获组时 range(at:) 直接 trap
                      let valueRange = Range(match.range(at: 1), in: transcript) else { continue }
                let raw = String(transcript[valueRange])
                let unit: String
                if match.numberOfRanges > 2, let uRange = Range(match.range(at: 2), in: transcript) {
                    unit = String(transcript[uRange])
                } else {
                    unit = rule.unitDefault
                }
                let normalized = NumberNormalizer.normalize(raw)
                let isMixed = raw.contains("点") || raw.contains(".")
                drafts.append(FieldDraft(key: rule.metricKey,
                                         value: normalized,
                                         unit: unit,
                                         confidence: isMixed ? 0.4 : 0.9))   // 混合形态强制复核
                break   // 每个 metricKey 取首个命中
            }
        }
        return drafts
    }

    /// 提醒抽取：时间 + 重复规则
    public static func extractReminder(_ transcript: String,
                                       rules: [ReminderGrammarRule]) -> [FieldDraft] {
        var drafts: [FieldDraft] = []
        for rule in rules {
            for pattern in rule.timePatterns {
                guard let regex = compiled(pattern) else { continue }
                let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                if let match = regex.firstMatch(in: transcript, range: range),
                   match.numberOfRanges > 1,
                   let vRange = Range(match.range(at: 1), in: transcript) {
                    drafts.append(FieldDraft(key: "time",
                                             value: NumberNormalizer.normalize(String(transcript[vRange])),
                                             confidence: 0.9))
                    break
                }
            }
            for pattern in rule.repeatPatterns {
                guard let regex = compiled(pattern) else { continue }
                let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                if let match = regex.firstMatch(in: transcript, range: range),
                   match.numberOfRanges > 1,
                   let vRange = Range(match.range(at: 1), in: transcript) {
                    drafts.append(FieldDraft(key: "repeat", value: String(transcript[vRange]),
                                             confidence: 0.85))
                    break
                }
            }
        }
        return drafts
    }

    /// 档案访谈抽取（过敏/既往史/当前用药/紧急联系人）
    public static func extractProfile(_ transcript: String,
                                      rules: [ProfileGrammarRule]) -> [FieldDraft] {
        var drafts: [FieldDraft] = []
        for rule in rules {
            for pattern in rule.patterns {
                guard let regex = compiled(pattern) else { continue }
                let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                if let match = regex.firstMatch(in: transcript, range: range),
                   match.numberOfRanges > 1,
                   let vRange = Range(match.range(at: 1), in: transcript) {
                    drafts.append(FieldDraft(key: rule.fieldKey,
                                             value: String(transcript[vRange]),
                                             confidence: 0.85))
                    break
                }
            }
        }
        return drafts
    }
}

/// FR17.13 标准语音输入模板复用断言（静态检查语义的 Domain 载体）：
/// 语音指导每步/速记/提醒草稿/观察速记四处确认必须走同一模板——禁止自建确认逻辑。
/// 引擎只产出 FieldDraft（待确认态）；确认一律经 OcrConfirmationSet.confirm。
public enum VoiceInputTemplate {
    /// 把语音草稿转成统一确认集（四处共用同一入口）
    public static func confirmationSet(drafts: [FieldDraft], documentId: UUID = UUID()) -> OcrConfirmationSet {
        OcrConfirmationSet(documentId: documentId, fields: drafts.map { draft in
            CandidateField(key: draft.key, displayLabel: draft.key, rawText: draft.value,
                           confidence: draft.confidence, value: draft.value,
                           grade: .ocrUnconfirmed)
        })
    }
}
