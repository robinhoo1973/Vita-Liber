import Foundation

/// F17 语音结构化抽取（§5.13）：受限文法模板引擎——Domain 纯函数，
/// 无模型训练、无网络。转写文本 → 字段草稿（全部待确认态，BR-003）。
/// 数值归一化：中文数字/小数/单位变体。
public struct FieldDraft: Sendable, Equatable, Identifiable {
    public var key: String
    public var value: String
    public var unit: String?
    public var confidence: Double          // 0..1，低置信强制 UI 复核
    // V3.86/契约 §3.2 V1.4 扩展（可选字段默认 nil，向后兼容，既有调用点零改）：
    public var rawText: String?            // 原文（BR-002 不丢内容；nil 时 = value）
    public var suggestedLabel: String?     // 建议显示标签（L10n 键语义，nil 时 = key）
    public var source: UnderstandingSource?// 产出轨（跨轨置信度不直接比较，仅呈现标注）
    public var codeResolution: CodeResolution?  // F25 惰性建议（医疗槽位，BR-003）
    public var id: String { key }
    public init(key: String, value: String, unit: String? = nil, confidence: Double = 0.9,
                rawText: String? = nil, suggestedLabel: String? = nil,
                source: UnderstandingSource? = nil, codeResolution: CodeResolution? = nil) {
        self.key = key; self.value = value; self.unit = unit; self.confidence = confidence
        self.rawText = rawText; self.suggestedLabel = suggestedLabel
        self.source = source; self.codeResolution = codeResolution
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
    /// 相对日期短语（明天/明早/后天/今天）→ 抽取键 "time"
    public var timePatterns: [String]
    /// 小时短语（\d+点 / 上下午）→ 抽取键 "hour"
    public var hourPatterns: [String]
    /// 具体日期（\d+月\d+[日号]）→ 抽取键 "date"
    public var datePatterns: [String]
    public var repeatPatterns: [String]
    public init(kind: String, timePatterns: [String], repeatPatterns: [String],
                hourPatterns: [String] = [], datePatterns: [String] = []) {
        self.kind = kind; self.timePatterns = timePatterns; self.repeatPatterns = repeatPatterns
        self.hourPatterns = hourPatterns; self.datePatterns = datePatterns
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
        // 纯中文数字序列归一化。
        // 审查修复（P0 医疗数值）：口语省位形态「一百二」= 120（百位后的
        // 单数词按位权 = 上一个单位的 1/10）；「一百零二」= 102（「零」
        // 打断位权继承，其后数词按个位）。原实现两者都归一成 102——
        // 血压「一百二」被静默写入 102 mmHg 且高置信。
        var total = 0
        var section = 0
        var lastUnit = 1
        var hasValue = false
        var zeroSeen = false
        for ch in chars {
            // 第六轮全仓审查修复：「零」在 cnDigits 中（值 0），必须先于
            // cnDigits 分支判定——原实现 else if ch == "零" 恒不可达，
            // 「一百零二」走 0 位权 → 120（实测），医疗数值静默错 18%。
            if ch == "零" {
                zeroSeen = true
                section = 0
                hasValue = true   // 第七轮修复：「零」本身是数值（血糖零=0）——hasValue 不置位则归一结果原样返回「零」
            } else if let d = cnDigits[ch] {
                section = d
                hasValue = true
            } else if let u = cnUnits[ch] {
                section = (section == 0 ? 1 : section) * u
                total += section
                section = 0
                lastUnit = u
            } else if ch == "." || ch == "点" {
                return text   // 混合形态不做归一（交由确认卡）
            }
        }
        // 尾部剩余数词：「零」隔断后按个位（一百零二=102）；
        // 前一单位 ≥10 且无隔断 → 按 1/10 位权（一百二=120）
        total += section * (zeroSeen || lastUnit < 10 ? 1 : lastUnit / 10)
        return hasValue ? String(total) : text
    }

    /// 数值录入解析单一出口（第八轮全仓审查修复）：逗号小数点（部分区域
    /// decimalPad 产出）归一后解析——此前三个录入点各自内联
    /// `replacingOccurrences(of: ",", with: ".")`，任何新数值输入框都可能
    /// 漏掉该区域化怪癖而把合法输入报错。返回 nil 表示不可解析（调用方
    /// 响亮拒绝）。
    public static func parseDecimal(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
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
                // 审查修复：单位一律取 rule.unitDefault——现有全部指标正则的第二捕获组
                // 是数值而非单位（如「血压 148 92」的 92 是舒张压），原「第二组=单位」
                // 分支把舒张压塞进收缩压草稿的 unit（FR7.10 验收句产垃圾单位）。
                let unit = rule.unitDefault
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
        // TestFlight 实测修复（双条提醒 + 字段契约错位）：
        // ① 每个字段类别全局只取首个命中——此前对每个 rule 都 append，两条规则
        //    同时命中即产出重复字段（确认卡显示两个「时间」=「两个提醒信息」）；
        // ② 小时短语此前被抽成 "time" 键，resolveDate 只认相对日期短语，
        //    「8点」类表达必然解析失败——现分离为 "hour"/"date"/"time" 三键。
        var hasDate = false, hasHour = false, hasRepeat = false
        for rule in rules {
            if !hasDate {
                for pattern in rule.timePatterns {
                    guard let regex = compiled(pattern) else { continue }
                    let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                    if let match = regex.firstMatch(in: transcript, range: range),
                       match.numberOfRanges > 1,
                       let vRange = Range(match.range(at: 1), in: transcript) {
                        drafts.append(FieldDraft(key: "time",
                                                 value: NumberNormalizer.normalize(String(transcript[vRange])),
                                                 confidence: 0.9))
                        hasDate = true
                        break
                    }
                }
            }
            if !hasDate {
                for pattern in rule.datePatterns {
                    guard let regex = compiled(pattern) else { continue }
                    let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                    if let match = regex.firstMatch(in: transcript, range: range),
                       match.numberOfRanges > 2,
                       let mRange = Range(match.range(at: 1), in: transcript),
                       let dRange = Range(match.range(at: 2), in: transcript) {
                        // 具体日期 "date" 键：value 存 "月 日" 双段，resolveDate 解析
                        drafts.append(FieldDraft(key: "date",
                                                 value: "\(String(transcript[mRange])) \(String(transcript[dRange]))",
                                                 confidence: 0.95))
                        hasDate = true
                        break
                    }
                }
            }
            if !hasHour {
                for pattern in rule.hourPatterns {
                    guard let regex = compiled(pattern) else { continue }
                    let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                    if let match = regex.firstMatch(in: transcript, range: range),
                       match.numberOfRanges > 1,
                       let vRange = Range(match.range(at: 1), in: transcript) {
                        let raw = NumberNormalizer.normalize(String(transcript[vRange]))
                        // FR10.2 绝不猜时间：「上/下午」等无具体点的短语不产出 hour
                        // （由 UI 引导补充），只落数值时刻
                        guard var hour = Int(raw) else { continue }
                        // 审查修复：带「下午/晚上/傍晚」限定词的数值时刻此前被
                        // (\d+)点 先命中、限定词被静默丢弃——「下午3点」抽成
                        // hour=3，提醒提前 12 小时（FR10.2 语义：有具体点又有
                        // 限定词时使用限定词，而非猜 24 小时制的默认支）。限定
                        // 词必须锚定到命中短语紧邻的前文（3 字符窗口同时容纳
                        // 「下午的3点」类虚词间隔）——二轮审查：全文搜索会把
                        // 「上午9点吃药，下午再测血糖」的 9 点误移为 21 点。
                        // 12 点（中午/凌晨两可）与「上午/凌晨/早上」不位移。
                        if hour >= 1 && hour <= 11,
                           let fullRange = Range(match.range(at: 0), in: transcript) {
                            let tail = String(transcript[..<fullRange.lowerBound].suffix(3))
                            if tail.contains("下午") || tail.contains("晚上") || tail.contains("傍晚") {
                                hour += 12
                            }
                        }
                        drafts.append(FieldDraft(key: "hour", value: "\(hour)", confidence: 0.8))
                        hasHour = true
                        break
                    }
                }
            }
            if !hasRepeat {
                for pattern in rule.repeatPatterns {
                    guard let regex = compiled(pattern) else { continue }
                    let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                    if let match = regex.firstMatch(in: transcript, range: range),
                       match.numberOfRanges > 1,
                       let vRange = Range(match.range(at: 1), in: transcript) {
                        drafts.append(FieldDraft(key: "repeat", value: String(transcript[vRange]),
                                                 confidence: 0.85))
                        hasRepeat = true
                        break
                    }
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
    /// 提醒草稿正文重组（语音面板 → 提醒页预填）：确认槽位无 content 键
    /// （文法产 hour/date/time/repeat），重组「日期 + N点」供页面按本页
    /// 流程重抽。中文形态放在 Domain（视图层零硬编码字面量，L10n 单出口）。
    public static func reminderTranscript(from fields: [FieldDraft]) -> String {
        var parts: [String] = []
        let values = Dictionary(fields.map { ($0.key, $0.value) },
                                uniquingKeysWith: { first, _ in first })
        if let date = values["date"], !date.isEmpty { parts.append(date) }
        if let hour = values["hour"], !hour.isEmpty { parts.append("\(hour)点") }
        if let time = values["time"], !time.isEmpty { parts.append(time) }
        return parts.joined(separator: " ")
    }
    /// 把语音草稿转成统一确认集（四处共用同一入口）。
    /// V3.86/契约 §8.6.2 唯一映射点扩展：suggestedLabel → displayLabel、
    /// rawText 保留原文、codeResolution 透传（D→C 生命周期合同——映射点
    /// 丢字段 = 理解层元数据静默丢失，与 §8.6 必测断言②直接相关）。
    public static func confirmationSet(drafts: [FieldDraft], documentId: UUID = UUID()) -> OcrConfirmationSet {
        OcrConfirmationSet(documentId: documentId, fields: drafts.map { draft in
            CandidateField(key: draft.key,
                           displayLabel: draft.suggestedLabel ?? draft.key,
                           rawText: draft.rawText ?? draft.value,
                           confidence: draft.confidence, value: draft.value,
                           grade: .ocrUnconfirmed,
                           codeResolution: draft.codeResolution)
        })
    }

    /// FR17.19 unknown 语义的回落草稿（抽取零命中时整句原文进草稿，确认卡
    /// 可编辑补全——绝不静默丢弃转写）。此前三处入口各自内联构造
    /// `FieldDraft(key: "note"/"body", …)`，键语义漂移（同一句话从面板落
    /// "note" 键、从速记页落 "body" 键）；键/置信度只维护这一处。
    public static func fallbackDraft(key: String = "note", value: String,
                                     confidence: Double) -> FieldDraft {
        FieldDraft(key: key, value: value, unit: nil, confidence: confidence)
    }
}
