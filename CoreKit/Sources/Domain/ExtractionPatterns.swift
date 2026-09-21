import Foundation

/// 抽取层的共享词表与文法单点（结构轮 2026-09-15）。
/// 收敛原则：只收「多份拷贝语义一致」的资产；捕获组语义不同的正则保持就地（无损优先）。
public enum ExtractionPatterns {

    /// 科室词表（最长优先匹配；处方/检验/病历/裸科室行全轨共享）。
    ///
    /// 此前 Domain（`ExtractionSpec.deptWords`，22 条）与 Infrastructure
    /// （`NLTextUnderstanding.deptWords`，36 条）各一份且已实证漂移：同一「裸科室行」
    /// 在规则轨与理解轨的命中面不同（缺项如「产科/心血管内科/肾内科」只在理解轨可配）。
    /// 本表取并集为单一事实源；新增科室 = 只加此处。
    public static let deptWords: [String] = [
        "内科", "外科", "儿科", "妇产科", "产科", "眼科", "耳鼻喉科", "口腔科",
        "皮肤科", "骨科", "泌尿外科", "神经内科", "消化内科", "呼吸内科",
        "心血管内科", "心内科", "内分泌科", "血液科", "肿瘤科", "感染科",
        "肾内科", "风湿免疫科", "老年科", "全科", "康复医学科", "康复科",
        "中医科", "针灸科", "急诊科", "重症医学科", "麻醉科", "放射科",
        "影像科", "超声科", "检验科", "病理科", "体检中心", "保健科",
    ]

    public static let deptWordSet: Set<String> = Set(deptWords)

    /// 最长优先（长词先匹配，避免「内科」截走「心血管内科」）。
    /// 预排序常量——此前调用点每行 `deptWords.sorted(by:)` 现算一次（30 行报告即 30 次排序）。
    public static let deptWordsByLength: [String] = deptWords.sorted { $0.count > $1.count }

    // MARK: - 标签值域（2026-09-16 实测污染修复）

    /// 标签词表（**值域右界**单一出口）。一行多标签时，某标签的值到「下一个标签」为止。
    ///
    /// 修复的实测缺陷：原实现把「首个冒号之后的**全部**文本」当值——
    /// 对 `日期：2026-09-12 科室：呼吸内科 医生：张三` 得到
    /// `doctor = "2026-09-12 科室：呼吸内科 医生：张三"`、
    /// `department = "呼吸内科 医生：张三"`、`date = 整行`。三者都不是任何标签的值，
    /// 且**原样进确认页**（启发式轨不经 `ExtractionGrounding`）。
    /// 医疗记录里错的字段值比空值更危险，故此类值必须被截断或丢弃。
    public static let labelBoundaries: [String] = [
        "科室", "科別", "科别",
        "医院", "醫院", "卫生院", "衛生院", "诊所", "診所",
        "医生", "醫生", "医师", "醫師",
        "日期", "检查时间", "檢查時間", "就诊时间", "就診時間", "报告日期", "報告日期",
        "参考范围", "參考範圍", "参考值", "参考区间", "參考區間", "正常范围", "正常範圍",
        "主诉", "主訴", "诊断", "診斷", "处理", "處理", "医嘱", "醫囑",
        "姓名", "性别", "性別", "年龄", "年齡", "病历号", "病歷號", "门诊号", "門診號",
    ]

    /// 标签是否**处于标签位**——其前一字符是行首、空白或分隔标点。
    ///
    /// **为什么必须有这条判据**：朴素的「值里出现标签词就截断」会误伤叙事值——
    /// `现病史：患者既往诊断高血压` 里的「诊断」是正文词（前一字符是「往」），
    /// 而 `诊断：支气管炎 处理：抗感染` 里的「处理」（前一字符是空白）才是真标签。
    /// 外部对照：logfmt 的「只有**下一个已确认的键**才结束当前值」；
    /// FUNSD 修订版论文指出空间配对不可靠正是因缺少显式分隔——本仓有显式 `：`，
    /// 故无需几何，用「标签位」即可判定。
    /// - Parameter labelEnd: 该标签词的结束位置。给出时，**逗号族分隔符**之后的候选
    ///   还需其后紧跟「：」才算真标签位（见下）。
    static func isLabelPosition(_ text: String, at index: String.Index,
                                labelEnd: String.Index? = nil) -> Bool {
        guard index > text.startIndex else { return true }          // 行首
        let prev = text[text.index(before: index)]
        if prev.isWhitespace || prev == ":" || prev == "：" { return true }
        guard "，,；;、（）()【】[]".contains(prev) else { return false }
        // 审查修复（叙事被逗号截断，BR-002/003）：此前的分隔符集含中文逗号——而
        // 「，」正是中文临床叙述的**常规分句符**，于是候选一律被判为标签位，值被
        // 在句中腰斩：实测 `truncatingAtLabelBoundary("患者3天前出现咳嗽、咳痰，诊断
        // 不明确，为进一步诊治来我院")` = "患者3天前出现咳嗽、咳痰，"（其后全部丢失）；
        // 更糟的是 T1/T2 轨：`OCRGrounding.fields` 会拿模型给出的**正确全文**与这个
        // 截断值比较，不相等即判定「无据」整条丢弃（droppedUngrounded++）——正确
        // 结果被扔掉、错误结果被留下，与本文件头部「错的字段值比空值更危险」相悖。
        // 判据补强（与本函数自述的「本仓有显式 `：`」一致）：逗号族之后的候选，
        // 只有**其后紧跟冒号**才是真标签。于是
        //   `既往史：高血压，诊断：糖尿病` → 「诊断」后是「：」→ 仍是标签位 ✓
        //   `…咳嗽、咳痰，诊断不明确…`     → 「诊断」后是「不」→ 不再是标签位 ✓
        // 行首/空白/方括号之后的候选维持原判（`科室 医生：张三` 等不受影响）。
        guard let end = labelEnd else { return true }
        var i = end
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
        return i < text.endIndex && (text[i] == "：" || text[i] == ":")
    }

    /// 值里**下一个处于标签位**的标签起点；无则 nil。
    static func nextLabelBoundary(in value: String) -> String.Index? {
        var cut: String.Index?
        for label in labelBoundaries {
            var search = value.startIndex
            while let r = value.range(of: label, range: search..<value.endIndex) {
                if isLabelPosition(value, at: r.lowerBound, labelEnd: r.upperBound) {
                    if cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
                    break
                }
                search = value.index(after: r.lowerBound)
            }
        }
        return cut
    }

    /// 把一个已捕获的值截断到**下一个处于标签位的标签**之前。用于修 `fieldPatterns` 里
    /// `(.+)` 的贪婪捕获（`科室[:：]?\s*(.+)` 会把「呼吸内科 医生：张三」整段收下）。
    /// 无标签位标签 → 原样返回；截断后为空 → 返回 nil（宁缺勿污染）。
    public static func truncatingAtLabelBoundary(_ value: String) -> String? {
        let cut = nextLabelBoundary(in: value) ?? value.endIndex
        let span = value[value.startIndex..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        return span.isEmpty ? nil : span
    }

    /// 取「标签：值」中**该标签自己**的值段：起点 = 标签之后跳过分隔符与空白；
    /// 右界 = 行内**其它**标签的起点（或行尾）。结果恒为 `text` 的精确子串。
    /// 审查修复：标签只接受**处于标签位**的首次出现——此前取全行首次出现，
    /// 叙事词内部的同字（「主治医生嘱…医生：张三」里的「主治医生」）会把
    /// 整条尾巴当值原样进确认页（本文件头部自述「错的字段值比空值更危险」）。
    /// 判据与 nextLabelBoundary 共用 isLabelPosition（标签位语义单一出口）。
    public static func valueSpan(afterLabel label: String, in text: String) -> String? {
        var search = text.startIndex
        var labelRange: Range<String.Index>?
        while let r = text.range(of: label, range: search..<text.endIndex) {
            if isLabelPosition(text, at: r.lowerBound, labelEnd: r.upperBound) {
                labelRange = r
                break
            }
            search = text.index(after: r.lowerBound)
        }
        guard let labelRange else { return nil }
        var cursor = labelRange.upperBound
        while cursor < text.endIndex {
            let ch = text[cursor]
            guard ch == ":" || ch == "：" || ch.isWhitespace else { break }
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }
        var boundary = text.endIndex
        let tail = text[cursor...]
        for other in labelBoundaries where other != label {
            if let r = tail.range(of: other), r.lowerBound < boundary { boundary = r.lowerBound }
        }
        guard cursor < boundary else { return nil }
        let span = text[cursor..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
        return span.isEmpty ? nil : span
    }

    /// 机构名（`<名称>医院` 后缀文法）：截到后缀为止，丢掉其后的文档类型词等尾随文本。
    /// 实测缺陷：`北京协和医院 处方笺` 整行当医院名。文法不命中返回 nil（调用方回落原行为）。
    public static func institutionName(in text: String) -> String? {
        guard let regex = institutionNamePattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - 日期单文法（round5 Q4，2026-09-20）

    /// 日期命中：年月日 + **原文**记号范围（记号恒为原文精确子串，grounding 可逐字定位）。
    public struct DateMatch: Equatable, Sendable {
        public let year: Int, month: Int, day: Int
        public let range: Range<String.Index>
    }

    /// 全仓日期文法的**唯一**定义（此前 `EntityCardProjection.datePattern` / `dateTokenPattern` /
    /// `RuleExtractor.Patterns.date` / fallback 边界四份近似副本各自演进、全部只认 4 位年在前）。
    /// 识别面（按 OCR 实测形态）：
    /// - 分隔形：`2026-09-20` / `2026/9/20` / `2026年9月20日` / `2026.09.20`（年 4 位**或** 2 位；2 位年仅在
    ///   三段齐全且含分隔时接受，世纪按 `referenceYear` 推：yy ≤ 参考年末两位+1 → 本世纪，否则上世纪）；
    /// - 紧凑形：`20260920`（前后不得紧邻数字——票据号/身份证片段不算；月 1–12、日 1–31 才算）；
    /// - 全角数字（NFKC 逐字折叠）与 OCR 混淆字（紧邻数字的 `O/o→0`、`l/I/|→1`）在**匹配副本**上折叠，
    ///   返回范围映射回原文——记号仍是原文子串；
    /// - 标签前缀、时间后缀忽略（`firstMatch`）。
    /// 折叠对每个 `Character` 一比一，字符偏移与原文对齐，故范围可直接映射。
    public static func dateMatch(in text: String, referenceYear: Int = currentYear) -> DateMatch? {
        guard !text.isEmpty else { return nil }
        let folded = foldedForDate(text)
        let foldedText = String(folded)
        let full = NSRange(foldedText.startIndex..., in: foldedText)
        if let regex = separatedDatePattern,
           let m = regex.firstMatch(in: foldedText, range: full),
           let match = components(from: m, in: foldedText, original: text, referenceYear: referenceYear, separated: true) {
            return match
        }
        if let regex = compactDatePattern,
           let m = regex.firstMatch(in: foldedText, range: full),
           let match = components(from: m, in: foldedText, original: text, referenceYear: referenceYear, separated: false) {
            return match
        }
        return nil
    }

    /// 日期记号（有界，恒为原文精确子串）——`dateMatch` 的记号投影。
    /// 实测缺陷（历史）：`append("report_date", text)` 曾把 `parseDate` 于行内任意位置命中的**整行**当值。
    public static func dateToken(in text: String) -> String? {
        guard let match = dateMatch(in: text) else { return nil }
        return String(text[match.range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 参考年（两位年世纪推断用）；测试注入固定值以保证确定性。
    public static var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    /// 匹配副本折叠：① NFKC 只在结果仍为单个 Character 时替换（全角数字/标点→半角）；
    /// ② 混淆字仅当左右任一侧紧邻 ASCII 数字才折（避免把 "Il-Il" 类罗马数字折成日期）。
    static func foldedForDate(_ text: String) -> [Character] {
        var chars: [Character] = text.map { c in
            let nfkc = String(c).precomposedStringWithCompatibilityMapping
            return nfkc.count == 1 ? nfkc.first! : c
        }
        func isDigit(_ i: Int) -> Bool { chars.indices.contains(i) && chars[i].isASCII && chars[i].isNumber }
        for i in chars.indices where isDigit(i - 1) || isDigit(i + 1) {
            switch chars[i] {
            case "O", "o": chars[i] = "0"
            case "l", "I", "|": chars[i] = "1"
            default: break
            }
        }
        return chars
    }

    private static func components(from m: NSTextCheckingResult, in folded: String, original: String,
                                   referenceYear: Int, separated: Bool) -> DateMatch? {
        func group(_ i: Int) -> Int? {
            guard m.numberOfRanges > i, let r = Range(m.range(at: i), in: folded) else { return nil }
            return Int(folded[r])
        }
        let year: Int
        if separated {
            if let y4 = group(1) { year = y4 }
            else if let y2 = group(2) {
                let century = referenceYear / 100 * 100
                year = y2 <= referenceYear % 100 + 1 ? century + y2 : century - 100 + y2
            } else { return nil }
        } else {
            guard let y4 = group(1) else { return nil }
            year = y4
        }
        guard let month = group(separated ? 3 : 2), let day = group(separated ? 4 : 3),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let foldedRange = Range(m.range, in: folded) else { return nil }
        // 折叠一比一：按字符偏移映射回原文
        let start = folded.distance(from: folded.startIndex, to: foldedRange.lowerBound)
        let end = folded.distance(from: folded.startIndex, to: foldedRange.upperBound)
        guard end <= original.count else { return nil }
        let lower = original.index(original.startIndex, offsetBy: start)
        let upper = original.index(original.startIndex, offsetBy: end)
        return DateMatch(year: year, month: month, day: day, range: lower..<upper)
    }

    /// 参考范围边界解析：「3.5-9.5」「3.5～9.5」「3.5 ~ 9.5」→ (低, 高)；
    /// 解析失败 nil（不猜范围）。数值文法含正负号/小数/科学计数。
    /// （结构轮：自 `CardTemplateMatcher.referenceBounds` 迁入——该文法是检验行/表头/
    /// 分类器多轨共用的语法资产，不再挂在模板匹配器名下。）
    public static func referenceBounds(_ text: String) -> (low: String, high: String)? {
        guard let regex = referenceBoundsPattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let lowRange = Range(match.range(at: 1), in: text), let highRange = Range(match.range(at: 2), in: text) else { return nil }
        let low = String(text[lowRange]), high = String(text[highRange])
        guard let l = Double(low), let h = Double(high), l.isFinite, h.isFinite, l <= h else { return nil }
        return (low, high)
    }

    // MARK: - 静态文法编译（一次性编译复用；同 `labelBoundaries` 预计算纪律）

    private static let institutionNamePattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量
        pattern: #"([一-龥A-Za-z0-9（）()·]{2,20}(?:医院|醫院|卫生院|衛生院|诊所|診所))"#)
    /// 分隔形：组 1 = 4 位年 / 组 2 = 2 位年（二选一）、组 3 = 月、组 4 = 日；年前后不得紧邻数字。
    private static let separatedDatePattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量
        pattern: #"(?<!\d)(?:(\d{4})|(\d{2}))\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})(?:\s*日)?(?!\d)"#)
    /// 紧凑形 yyyyMMdd：8 位、前后非数字（月日合法性在 `components` 校验）。
    private static let compactDatePattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量
        pattern: #"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)"#)
    private static let referenceBoundsPattern: NSRegularExpression? = {
        let number = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#
        return try? NSRegularExpression(pattern: "^\\s*(\(number))\\s*[-–~～]\\s*(\(number))\\s*$")   // try?-ok: 静态数值文法字面量，构造不会失败
    }()
}
