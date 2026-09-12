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
        let sorted = scores.sorted { $0.hits > $1.hits }
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

/// FR17.18 信息卡分组路由（ui-ux 4.28 OcrFieldGroupCard）：字段键 → 类别键
/// （rx=药品信息 / lab=检查结果 / visit=就诊信息 / generic=未分类）。
/// 稳定键单一事实源——App 层按类别键映射 L10n 卡头标签，键语义漂移只维护此处。
public enum FieldGroupRules {
    public static func category(ofKey key: String) -> String {
        if key.hasPrefix("rx_") { return "rx" }
        if key.hasPrefix("lab_") || key == "dept" || key == "report_date"
            || key == "reference_range" { return "lab" }
        if ["chief_complaint", "diagnosis", "treatment"].contains(key) { return "visit" }
        return "generic"
    }

    /// 信息卡呈现顺序（卡序按类别固定；卡内字段按确认集原序）
    public static let categoryOrder: [String] = ["rx", "lab", "visit", "generic"]
}

public extension DocumentTypeClassifierFallback {
    /// Page-local extraction does not discard another card kind because the primary label differs.
    static func pageFields(lines: [String], understood: [FieldDraft], confidence: Double) -> [FieldDraft] {
        let measuredConfidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        let prescriptionPage = lines.contains { line in
            ["处方", "處方", "用法", "用量", "药品名称", "藥品名稱"].contains(where: line.contains)
        }
        var output: [FieldDraft] = []
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var fields = understood.filter {
                !$0.key.hasPrefix("line_") && ($0.sourceLineIndex == nil || $0.sourceLineIndex == index)
                    && ($0.rawText?.trimmingCharacters(in: .whitespacesAndNewlines) == text
                    || ($0.rawText == nil && $0.value.trimmingCharacters(in: .whitespacesAndNewlines) == text))
            }
            for field in guessFields(line: line) {
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
            func append(_ key: String, _ value: String) {
                guard !fields.contains(where: { $0.key == key }) else { return }
                fields.append(FieldDraft(key: key, value: value, confidence: min(0.6, measuredConfidence), rawText: line, source: .heuristic, sourceLineIndex: index))
            }
            let suffix = text.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" }).last.map(String.init) ?? text
            if text.contains("医院") || text.contains("醫院") { append("hospital", suffix) }
            if ["医生", "醫生", "医师", "醫師"].contains(where: text.contains) { append("doctor", suffix) }
            if EntityCardProjection.parseDate(text, calendar: Calendar(identifier: .gregorian)) != nil {
                append("report_date", text)
            }
            let explicitDrug = ["药品名称", "藥品名稱", "药名", "藥名", "药品：", "藥品："].contains(where: text.hasPrefix)
            let directions = ["用法", "用量", "每次", "每日", "口服", "外用"].contains(where: text.hasPrefix)
            let namedForm = ["胶囊", "膠囊", "颗粒", "顆粒", "注射液", "缓释片", "緩釋片"].contains(where: text.contains)
            let strengthLine = prescriptionPage && text.range(
                of: #"^[一-龥A-Za-z][一-龥A-Za-z0-9（）() -]*?\s+[0-9]+(?:\.[0-9]+)?\s*(?:mg|g|mcg|μg|mL|ml|片|粒|支|袋)(?:\s.*)?$"#,
                options: .regularExpression) != nil
            if explicitDrug || ((namedForm || strengthLine) && !directions) { append("drug_name", explicitDrug ? suffix : text) }
            if directions { append("advice_text", suffix) }
            // 标签直配扩展：只取印刷值，不推导剂量、币种或下一针时间。
            let labels: [(String, [String])] = [
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
            if text.contains(":") || text.contains("：") {
                for (key, prefixes) in labels where prefixes.contains(where: text.hasPrefix) {
                    append(key, OCRGrounding.normalized(suffix.trimmingCharacters(in: .whitespaces), key: key))
                }
            }
            if let range = text.range(of: #"(?:合计|合計|总额|總額|金额|金額|(?i:total|amount))\s*[:：]?\s*([0-9]+(?:\.[0-9]{1,2})?)(?![0-9.])"#, options: .regularExpression) {
                let portion = String(text[range])
                if let number = portion.range(of: #"[0-9]+(?:\.[0-9]{1,2})?"#, options: .regularExpression) { append("amount", String(portion[number])) }
            }
            // 审查修复：币种/票据类型归一化经 OCRGrounding.normalized 单出口——
            // 旧实现内联映射漏掉 费用/費用→fee，规则轨与模型轨对同一票据
            // 文本归一化出不同 item_type（双事实源漂移）。
            if ["人民币", "人民幣", "CNY", "RMB"].contains(where: text.contains) {
                append("currency", OCRGrounding.normalized("人民币", key: "currency"))
            }
            if text.contains("发票") || text.contains("發票") {
                append("item_type", OCRGrounding.normalized("发票", key: "item_type"))
            } else if ["收费单", "收費單", "费用", "費用"].contains(where: text.contains) {
                append("item_type", OCRGrounding.normalized("收费单", key: "item_type"))
            } else if text.contains("收据") || text.contains("收據") {
                append("item_type", OCRGrounding.normalized("收据", key: "item_type"))
            }
            if fields.contains(where: { $0.key == "amount" }) {
                fields.removeAll { $0.key == "lab_item" || $0.key == "reference_range" }
            }
            if fields.isEmpty {
                fields = [FieldDraft(key: "line_\(index)", value: line, confidence: measuredConfidence, rawText: line)]
            }
            for var field in fields {
                field.sourceLineIndex = index
                field.confidence = min(measuredConfidence, field.confidence.isFinite ? max(0, field.confidence) : 0)
                output.append(field)
            }
        }
        return output
    }

    static func hasVisitEvidence(in fields: [FieldDraft]) -> Bool {
        fields.contains { ["chief_complaint", "diagnosis", "treatment"].contains($0.key) }
            || fields.contains { field in
                ["门诊", "門診", "病历", "病歷", "诊断证明", "診斷證明"].contains(where: field.value.contains)
            }
    }
}

/// FR11.4 懒创建触发点（V3.49）：病历类文档确认保存后，从已确认字段派生
/// 候选健康问题名——诊断字段优先（截断 40 字），无诊断回落「文档类型+日期」。
/// Domain 纯函数零业务决策：候选仅作建议，用户确认后才落 health_problem
/// （D 级建议→C 级事实）。
public enum HealthProblemDerivation {
    /// 候选名回落格式 "yyyy-MM-dd"（静态缓存——DateFormatter 构造昂贵，
    /// 每份病历保存触发一次懒创建即一次构造不必要）
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func candidateName(fields: [CandidateField], docTypeLabel: String,
                                     now: Date = Date()) -> String {
        if let diagnosis = fields.first(where: { $0.key == "diagnosis" && !$0.value.isEmpty }) {
            return String(diagnosis.value.prefix(40))
        }
        return "\(docTypeLabel)·\(dayFormatter.string(from: now))"
    }
}
