import Foundation

/// FR5.5/FR6.2（V3.41 去向前置指定）兜底轨文档类型分类器（期一）：
/// OCR 行文本 → 稳定类型键 + 候选列表 + 启发式语义字段。Domain 纯函数、
/// 零资产恒可用（ADR-029 兜底轨）；低置信/零命中 → suggestedTarget=nil，
/// 由调用方引导用户选择类型（§8.6 断言④：低置信类型不落 doc_type）。
///
/// 稳定类型键与持久化 doc_type 的关系：持久化仍沿用既有 doc_type 值
/// （导入入口 L10n 标签），本分类器只产出**稳定键**供确认卡草稿行呈现
/// 与模板路由（DocumentTemplateRegistry 语义），App 层负责键↔标签映射。

public struct DocumentTypeEvidence: Sendable, Equatable {
    public var key: String
    /// 证据词（zh-Hans/zh-Hant/en 字形；命中即计分）
    public var keywords: [String]
    public init(key: String, keywords: [String]) {
        self.key = key
        self.keywords = keywords
    }
}

public enum DocumentTypeClassifierFallback {
    /// 稳定类型键表（单一事实源；新增类型=加一行+App 层映射加一支）。
    public static let evidenceTable: [DocumentTypeEvidence] = [
        .init(key: "prescription", keywords: [
            "处方", "處方", "Rx", "用法", "用量", "剂量", "劑量",
            "每次", "每日", "口服", "外用", "粒", "毫升", "胶囊", "膠囊", "mg",
            // 注：「片」已剔除——单字无界子串命中「照片/图片/片状阴影」，
            // 影像报告被误判处方（0.75 置信）后整份走 PrescriptionFieldMapper
        ]),
        .init(key: "lab_report", keywords: [
            "检验", "檢驗", "化验", "化驗", "参考范围", "參考範圍",
            "项目", "項目", "结果", "結果", "单位", "單位", "标本", "標本",
        ]),
        .init(key: "outpatient_record", keywords: [
            "门诊", "門診", "病历", "病歷", "主诉", "主訴", "现病史", "現病史",
            "诊断", "診斷", "处理", "處理", "医嘱", "醫囑",
        ]),
        .init(key: "vaccine_record", keywords: [
            "疫苗", "接种", "接種", "剂次", "劑次", "预防接种", "預防接種",
        ]),
        .init(key: "diagnosis_certificate", keywords: [
            "诊断证明", "診斷證明", "疾病证明", "疾病證明", "病休证明",
        ]),
        .init(key: "invoice", keywords: ["发票", "發票", "收费单", "收費單", "收据", "收據", "金额", "金額", "Invoice", "Receipt"]),
        .init(key: "medication_label", keywords: ["通用名称", "通用名稱", "商品名称", "商品名稱", "药品规格", "藥品規格"]),
        // v26（子项目 D §C.10 / D2-2）：住院族与检查族证据词（D3-2 定稿 25 类分类学）。不用「医院/报告」等泛词，避免夺既有主类。
        .init(key: "inpatient_record", keywords: [
            "病案首页", "病案首頁", "住院病历", "住院病歷", "入院记录", "入院記錄", "病程记录", "病程記錄",
            "住院号", "住院號", "入院日期", "入院时间", "入院時間", "入院诊断", "入院診斷", "Inpatient", "Admission",
        ]),
        .init(key: "discharge_summary", keywords: [
            "出院小结", "出院小結", "出院记录", "出院記錄", "出院诊断", "出院診斷", "出院医嘱", "出院醫囑", "出院带药", "出院帶藥",
            "出院日期", "出院时间", "出院時間", "诊疗经过", "診療經過", "Discharge",
        ]),
        .init(key: "day_surgery_record", keywords: ["日间手术", "日間手術", "Day Surgery", "Ambulatory Surgery"]),
        .init(key: "emergency_record", keywords: ["急诊病历", "急診病歷", "急诊科", "急診科", "急诊", "急診", "Emergency"]),
        .init(key: "exam_report", keywords: [
            "检查报告", "檢查報告", "检查所见", "檢查所見", "影像所见", "影像所見", "影像学表现", "影像學表現", "诊断意见", "診斷意見",
            "印象", "检查部位", "檢查部位", "超声", "超聲", "CT", "MRI", "X线", "X線", "心电图", "心電圖", "内镜", "內鏡", "Impression", "Findings",
        ]),
        .init(key: "pathology_report", keywords: [
            "病理", "镜下所见", "鏡下所見", "肉眼所见", "肉眼所見", "免疫组化", "免疫組化", "活检", "活檢", "Pathology", "Biopsy", "Microscopic",
        ]),
        .init(key: "checkup_report", keywords: ["体检报告", "體檢報告", "健康体检", "健康體檢", "体检", "體檢", "总检", "總檢", "健康指导", "健康指導",
                                                "Health Checkup", "Physical Examination Report"]),
        // v27（子项目 J / 原 D3 §C.8–§C.9）：手术记录与门诊治疗文书证据词——只用文书专有词（手术记录 / 术者 / 输液单…），
        // 出院小结内的手术段按命中行数输给出院族，不夺主类。
        .init(key: "surgery_record", keywords: [
            "手术记录", "手術記錄", "手术名称", "手術名稱", "术者", "術者", "主刀", "术中所见", "術中所見", "手术经过", "手術經過",
            "Operative Report", "Operation Record", "Surgery Record",
        ]),
        .init(key: "treatment_record", keywords: [
            "输液记录", "輸液記錄", "输液单", "輸液單", "输液药物", "輸液藥物", "注射单", "注射單", "注射记录", "注射記錄",
            "治疗记录", "治療記錄", "理疗记录", "理療記錄", "换药记录", "換藥記錄", "Infusion Record", "Treatment Record", "Injection Record",
        ]),
    ]

    /// 分类：每类按命中行数计分（一行多词只计一次），主类=最高分；
    /// 其余有分类型为 secondaryTargets（多类候选仅引导，不决定 doc_type）。
    /// 置信度：1 行命中 0.6 / 2 行 0.75 / ≥3 行 0.9；零命中 → nil（引导选择）。
    public static func classify(lines: [String]) -> (target: String?, confidence: Double,
                                                     secondary: [TargetCandidate]) {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var scores: [(key: String, hits: Int)] = []
        for evidence in evidenceTable {
            var hits = 0
            for line in trimmed {
                if evidence.keywords.contains(where: { line.contains($0) }) {
                    hits += 1
                }
            }
            if hits > 0 { scores.append((evidence.key, hits)) }
        }
        guard !scores.isEmpty else { return (nil, 0, []) }
        var sorted = scores.sorted { $0.hits > $1.hits }
        // v26 亚型覆盖：更具体的类型与其上位类型共享证据词（急诊病历 ⊂ 病历：主诉/诊断/处理；日间手术记录 ⊂ 住院/出院记录），
        // 按命中数永远输给上位类型——上位类型为主类且亚型有证据时，亚型胜出，上位类型降为次级候选。置信度沿用主类命中行数。
        if let specific = specializations[sorted[0].key]?.first(where: { key in sorted.contains { $0.key == key } }),
           let index = sorted.firstIndex(where: { $0.key == specific }) {
            let promoted = (key: specific, hits: max(sorted[0].hits, sorted[index].hits))
            sorted.remove(at: index)
            sorted.insert(promoted, at: 0)
        }
        let primary = sorted[0]
        let confidence: Double
        switch primary.hits {
        case 1: confidence = 0.6
        case 2: confidence = 0.75
        default: confidence = 0.9
        }
        let secondary = sorted.dropFirst().map {
            TargetCandidate(key: $0.key, confidence: 0.5, source: .heuristic)
        }
        return (primary.key, confidence, secondary)
    }

    /// 上位类型 → 亚型（有证据即覆盖）；单一事实源，与 `evidenceTable` 同处维护。
    private static let specializations: [String: [String]] = [
        "outpatient_record": ["emergency_record"],
        "inpatient_record": ["day_surgery_record"],
        "discharge_summary": ["day_surgery_record"],
    ]

    /// 角色正则（编译期静态字面量，一次性编译复用——此前每行每调用重编译
    /// 6 条，OCR 30 行报告即 ~360 次 NSRegularExpression 构造）
    private static let fieldPatterns: [(key: String, regex: NSRegularExpression)] = {
        let patterns: [(key: String, pattern: String)] = [
            // 科室（检验单/病历共用）
            ("dept", #"科\s*室[:：]?\s*(.+)"#),
            // 报告/就诊日期（yyyy-MM-dd 或 yyyy年M月d日）
            ("report_date", #"(?:日期|检查时间|就诊时间)[:：]?\s*(\d{4}[-年/]\d{1,2}[-月/]\d{1,2})"#),
            // 参考范围（体检报告字段目录：项目/结果/参考范围/单位——
            // coreml §4.2 字段目录此前缺此角色，检验报告参考区间落 line_N）
            ("reference_range", #"(?:参考范围|參考範圍|参考值|參考值|正常范围|正常範圍|参考区间|參考區間)[:：]?\s*(.+)"#),
            // 主诉/诊断/处理（病历）
            ("chief_complaint", #"(?:主诉|主訴)[:：]?\s*(.+)"#),
            ("diagnosis", #"(?:诊断|診斷)[:：]?\s*(.+)"#),
            ("treatment", #"(?:处理|處理|医嘱|醫囑)[:：]?\s*(.+)"#),
            // 叙事字段补全（审查修复 2026-09-18 业主实测）：此前病历只认
            // 主诉/诊断/处理三标签，现病史/既往史/家族史/过敏史整段落
            // line_N 孤行。键与 encounterSpec 叙事键同源对齐。
            ("present_illness", #"(?:现病史|現病史|病情说明|病情說明)[:：]?\s*(.+)"#),
            ("past_history", #"(?:既往史|既住史|过往病史|過往病史|过去史|過去史|既往病史|Past History|PMH)[:：]?\s*(.+)"#),
            ("family_history", #"(?:家族史|Family History)[:：]?\s*(.+)"#),
            ("allergy_history", #"(?:过敏史|過敏史|药物过敏史|藥物過敏史|Allergies)[:：]?\s*(.+)"#),
            // 检验项目行：「血红蛋白 150 g/L」「HbA1c: 5.6%」「白细胞 6.5 10^9/L 3.5-9.5」
            // （V3.61：可选尾随参考范围 → 伴随 reference_range 草稿，同 rawText 归入该检验行）
            // 审查修复：项目名类此前不含数字/连字符——HbA1c/CA125/T3/25-OH-D
            // 等注释中明示支持的分析物全行不匹配，结构化卡创建被静默丢弃
            // round10 修复：单位与参考范围**顺序可互换**——字段目录注释为
            // 「项目/结果/参考范围/单位」（"血红蛋白 150 115-150 g/L"），旧
            // 正则只认「值 单位 范围」序，目录自身次序整卡静默不建；冒号后
            // 空白改为可选（"血红蛋白：150" 此前不匹配）。
            ("lab_item", #"^([一-龥A-Za-z0-9\*\-\/]{1,20})(?:[:：]\s*|\s+)([0-9]+\.?[0-9]*)\s*((?:10\^[0-9]+/)?[a-zA-Z/%μ·]+)?(?:\s+([0-9]+\.?[0-9]*)\s*[-–~～]\s*([0-9]+\.?[0-9]*))?\s*((?:10\^[0-9]+/)?[a-zA-Z/%μ·]+)?$"#),
        ]
        return patterns.compactMap { key, pattern in
            let compiled = try? NSRegularExpression(pattern: pattern)   // try?-ok: 模式为编译期静态字面量，构造不会失败
            return compiled.map { (key, $0) }
        }
    }()

    /// `(.+)` 贪婪捕获的自由文本角色——其值必须按标签边界截断，
    /// 否则一行多标签时每个字段都吞掉后面的标签与值（2026-09-16 实测污染）。
    private static let freeTextRoles: Set<String> = [
        "dept", "reference_range", "chief_complaint", "diagnosis", "treatment",
        "present_illness", "past_history", "family_history", "allergy_history",
    ]

    /// 叙事字段键（多行并入判据，2026-09-18 业主实测）：这些角色的值
    /// 天然多行（主诉/现病史/既往史段落），标签行后的无标签行并入而非
    /// 落 line_N。单一事实源：本表与 fieldPatterns 叙事键逐条对齐。
    /// 刻意**不含** diagnosis/treatment：诊断/医嘱是结构化短字段，其后
    /// 常跟报告标题/医生/检验行——吸收会吞掉后续结构化行（标签直配
    /// 三语测试实测回归）。
    public static let narrativeFieldKeys: Set<String> = [
        "chief_complaint", "present_illness", "past_history",
        "family_history", "allergy_history",
    ]

    /// 叙事续行并入（纯函数，可单测）：lines[startIndex..<n] 逐行并入，
    /// 直到调用方判定为边界的行。返回并入文本（换行拼接）与吸收行数
    /// （边界行不计入）。逐字拼接、不重写不翻译（BR-002 不丢内容 /
    /// BR-006 不生成结论）。
    public static func mergeNarrativeLines(lines: [String], from startIndex: Int,
                                           isBoundary: (String) -> Bool) -> (text: String, absorbed: Int) {
        var parts: [String] = []
        var absorbed = 0
        var cursor = startIndex
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { cursor += 1; absorbed += 1; continue }
            if isBoundary(candidate) { break }
            parts.append(lines[cursor])
            absorbed += 1
            cursor += 1
        }
        return (parts.joined(separator: "\n"), absorbed)
    }

    /// 按判定类型收敛的启发式语义字段（期一；处方路径由既有
    /// PrescriptionFieldMapper 承担，本函数只覆盖检验/病历/通用）。
    /// 每行产出至多一个角色草稿（key=角色、value=抽取载荷、rawText=原文、
    /// source=.heuristic、confidence=0.6——中档「需复核」不预填）。
    /// 未命中任何角色的行返回 nil（调用方以通用 line_N 兜底呈现）。
    public static func guessFields(line: String) -> [FieldDraft] {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var drafts: [FieldDraft] = []
        for (key, regex) in fieldPatterns {
            guard drafts.isEmpty else { break }   // 一行一角色：首命中即定（行语义单一）
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let vRange = Range(match.range(at: 1), in: text) else { continue }
            var payload = String(text[vRange]).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            // 自由文本角色（`(.+)` 贪婪捕获）：截到**下一个标签**之前。
            // 2026-09-16 实测污染修复——`科室[:：]?\s*(.+)` 曾把
            // 「呼吸内科 医生：张三」整段收作科室值、`医生` 亦然。
            // 结构化角色（report_date/lab_item）的捕获组本身有界，不动。
            if Self.freeTextRoles.contains(key) {
                guard let truncated = ExtractionPatterns.truncatingAtLabelBoundary(payload) else { continue }
                payload = truncated
            }
            var unit: String?
            var referenceRange: String?
            if key == "lab_item" {
                // 检验项目行：载荷 = 「项目 数值 单位」（确认卡逐字段编辑
                // 以原文对照）；单位独立成槽位供 F25 读数联合解析
                if match.numberOfRanges > 2, let nRange = Range(match.range(at: 2), in: text) {
                    let number = String(text[nRange]).trimmingCharacters(in: .whitespaces)
                    payload = "\(payload) \(number)".trimmingCharacters(in: .whitespaces)
                }
                if match.numberOfRanges > 3, let uRange = Range(match.range(at: 3), in: text) {
                    let u = String(text[uRange]).trimmingCharacters(in: .whitespaces)
                    if !u.isEmpty { unit = u }
                } else if match.numberOfRanges > 6, let uRange = Range(match.range(at: 6), in: text) {
                    // 「值 范围 单位」目录次序（单位在范围之后）
                    let u = String(text[uRange]).trimmingCharacters(in: .whitespaces)
                    if !u.isEmpty { unit = u }
                }
                // 尾随参考范围（FR7.2 A 级范围随行）：低-高 两组捕获都在才成立
                if match.numberOfRanges > 5,
                   let lowRange = Range(match.range(at: 4), in: text),
                   let highRange = Range(match.range(at: 5), in: text) {
                    referenceRange = "\(text[lowRange])-\(text[highRange])"
                }
            }
            var draft = FieldDraft(key: key, value: payload, unit: unit,
                                   confidence: 0.6, rawText: text)
            draft.source = .heuristic
            drafts.append(draft)
            if let referenceRange {
                var companion = FieldDraft(key: "reference_range", value: referenceRange,
                                           confidence: 0.6, rawText: text)
                companion.source = .heuristic
                drafts.append(companion)
            }
        }
        return drafts
    }

    /// 病历类判定（FR11.4 懒创建触发判定）：门诊病历/诊断证明/体检报告
    /// 视为可派生健康问题的病历类文档。
    public static func isClinicalType(_ stableKey: String) -> Bool {
        stableKey == "outpatient_record" || stableKey == "diagnosis_certificate"
            || stableKey == "lab_report"
    }
}

public extension DocumentTypeClassifierFallback {
    // MARK: - 行内直配静态资产（一次性构造，同 `fieldPatterns` 预编译纪律）

    /// 药品/用法直配词表与医生标签（每行现算 → 常量复用）。
    private static let drugLabelPrefixes = ["药品名称", "藥品名稱", "药名", "藥名", "药品：", "藥品："]
    private static let directionsPrefixes = ["用法", "用量", "每次", "每日", "口服", "外用"]
    private static let namedFormTokens = ["胶囊", "膠囊", "颗粒", "顆粒", "注射液", "缓释片", "緩釋片"]
    private static let doctorTokens = ["医生", "醫生", "医师", "醫師"]

    /// 标签直配扩展：只取印刷值，不推导剂量、币种或下一针时间。
    private static let directLabelAliases: [(String, [String])] = [
        ("generic_name", ["通用名称", "通用名稱", "通用名"]),
        ("brand_name", ["商品名称", "商品名稱"]),
        ("spec", ["药品规格", "藥品規格", "规格", "規格"]),
        ("unit_kind", ["计量单位", "計量單位", "制剂单位", "製劑單位"]),
        ("currency", ["币种", "幣種", "Currency"]),
        ("merchant", ["收费单位", "收費單位", "收款单位", "收款單位"]),
        ("summary", ["费用摘要", "費用摘要", "摘要"]),
        ("vaccine_name", ["疫苗名称", "疫苗名稱"]),
        ("dose_number", ["接种剂次", "接種劑次", "剂次", "劑次"]),
        ("administered_at", ["接种日期", "接種日期"]),
        ("provider", ["接种单位", "接種單位"]),
        ("lot_number", ["批号", "批號"]),
    ]

    /// 药品行强度文法（药品名 + 数值 + 单位，处方页专判）。
    private static let drugStrengthPattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"^[一-龥A-Za-z][一-龥A-Za-z0-9（）() -]*?\s+[0-9]+(?:\.[0-9]+)?\s*(?:mg|g|mcg|μg|mL|ml|片|粒|支|袋)(?:\s.*)?$"#)
    /// 合计金额文法（全匹配 = 标签 + 数字载荷；再取数字段）。
    private static let amountPattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"(?:合计|合計|总额|總額|金额|金額|(?i:total|amount))\s*[:：]?\s*([0-9]+(?:\.[0-9]{1,2})?)(?![0-9.])"#)
    private static let amountNumberPattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"[0-9]+(?:\.[0-9]{1,2})?"#)
    /// 叙事并入的边界行记号（日期开头 / 编号列表）。
    private static let narrativeBoundaryPattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"^\d{4}\s*[-/年.]|^\d+[.、)]"#)

    /// Page-local extraction does not discard another card kind because the primary label differs.
    static func pageFields(lines: [String], understood: [FieldDraft], confidence: Double) -> [FieldDraft] {
        let measuredConfidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        let prescriptionPage = lines.contains { line in
            ["处方", "處方", "用法", "用量", "药品名称", "藥品名稱"].contains(where: line.contains)
        }
        let heuristicConfidence = min(0.6, measuredConfidence)
        var output: [FieldDraft] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { index += 1; continue }
            var fields = understood.filter {
                !$0.key.hasPrefix("line_") && ($0.sourceLineIndex == nil || $0.sourceLineIndex == index)
                    && ($0.rawText?.trimmingCharacters(in: .whitespacesAndNewlines) == text
                    || ($0.rawText == nil && $0.value.trimmingCharacters(in: .whitespacesAndNewlines) == text))
            }
            mergeGuessedFields(line: text, index: index, into: &fields)
            // 标签直配块（v26/v27）沿用「首个冒号之后」取值：该路径**只在行首命中标签时**进入，
            // 单标签行（`入院日期：2026-09-12`）取值正确。**同族已知问题**（2026-09-16 登记）：
            // 多标签同行仍会吞值——`出院诊断：支气管炎 出院医嘱：继续服药` 的
            // diagnosis_item 会得到整段。修它需区分**叙事键**（治疗经过合法含「诊断」二字，
            // 不得截断）与**标识键**（应截断），是一次策略决策而非机械替换，故不在本批擅动。
            let suffix = text.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" }).last.map(String.init) ?? text
            // 值域锚定（2026-09-16 实测污染修复）：取**该标签自己**的值段，右界为下一个标签。
            // 原实现取「首个冒号之后的全部文本」当值——对
            // `日期：2026-09-12 科室：呼吸内科 医生：张三` 得到 doctor = 整段（含日期与科室）、
            // department =「呼吸内科 医生：张三」、date = 整行。三者都不是任何标签的值，
            // 且本轨产物**不经 `ExtractionGrounding`**（grounding 只保护 NL 规格轨），
            // 污染值原样进确认页——医疗记录里错值比空值更危险。
            // 机构名用后缀文法：`北京协和医院 处方笺` 的尾随「处方笺」不是标签，截标签法无效；
            // 文法不命中则回落原行为（宁保守勿误截）。
            if text.contains("医院") || text.contains("醫院") {
                appendIfAbsent("hospital", ExtractionPatterns.institutionName(in: text) ?? text,
                               rawLine: line, index: index, confidence: heuristicConfidence, to: &fields)
            }
            if doctorTokens.contains(where: text.contains) {
                if let span = doctorTokens
                    .compactMap({ ExtractionPatterns.valueSpan(afterLabel: $0, in: text) }).first {
                    appendIfAbsent("doctor", span, rawLine: line, index: index, confidence: heuristicConfidence, to: &fields)
                }
            }
            // 日期：判定沿用 `parseDate`（它校验月/日域），**值改为有界日期记号**——
            // `parseDate` 内部是 `firstMatch`（行内任意位置命中即真），原实现据此把**整行**当值。
            if EntityCardProjection.parseDate(text, calendar: Calendar(identifier: .gregorian)) != nil,
               let dateSpan = ExtractionPatterns.dateToken(in: text) {
                appendIfAbsent("report_date", dateSpan, rawLine: line, index: index, confidence: heuristicConfidence, to: &fields)
            }
            appendDrugAndLabelFields(text: text, suffix: suffix, line: line, index: index,
                                     confidence: heuristicConfidence, prescriptionPage: prescriptionPage, to: &fields)
            appendInvoiceFields(text: text, line: line, index: index, confidence: heuristicConfidence, to: &fields)
            if fields.contains(where: { $0.key == "amount" }) {
                fields.removeAll { $0.key == "lab_item" || $0.key == "reference_range" }
            }
            // v27：显式标注为体检一般检查（身高 / 体重 / 血压 / 脉搏 / 腰围…）的行不是检验项目——防同一体重既成 lab.体重 又成 weight 双投影。
            if fields.contains(where: { ClinicalFieldLabels.generalExamKeys.contains($0.key) }) {
                fields.removeAll { $0.key == "lab_item" || $0.key == "reference_range" }
            }
            if fields.isEmpty {
                fields = [FieldDraft(key: "line_\(index)", value: line, confidence: measuredConfidence, rawText: line)]
            }
            if let next = absorbNarrativeLines(lines: lines, understood: understood, fields: &fields, from: index) {
                index = next
            }
            for var field in fields {
                field.sourceLineIndex = index
                field.confidence = min(measuredConfidence, field.confidence.isFinite ? max(0, field.confidence) : 0)
                output.append(field)
            }
            index += 1
        }
        return output
    }

    /// 同一行把启发式轨产出并入已有字段（模型轨与启发式轨双产出）：同名同行的草稿以含数值者
    /// 胜出；全新「键+值」对才追加（重复候选不并列）。
    private static func mergeGuessedFields(line text: String, index: Int, into fields: inout [FieldDraft]) {
        for field in guessFields(line: text) {
            let sameLineAndKey = { (existing: FieldDraft) in
                existing.key == field.key
                    && (existing.sourceLineIndex == index
                        || existing.rawText?.trimmingCharacters(in: .whitespacesAndNewlines) == text)
            }
            let hasNumber = { (draft: FieldDraft) in
                draft.value.range(of: #"[0-9]"#, options: .regularExpression) != nil
            }
            if let existingIndex = fields.firstIndex(where: sameLineAndKey) {
                // 同一原文行的同名草稿（模型轨与启发式轨双产出）：启发式
                // 载荷含数值（"血红蛋白 150"）优于仅名称的模型载荷
                // （"血红蛋白"）——后者缺 value 必填键，落库时整行被判
                // 无效且同一分析物出现两行（round10 审查 O8）。
                if hasNumber(field), !hasNumber(fields[existingIndex]) { fields[existingIndex] = field }
            } else if !fields.contains(where: { $0.key == field.key && $0.value == field.value }) {
                fields.append(field)
            }
        }
    }

    /// 「标签：值」直配的落槽（同键已存在则跳过——原局部 append 语义的单一出口）。
    private static func appendIfAbsent(_ key: String, _ value: String, rawLine: String, index: Int,
                                       confidence: Double, to fields: inout [FieldDraft]) {
        guard !fields.contains(where: { $0.key == key }) else { return }
        fields.append(FieldDraft(key: key, value: value, confidence: confidence, rawText: rawLine,
                                 source: .heuristic, sourceLineIndex: index))
    }

    /// 药品/医嘱直配 + 印刷标签直配（v26/v27 住院/检查/检验/疫苗/诊断/结论）+
    /// 报告标题词表 → report_type canonical raw（D 级建议，Picker 可改）。
    private static func appendDrugAndLabelFields(text: String, suffix: String, line: String, index: Int,
                                                 confidence: Double, prescriptionPage: Bool,
                                                 to fields: inout [FieldDraft]) {
        let explicitDrug = drugLabelPrefixes.contains(where: text.hasPrefix)
        let directions = directionsPrefixes.contains(where: text.hasPrefix)
        let namedForm = namedFormTokens.contains(where: text.contains)
        let strengthLine = prescriptionPage && drugStrengthPattern?.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)) != nil
        if explicitDrug || ((namedForm || strengthLine) && !directions) {
            appendIfAbsent("drug_name", explicitDrug ? suffix : text, rawLine: line, index: index, confidence: confidence, to: &fields)
        }
        if directions {
            appendIfAbsent("advice_text", suffix, rawLine: line, index: index, confidence: confidence, to: &fields)
        }
        if text.contains(":") || text.contains("：") {
            for (key, prefixes) in directLabelAliases where prefixes.contains(where: text.hasPrefix) {
                appendIfAbsent(key, OCRGrounding.normalized(suffix.trimmingCharacters(in: .whitespaces), key: key),
                               rawLine: line, index: index, confidence: confidence, to: &fields)
            }
            // v26 住院/检查/检验标签直配（简/繁/英，单一事实源 ClinicalFieldLabels）：只取印刷值，不推导日期/类型。
            let printed = suffix.trimmingCharacters(in: .whitespaces)
            if !printed.isEmpty {
                for (key, prefixes) in ClinicalFieldLabels.prefixAliases where prefixes.contains(where: text.hasPrefix) {
                    // v27 体检一般检查「数值 单位」拆值/单位槽位（同 lab_item 纪律；拆不开整段原文保留，不换算——BR-006/007）
                    if ClinicalFieldLabels.generalExamKeys.contains(key), let split = ClinicalFieldLabels.splitNumberUnit(printed),
                       !fields.contains(where: { $0.key == key }) {
                        fields.append(FieldDraft(key: key, value: split.value, unit: split.unit, confidence: confidence,
                                                 rawText: line, source: .heuristic, sourceLineIndex: index))
                        continue
                    }
                    appendIfAbsent(key, OCRGrounding.normalized(printed, key: key), rawLine: line, index: index, confidence: confidence, to: &fields)
                }
                // 诊断标签行 → 诊断行（diagnosis_item）+ 标签自带的类型（主/次/入院/出院…）；病理诊断留在 impression，不自动成行（§C.4）。
                if let diagnosis = ClinicalFieldLabels.diagnosisLabel(prefixOf: text), diagnosis.type != "pathology" {
                    appendIfAbsent("diagnosis_item", printed, rawLine: line, index: index, confidence: confidence, to: &fields)
                    if let type = diagnosis.type {
                        appendIfAbsent("diagnosis_type", type, rawLine: line, index: index, confidence: confidence, to: &fields)
                    }
                }
                // v27 结论标签行（检验结论 / 检查结论 / 异常发现 / 复查建议 / 就医建议）→ 结论行 + 标签自带类型；
                // 总检结论 / 健康建议归首页叙事键（overall_conclusion / health_guidance），不重复成行。
                if let conclusion = ClinicalFieldLabels.conclusionLabel(prefixOf: text) {
                    appendIfAbsent("conclusion_item", printed, rawLine: line, index: index, confidence: confidence, to: &fields)
                    appendIfAbsent("conclusion_type", conclusion.type, rawLine: line, index: index, confidence: confidence, to: &fields)
                }
            }
        }
        // 报告标题词表（「CT检查报告单」「超声检查报告」）→ report_type canonical raw（D 级建议，Picker 可改）。
        if let reportType = ClinicalFieldLabels.reportType(inTitle: text) {
            appendIfAbsent("report_type", reportType, rawLine: line, index: index, confidence: confidence, to: &fields)
        }
    }

    /// 票据信号（合计金额 / 币种 / 票据类型）——币种与类型归一化经 OCRGrounding.normalized 单出口
    /// （审查修复：旧实现内联映射漏掉 费用/費用→fee，规则轨与模型轨对同一票据
    /// 文本归一化出不同 item_type，双事实源漂移）。
    private static func appendInvoiceFields(text: String, line: String, index: Int,
                                            confidence: Double, to fields: inout [FieldDraft]) {
        if let match = amountPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let portion = String(text[range])
            if let numberMatch = amountNumberPattern?.firstMatch(in: portion, range: NSRange(portion.startIndex..., in: portion)),
               let numberRange = Range(numberMatch.range, in: portion) {
                appendIfAbsent("amount", String(portion[numberRange]), rawLine: line, index: index, confidence: confidence, to: &fields)
            }
        }
        if ["人民币", "人民幣", "CNY", "RMB"].contains(where: text.contains) {
            appendIfAbsent("currency", OCRGrounding.normalized("人民币", key: "currency"), rawLine: line, index: index, confidence: confidence, to: &fields)
        }
        if text.contains("发票") || text.contains("發票") {
            appendIfAbsent("item_type", OCRGrounding.normalized("发票", key: "item_type"), rawLine: line, index: index, confidence: confidence, to: &fields)
        } else if ["收费单", "收費單", "费用", "費用"].contains(where: text.contains) {
            appendIfAbsent("item_type", OCRGrounding.normalized("收费单", key: "item_type"), rawLine: line, index: index, confidence: confidence, to: &fields)
        } else if text.contains("收据") || text.contains("收據") {
            appendIfAbsent("item_type", OCRGrounding.normalized("收据", key: "item_type"), rawLine: line, index: index, confidence: confidence, to: &fields)
        }
    }

    /// 叙事多行并入（审查修复 2026-09-18 业主实测）：主诉/现病史/既往史
    /// 等多行段落此前只取标签所在行，后续行落 line_N 孤行或误猜成别的
    /// 角色。标签行后的无标签行逐字换行并入（BR-002 不丢内容），直到
    /// 边界行（任何 guessFields 命中行 / 日期开头 / 编号列表 / 已有
    /// 模型轨字段的行）。吸收行跳过独立处理（不产 line_N）。
    /// 返回并入后主循环应继续处理的下一行下标；无吸收返回 nil。
    private static func absorbNarrativeLines(lines: [String], understood: [FieldDraft],
                                             fields: inout [FieldDraft], from index: Int) -> Int? {
        guard let narrativeIndex = fields.firstIndex(where: { Self.narrativeFieldKeys.contains($0.key) }) else { return nil }
        var cursor = index + 1
        var absorbed: [String] = []
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { cursor += 1; continue }
            if !guessFields(line: lines[cursor]).isEmpty { break }
            if narrativeBoundaryPattern?.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil { break }
            if understood.contains(where: { ($0.sourceLineIndex ?? -1) == cursor }) { break }
            absorbed.append(lines[cursor])
            cursor += 1
        }
        guard !absorbed.isEmpty else { return nil }
        fields[narrativeIndex].value += "\n" + absorbed.joined(separator: "\n")
        return cursor - 1
    }

    static func hasVisitEvidence(in fields: [FieldDraft]) -> Bool {
        fields.contains { ["chief_complaint", "diagnosis", "treatment"].contains($0.key) }
            || fields.contains { field in
                ["门诊", "門診", "病历", "病歷", "诊断证明", "診斷證明"].contains(where: field.value.contains)
            }
    }
}
