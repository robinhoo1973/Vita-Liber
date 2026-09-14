import Foundation

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §4.2）：每种信息卡一份**可执行**的抽取规格——三轨（T1 Foundation
/// Models / T2 本机 LLM / T3 规则）同一输入；`FieldSpec.key` **= 模板键**（`CardTemplate.mapping` 值域 ∪ `rowLevelKeys`），
/// 不再经 `mapping` 二次映射。枚举 canonical 与 `OCRGrounding.normalized` 同源；别名与 `ClinicalFieldLabels` 同源；
/// 否定守卫与 `OCRGrounding.negationGuards` 同源。全部产物恒 D 级（BR-003）；类型只描述**格式**，不做单位换算 /
/// 参考范围判读 / 剂量推算（BR-004/012）。

public enum FieldType: Codable, Sendable, Equatable {
    /// `maxChars` 只作 token 预算与 T2 文法长度上限（design §6.3），**不**截断、不据此丢弃（BR-002）。
    case text(maxChars: Int), narrative(maxChars: Int), number(integer: Bool), date, quantityWithUnit, enumerated(domain: [String])

    /// 格式校验（只查格式，BR-004/012）：日期可解析（NFKC 折叠后 `EntityCardProjection.parseDate`）、数字有限
    ///（`integer` 时须为整数）、带单位量至少含一个数字、枚举须为 canonical（归一在 `OCRGrounding.normalized` 单出口）；
    /// 文本 / 叙事只要求非空白。
    public func acceptsFormat(_ value: String) -> Bool {
        let folded = value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return false }
        switch self {
        case .text, .narrative: return true
        case .date: return EntityCardProjection.parseDate(folded, calendar: .current) != nil
        case .number(let integer):
            let token = folded.replacingOccurrences(of: ",", with: "")
            if integer { return Int(token) != nil }
            guard let number = Double(token) else { return false }
            return number.isFinite
        case .quantityWithUnit: return folded.contains { $0.isNumber }
        case .enumerated(let domain): return domain.contains(folded)
        }
    }
}

public enum GroundingRule: String, Codable, Sendable { case verbatim, labeledValue, numericToken, enumNormalized }

/// T3 无标签时的启发式（吸收 `DocumentTypeClassifierFallback.pageFields` 的医院 / 日期 / 科室直配）。
public enum RuleFallback: Codable, Sendable, Equatable { case firstDateInRegion, lineContaining([String]), lineEndingWithAny([String]) }

public struct FieldSpec: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case shared, row }
    public let key: String, type: FieldType, scope: Scope, isRequired: Bool
    public let labelAliases: [String], grounding: GroundingRule, promptHint: String, fallback: RuleFallback?
    public init(key: String, type: FieldType, scope: Scope, isRequired: Bool, labelAliases: [String],
                grounding: GroundingRule, promptHint: String, fallback: RuleFallback?) {
        self.key = key; self.type = type; self.scope = scope; self.isRequired = isRequired
        self.labelAliases = labelAliases; self.grounding = grounding; self.promptHint = promptHint; self.fallback = fallback
    }
}

public struct Exemplar: Codable, Sendable, Equatable {
    public let lines: [String], json: String
    public init(lines: [String], json: String) { self.lines = lines; self.json = json }
}

public struct ExtractionSpec: Codable, Sendable, Equatable {
    public let kind: String, version: Int, shared: [FieldSpec], row: [FieldSpec], rowAnchor: String?
    public let maxRowsPerRegion: Int, exemplars: [Exemplar], negativeGuards: [String]
    /// 一行至少几个已锚定字段才成行（T3 过滤「只有项目名没有结果」的标题 / 表头误行）：处方 1、检验 / 票据 / 药品标签 2。
    public let rowMinFields: Int
    public init(kind: String, version: Int, shared: [FieldSpec], row: [FieldSpec], rowAnchor: String?,
                maxRowsPerRegion: Int, exemplars: [Exemplar], negativeGuards: [String], rowMinFields: Int) {
        self.kind = kind; self.version = version; self.shared = shared; self.row = row; self.rowAnchor = rowAnchor
        self.maxRowsPerRegion = maxRowsPerRegion; self.exemplars = exemplars; self.negativeGuards = negativeGuards
        self.rowMinFields = rowMinFields
    }

    public var requiredKeys: Set<String> { Set((shared + row).filter(\.isRequired).map(\.key)) }
    public var fields: [FieldSpec] { shared + row }
    public func field(for key: String) -> FieldSpec? { fields.first { $0.key == key } }

    /// design §6.3：Σ(键 4 + 类型上限)×行数 + JSON 开销 16，上限 1536（T1 maximumResponseTokens / F 的 n_predict 派生）。
    public var outputTokenBudget: Int {
        func cap(_ t: FieldType) -> Int {
            switch t { case .text: 24; case .narrative: 96; case .number: 8; case .date: 12; case .quantityWithUnit: 12; case .enumerated: 6 }
        }
        let perRow = row.reduce(0) { $0 + 4 + cap($1.type) }
        return min(1_536, shared.reduce(16) { $0 + 4 + cap($1.type) } + perRow * max(1, maxRowsPerRegion))
    }

    /// 缩范围重试（design §5.3）：去可选字段、少样本 ≤ 1；行锚恒保留。
    public func narrowed() -> ExtractionSpec {
        ExtractionSpec(kind: kind, version: version, shared: shared.filter(\.isRequired),
                       row: row.filter { $0.isRequired || $0.key == rowAnchor },
                       rowAnchor: rowAnchor, maxRowsPerRegion: maxRowsPerRegion, exemplars: Array(exemplars.prefix(1)),
                       negativeGuards: negativeGuards, rowMinFields: rowMinFields)
    }
}

/// 卡类 → spec 单一事实源（键集与 `CardKindRegistry` / `CardTemplateMatcher.ocrTemplates` 同源，`ExtractionSpecTests` 断言）。
/// 新增卡类 = 加一项 + 金样，零改引擎（G1）。
public enum ExtractionSpecRegistry {
    private static func f(_ key: String, _ type: FieldType, _ scope: FieldSpec.Scope = .shared, req: Bool = false,
                          aliases: [String] = [], hint: String, fallback: RuleFallback? = nil) -> FieldSpec {
        let rule: GroundingRule = {
            switch type {
            case .narrative: return .labeledValue
            case .number, .quantityWithUnit: return .numericToken
            case .enumerated: return .enumNormalized
            case .text, .date: return .verbatim
            }
        }()
        return FieldSpec(key: key, type: type, scope: scope, isRequired: req, labelAliases: aliases, grounding: rule, promptHint: hint, fallback: fallback)
    }

    /// `ClinicalFieldLabels.prefixAliases` 标签（单一事实源）+ 补充别名，保序去重。
    private static func labels(_ key: String, _ extra: [String] = []) -> [String] {
        let base = ClinicalFieldLabels.prefixAliases.first { $0.key == key }?.labels ?? []
        var seen = Set<String>()
        return (base + extra).filter { seen.insert($0).inserted }
    }

    static let hospitalAliases = ["医院", "醫院", "医疗机构", "醫療機構", "Hospital"]
    static let deptAliases = ["科室", "科别", "科別", "Department", "Dept"]
    static let doctorAliases = ["医生", "醫生", "医师", "醫師", "Doctor", "Physician"]
    static let deptWords = ["内科", "外科", "儿科", "妇产科", "眼科", "耳鼻喉科", "口腔科", "皮肤科", "骨科", "神经内科", "消化内科", "呼吸内科",
                            "心内科", "内分泌科", "肾内科", "肿瘤科", "感染科", "急诊科", "全科", "中医科", "康复科", "体检中心"]
    static let hospitalFallback: RuleFallback = .lineContaining(["医院", "醫院"])
    static let deptFallback: RuleFallback = .lineEndingWithAny(deptWords)
    static let negativeGuards = OCRGrounding.negationGuards

    // MARK: 共享字段助手（医院 / 科室 / 医生在多卡类重复）

    private static func hospital(_ hint: String = "医院/机构名") -> FieldSpec {
        f("hospital", .text(maxChars: 40), aliases: hospitalAliases, hint: hint, fallback: hospitalFallback)
    }
    private static func department(_ extra: [String] = []) -> FieldSpec {
        f("department", .text(maxChars: 20), aliases: deptAliases + extra, hint: "科室原文", fallback: deptFallback)
    }
    private static func doctor(_ extra: [String] = []) -> FieldSpec {
        f("doctor", .text(maxChars: 20), aliases: doctorAliases + extra, hint: "医师姓名原文")
    }

    // MARK: 处方（design §4.2 范本）

    static let prescriptionSpec = ExtractionSpec(kind: "prescription", version: 1, shared: [
        f("prescribed_at", .date, req: true, aliases: ["处方日期", "處方日期", "开具日期", "開具日期", "日期", "Date"], hint: "印刷日期原文", fallback: .firstDateInRegion),
        hospital(),
        department(),
        doctor(["处方医师", "處方醫師"]),
        f("clinical_diagnosis", .narrative(maxChars: 200), aliases: labels("clinical_diagnosis", ["诊断", "診斷", "Diagnosis"]), hint: "诊断整段原文"),
        f("advice_text", .narrative(maxChars: 400), aliases: ["医嘱", "醫囑", "备注", "備註", "Notes"], hint: "医嘱整段原文"),
        f("prescription_no", .text(maxChars: 32), aliases: ["处方编号", "處方編號", "处方号", "處方號", "No."], hint: "处方编号原文"),
        f("prescription_type", .enumerated(domain: ["general", "emergency", "pediatric", "narcotic", "psychotropic", "tcm"]),
          aliases: ["处方类型", "處方類型"], hint: "印刷处方类型"),
    ], row: [
        f("drug_name", .text(maxChars: 40), .row, req: true, aliases: ["药品名称", "藥品名稱", "药名", "藥名", "名称", "名稱", "Drug"], hint: "药名逐字"),
        f("spec", .quantityWithUnit, .row, aliases: ["规格", "規格", "Spec"], hint: "规格原文如 0.25g×24"),
        f("dosage", .quantityWithUnit, .row, aliases: ["用量", "单次剂量", "單次劑量", "每次", "Dose"], hint: "单次量原文"),
        f("frequency", .text(maxChars: 20), .row, aliases: ["频次", "頻次", "用法", "Freq", "Sig"], hint: "频次原文不换算"),
        f("route", .text(maxChars: 12), .row, aliases: ["途径", "途徑", "给药途径", "給藥途徑", "Route"], hint: "给药途径原文"),
        f("days", .number(integer: true), .row, aliases: ["天数", "天數", "疗程", "療程", "Days"], hint: "天数原文"),
        f("quantity", .quantityWithUnit, .row, aliases: ["数量", "數量", "Qty"], hint: "发药数量原文"),
        f("note", .text(maxChars: 60), .row, aliases: ["备注", "備註"], hint: "行备注原文"),
    ], rowAnchor: "drug_name", maxRowsPerRegion: 8, exemplars: [Exemplar(
        lines: ["药品名称 规格 数量 用法用量", "阿莫西林胶囊 0.25g×24 1盒 每次1粒 每日3次 口服 7天"],
        json: #"{"rows":[{"drug_name":"阿莫西林胶囊","spec":"0.25g×24","quantity":"1盒","dosage":"1粒","frequency":"每日3次","route":"口服","days":"7","line":1}]}"#)],
        negativeGuards: negativeGuards, rowMinFields: 1)

    // MARK: 检验（表头 + 行）

    static let metricSampleSpec = ExtractionSpec(kind: "metric_sample", version: 1, shared: [
        f("measured_at", .date, req: true, aliases: ["报告日期", "報告日期", "检验日期", "檢驗日期", "报告时间", "報告時間", "日期"], hint: "报告日期原文", fallback: .firstDateInRegion),
        hospital(),
        department(["送检科室", "送檢科室"]),
        f("clinical_diagnosis", .narrative(maxChars: 200), aliases: labels("clinical_diagnosis"), hint: "诊断原文"),
        f("specimen_type", .text(maxChars: 20), aliases: labels("specimen_type", ["样本", "樣本"]), hint: "标本类型原文"),
        f("collected_at", .date, aliases: labels("collected_at"), hint: "采集时间原文"),
        f("reported_at", .date, aliases: labels("reported_at"), hint: "报告时间原文"),
    ], row: [
        f("raw_label", .text(maxChars: 40), .row, req: true, aliases: ["项目", "項目", "检验项目", "檢驗項目", "Item", "Test"], hint: "项目名逐字"),
        f("value", .text(maxChars: 20), .row, req: true, aliases: ["结果", "結果", "Result"], hint: "结果原文（数值/比较符/定性）"),
        f("unit", .text(maxChars: 12), .row, aliases: ["单位", "單位", "Unit"], hint: "单位原文"),
        f("reference_range", .text(maxChars: 30), .row, aliases: ["参考范围", "參考範圍", "参考值", "參考值", "参考区间", "參考區間", "Reference", "Ref"], hint: "参考范围原文"),
        f("abnormal_flag", .text(maxChars: 4), .row, aliases: ["提示", "标志", "標誌", "Flag"], hint: "↑↓HL 原文"),
    ], rowAnchor: "raw_label", maxRowsPerRegion: 12, exemplars: [Exemplar(lines: ["白细胞 6.5 10^9/L 3.5-9.5"],
        json: #"{"rows":[{"raw_label":"白细胞","value":"6.5","unit":"10^9/L","reference_range":"3.5-9.5","line":0}]}"#)],
        negativeGuards: [], rowMinFields: 2)

    // MARK: 就诊 / 票据 / 药品标签 / 疫苗（计划登记表）

    static let encounterSpec = ExtractionSpec(kind: "encounter", version: 1, shared: [
        f("date", .date, req: true, aliases: ["就诊日期", "就診日期", "就诊时间", "就診時間", "日期"], hint: "就诊日期原文", fallback: .firstDateInRegion),
        hospital(),
        department(),
        doctor(),
        f("chief_complaint", .narrative(maxChars: 300), aliases: ["主诉", "主訴", "Chief Complaint"], hint: "主诉原文"),
        f("present_illness", .narrative(maxChars: 800), aliases: ["现病史", "現病史", "病情说明", "病情說明", "HPI"], hint: "现病史原文"),
        f("past_history", .narrative(maxChars: 400), aliases: ["既往史", "既往病史", "Past History", "PMH"], hint: "既往史原文"),
        f("physical_exam", .narrative(maxChars: 400), aliases: ["体格检查", "體格檢查", "查体", "查體", "Physical Exam"], hint: "体格检查原文"),
        f("allergy_history", .narrative(maxChars: 400), aliases: ["过敏史", "過敏史", "药物过敏史", "藥物過敏史", "Allergies"], hint: "过敏史原文"),
        f("diagnosis_text", .narrative(maxChars: 300), aliases: ["诊断", "診斷", "初步诊断", "初步診斷", "临床诊断", "臨床診斷", "Diagnosis"], hint: "诊断原文"),
        f("advice_text", .narrative(maxChars: 600), aliases: ["处理", "處理", "医嘱", "醫囑", "Instructions"], hint: "处理/医嘱原文"),
        f("visit_summary", .narrative(maxChars: 600), aliases: ["就诊总结", "就診總結", "就诊小结", "就診小結", "Visit Summary"], hint: "就诊总结原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    static let claimSpec = ExtractionSpec(kind: "claim_item", version: 1, shared: [
        f("date", .date, req: true, aliases: ["开票日期", "開票日期", "收费日期", "收費日期", "日期", "Date"], hint: "开票日期原文", fallback: .firstDateInRegion),
        f("amount", .number(integer: false), req: true, aliases: ["合计", "合計", "总额", "總額", "金额", "金額", "Total", "Amount"], hint: "合计金额原文"),
        f("currency", .enumerated(domain: ["CNY"]), req: true, aliases: ["币种", "幣種"], hint: "币种原文",
          fallback: .lineContaining(["人民币", "人民幣", "CNY", "RMB"])),
        f("item_type", .enumerated(domain: ["invoice", "fee", "receipt"]), req: true, aliases: ["票据类型", "票據類型"], hint: "票据类型原文",
          fallback: .lineContaining(["发票", "發票", "收费单", "收費單", "收据", "收據"])),
        f("merchant", .text(maxChars: 40), aliases: ["收费单位", "收費單位", "收款单位", "收款單位", "医院", "醫院"], hint: "收费单位原文", fallback: hospitalFallback),
        f("reimbursed_amount", .number(integer: false), aliases: ["医保支付", "醫保支付", "统筹支付", "統籌支付", "报销", "報銷"], hint: "医保支付原文"),
        f("out_of_pocket", .number(integer: false), aliases: ["个人支付", "個人支付", "自付", "自费", "自費"], hint: "个人支付原文"),
        f("invoice_no", .text(maxChars: 32), aliases: ["发票号", "發票號", "票据号", "票據號", "No."], hint: "发票号原文"),
    ], row: [
        f("item_name", .text(maxChars: 40), .row, req: true, aliases: ["项目", "項目", "项目名称", "項目名稱", "Item"], hint: "项目名逐字"),
        f("item_amount", .number(integer: false), .row, aliases: ["金额", "金額", "Amount"], hint: "行金额原文"),
        f("item_quantity", .text(maxChars: 12), .row, aliases: ["数量", "數量"], hint: "数量原文"),
        f("unit_price", .number(integer: false), .row, aliases: ["单价", "單價"], hint: "单价原文"),
        f("item_spec", .text(maxChars: 40), .row, aliases: ["规格", "規格"], hint: "规格原文"),
    ], rowAnchor: "item_name", maxRowsPerRegion: 12, exemplars: [], negativeGuards: [], rowMinFields: 2)

    static let medicationSpec = ExtractionSpec(kind: "medication", version: 1, shared: [], row: [
        f("generic_name", .text(maxChars: 40), .row, req: true, aliases: ["通用名称", "通用名稱", "通用名"], hint: "通用名逐字"),
        f("brand_name", .text(maxChars: 40), .row, aliases: ["商品名称", "商品名稱", "商品名"], hint: "商品名原文"),
        f("spec", .quantityWithUnit, .row, aliases: ["药品规格", "藥品規格", "规格", "規格"], hint: "规格原文"),
        f("unit_kind", .enumerated(domain: ["tablet", "capsule", "patch", "vial"]), .row, req: true,
          aliases: ["计量单位", "計量單位", "制剂单位", "製劑單位"], hint: "计量单位原文"),
    ], rowAnchor: "generic_name", maxRowsPerRegion: 4, exemplars: [], negativeGuards: negativeGuards, rowMinFields: 2)

    static let immunizationSpec = ExtractionSpec(kind: "immunization", version: 1, shared: [
        f("vaccine_name", .text(maxChars: 40), req: true, aliases: ["疫苗名称", "疫苗名稱", "Vaccine"], hint: "疫苗名称原文"),
        f("dose_number", .number(integer: true), req: true, aliases: ["接种剂次", "接種劑次", "剂次", "劑次", "Dose"], hint: "剂次原文"),
        f("administered_at", .date, req: true, aliases: ["接种日期", "接種日期", "Date"], hint: "接种日期原文", fallback: .firstDateInRegion),
        f("provider", .text(maxChars: 40), req: true, aliases: ["接种单位", "接種單位", "接种机构", "接種機構", "Provider"], hint: "接种单位原文"),
        f("lot_number", .text(maxChars: 32), aliases: ["批号", "批號", "Lot"], hint: "批号原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    // MARK: 住院 / 诊断 / 检查 / 体检 / 结论 / 手术 / 治疗（v26/v27 卡类；别名 = ClinicalFieldLabels 单一事实源）

    /// 住院期：多日期并存（入院 / 出院 / 小结），日期一律只认显式标签（不猜）。
    static let hospitalizationSpec = ExtractionSpec(kind: "hospitalization", version: 1, shared: [
        f("hospital", .text(maxChars: 40), req: true, aliases: hospitalAliases, hint: "医院原文", fallback: hospitalFallback),
        f("admit_at", .date, aliases: labels("admit_at"), hint: "入院日期原文"),
        f("discharge_at", .date, aliases: labels("discharge_at"), hint: "出院日期原文"),
        f("medical_record_no", .text(maxChars: 32), aliases: labels("medical_record_no"), hint: "病案号原文"),
        f("inpatient_times", .number(integer: true), aliases: labels("inpatient_times"), hint: "住院次数原文"),
        f("actual_days", .number(integer: true), aliases: labels("actual_days"), hint: "实际住院天数原文"),
        f("admit_dept", .text(maxChars: 20), aliases: labels("admit_dept"), hint: "入院科别原文"),
        f("discharge_dept", .text(maxChars: 20), aliases: labels("discharge_dept"), hint: "出院科别原文"),
        f("ward", .text(maxChars: 40), aliases: labels("ward"), hint: "病区原文"),
        f("bed_no", .text(maxChars: 40), aliases: labels("bed_no"), hint: "床号原文"),
        f("admit_route", .text(maxChars: 40), aliases: labels("admit_route"), hint: "入院途径原文"),
        f("payment_type", .text(maxChars: 40), aliases: labels("payment_type"), hint: "付费方式原文"),
        f("discharge_way", .text(maxChars: 40), aliases: labels("discharge_way"), hint: "离院方式原文"),
        f("attending_physician", .text(maxChars: 20), aliases: labels("attending_physician"), hint: "主治医师原文"),
        f("admit_diagnosis", .narrative(maxChars: 400), aliases: labels("admit_diagnosis"), hint: "入院诊断原文"),
        f("discharge_diagnosis", .narrative(maxChars: 400), aliases: labels("discharge_diagnosis"), hint: "出院诊断原文"),
        f("admit_condition", .narrative(maxChars: 400), aliases: labels("admit_condition"), hint: "入院情况原文"),
        f("treatment_course", .narrative(maxChars: 800), aliases: labels("treatment_course"), hint: "诊疗经过原文"),
        f("discharge_condition", .narrative(maxChars: 400), aliases: labels("discharge_condition"), hint: "出院情况原文"),
        f("discharge_orders", .narrative(maxChars: 400), aliases: labels("discharge_orders"), hint: "出院医嘱原文"),
        f("take_home_drugs", .narrative(maxChars: 400), aliases: labels("take_home_drugs"), hint: "出院带药原文（不拆行）"),
        f("total_cost", .number(integer: false), aliases: labels("total_cost"), hint: "住院总费用原文"),
        f("summary_doctor", .text(maxChars: 20), aliases: labels("summary_doctor"), hint: "小结医师原文"),
        f("summary_date", .date, aliases: labels("summary_date"), hint: "小结日期原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    /// 诊断行：每条一行；`diagnosis_type` 行级（主 / 次 / 入院 / 出院…标签本身即类型），共享面类型由文档键派生（匹配器 derived）。
    static let diagnosisSpec = ExtractionSpec(kind: "diagnosis", version: 1, shared: [
        f("diagnosed_at", .date, aliases: ["诊断日期", "診斷日期", "Diagnosis Date"], hint: "诊断日期原文"),
        hospital(),
    ], row: [
        f("name", .text(maxChars: 60), .row, req: true, aliases: ClinicalFieldLabels.plainDiagnosisLabels + ClinicalFieldLabels.diagnosisTypeLabels.flatMap(\.labels),
          hint: "诊断名称逐字"),
        f("code_text", .text(maxChars: 32), .row, aliases: ["ICD编码", "ICD編碼", "疾病编码", "疾病編碼", "诊断编码", "診斷編碼", "ICD-10", "ICD", "Code"], hint: "编码打印原文"),
        f("code_system", .text(maxChars: 20), .row, aliases: ["编码体系", "編碼體系", "Code System"], hint: "编码体系原文"),
        f("diagnosis_type", .enumerated(domain: Diagnosis.diagnosisTypes), .row, aliases: ["诊断类型", "診斷類型", "Diagnosis Type"], hint: "诊断类型标签原文"),
    ], rowAnchor: "name", maxRowsPerRegion: 8, exemplars: [], negativeGuards: [], rowMinFields: 1)

    /// 检查报告：`report_type` 无标签兜底走标题词表（`ClinicalFieldLabels.reportType(inTitle:)`，E3 规则轨）。
    static let examReportSpec = ExtractionSpec(kind: "exam_report", version: 1, shared: [
        f("report_type", .enumerated(domain: ExamReport.reportTypes), req: true, aliases: ["检查类型", "檢查類型", "报告类型", "報告類型", "Modality"], hint: "检查类型原文"),
        hospital(),
        department(),
        f("report_no", .text(maxChars: 32), aliases: labels("report_no"), hint: "报告编号原文"),
        f("exam_part", .narrative(maxChars: 200), aliases: labels("exam_part"), hint: "检查部位原文"),
        f("exam_method", .narrative(maxChars: 200), aliases: labels("exam_method"), hint: "检查方法原文"),
        f("exam_at", .date, aliases: labels("exam_at"), hint: "检查日期原文", fallback: .firstDateInRegion),
        f("reported_at", .date, aliases: labels("reported_at"), hint: "报告日期原文"),
        f("findings", .narrative(maxChars: 800), aliases: labels("findings"), hint: "检查所见整段原文"),
        f("impression", .narrative(maxChars: 600), aliases: labels("impression"), hint: "检查结论整段原文"),
        f("apply_doctor", .text(maxChars: 20), aliases: labels("apply_doctor"), hint: "申请医师原文"),
        f("report_doctor", .text(maxChars: 20), aliases: labels("report_doctor"), hint: "报告医师原文"),
        f("review_doctor", .text(maxChars: 20), aliases: labels("review_doctor"), hint: "审核医师原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    /// 体检首页：一般检查为打印原文（数值 + 单位），血压合体「128/82」由 T1/T3 分别给 systolic/diastolic（只拆打印分隔，不换算）。
    static let healthExamSpec = ExtractionSpec(kind: "health_exam", version: 1, shared: [
        f("org_name", .text(maxChars: 40), req: true, aliases: labels("org_name", hospitalAliases), hint: "体检机构原文",
          fallback: .lineContaining(["医院", "醫院", "体检中心", "體檢中心"])),
        f("exam_date", .date, req: true, aliases: labels("exam_date", ["日期"]), hint: "体检日期原文", fallback: .firstDateInRegion),
        f("exam_no", .text(maxChars: 32), aliases: labels("exam_no"), hint: "体检编号原文"),
        f("package_name", .text(maxChars: 40), aliases: labels("package_name"), hint: "套餐名称原文"),
        f("total_doctor", .text(maxChars: 20), aliases: labels("total_doctor"), hint: "总检医师原文"),
        f("report_date", .date, aliases: labels("reported_at"), hint: "报告日期原文"),
        f("height", .quantityWithUnit, aliases: labels("height"), hint: "身高原文含单位"),
        f("weight", .quantityWithUnit, aliases: labels("weight"), hint: "体重原文含单位"),
        f("bmi", .number(integer: false), aliases: labels("bmi"), hint: "BMI 打印值"),
        f("systolic", .number(integer: false), aliases: labels("systolic", labels("blood_pressure")), hint: "收缩压打印值"),
        f("diastolic", .number(integer: false), aliases: labels("diastolic", labels("blood_pressure")), hint: "舒张压打印值"),
        f("pulse", .quantityWithUnit, aliases: labels("pulse"), hint: "脉搏原文含单位"),
        f("waist", .quantityWithUnit, aliases: labels("waist"), hint: "腰围原文含单位"),
        f("vision_left", .text(maxChars: 12), aliases: labels("vision_left"), hint: "左眼视力原文"),
        f("vision_right", .text(maxChars: 12), aliases: labels("vision_right"), hint: "右眼视力原文"),
        f("overall_conclusion", .narrative(maxChars: 600), aliases: labels("overall_conclusion"), hint: "总检结论整段原文"),
        f("health_guidance", .narrative(maxChars: 600), aliases: labels("health_guidance"), hint: "健康指导整段原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    /// 结论行：行首结论标签成行；`severity` 为打印原文，不编码不着色（BR-004/012）。
    static let clinicalConclusionSpec = ExtractionSpec(kind: "clinical_conclusion", version: 1, shared: [
        f("org_name", .text(maxChars: 40), aliases: labels("org_name", hospitalAliases), hint: "体检机构原文"),
        f("exam_date", .date, aliases: labels("exam_date", ["日期"]), hint: "体检日期原文", fallback: .firstDateInRegion),
        f("exam_no", .text(maxChars: 32), aliases: labels("exam_no"), hint: "体检编号原文"),
    ], row: [
        f("content", .narrative(maxChars: 400), .row, req: true,
          aliases: ClinicalFieldLabels.conclusionTypeLabels.flatMap(\.labels) + ["结论", "結論", "Conclusion"], hint: "结论整段原文"),
        f("conclusion_type", .enumerated(domain: ClinicalConclusion.conclusionTypes), .row, aliases: ["结论类型", "結論類型"], hint: "结论类型标签原文"),
        f("severity", .text(maxChars: 20), .row, aliases: ["严重程度", "嚴重程度", "程度", "Severity"], hint: "严重程度打印原文"),
    ], rowAnchor: "content", maxRowsPerRegion: 8, exemplars: [], negativeGuards: [], rowMinFields: 1)

    /// 手术记录：泛日期**不**冒充手术日期（出院小结多日期并存）——手术日期只认显式标签。
    static let surgerySpec = ExtractionSpec(kind: "surgery", version: 1, shared: [
        f("surgery_at", .date, req: true, aliases: labels("surgery_at"), hint: "手术日期原文"),
        f("surgery_name", .text(maxChars: 60), req: true, aliases: labels("surgery_name"), hint: "手术名称逐字"),
        hospital(),
        department(),
        f("ended_at", .date, aliases: labels("ended_at"), hint: "手术结束时间原文"),
        f("surgery_code", .text(maxChars: 32), aliases: labels("surgery_code"), hint: "手术编码打印原文"),
        f("surgery_level", .text(maxChars: 20), aliases: labels("surgery_level"), hint: "手术级别原文"),
        f("surgeon", .text(maxChars: 20), aliases: labels("surgeon"), hint: "手术医师原文"),
        f("assistants", .text(maxChars: 40), aliases: labels("assistants"), hint: "助手原文"),
        f("anesthesiologist", .text(maxChars: 20), aliases: labels("anesthesiologist"), hint: "麻醉医师原文"),
        f("anesthesia_method", .text(maxChars: 40), aliases: labels("anesthesia_method"), hint: "麻醉方式原文"),
        f("preop_diagnosis", .narrative(maxChars: 400), aliases: labels("preop_diagnosis"), hint: "术前诊断原文"),
        f("postop_diagnosis", .narrative(maxChars: 400), aliases: labels("postop_diagnosis"), hint: "术后诊断原文"),
        f("procedure_course", .narrative(maxChars: 800), aliases: labels("procedure_course"), hint: "手术经过整段原文"),
        f("intraop_findings", .narrative(maxChars: 400), aliases: labels("intraop_findings"), hint: "术中所见整段原文"),
        f("implants", .text(maxChars: 60), aliases: labels("implants"), hint: "植入物原文"),
        f("specimen", .text(maxChars: 60), aliases: labels("specimen"), hint: "手术标本原文"),
        f("blood_loss", .text(maxChars: 20), aliases: labels("blood_loss"), hint: "出血量打印原文"),
        f("transfusion", .text(maxChars: 20), aliases: labels("transfusion"), hint: "输血原文"),
        f("drainage", .text(maxChars: 40), aliases: labels("drainage"), hint: "引流原文"),
        f("postop_orders", .narrative(maxChars: 400), aliases: labels("postop_orders"), hint: "术后医嘱整段原文"),
        f("complications", .narrative(maxChars: 400), aliases: labels("complications"), hint: "并发症原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    /// 治疗记录：单日期文书——泛日期即治疗日期（同处方 / 票据纪律）；`drugs_text` 原文不拆行。
    static let treatmentRecordSpec = ExtractionSpec(kind: "treatment_record", version: 1, shared: [
        f("treated_at", .date, req: true, aliases: labels("treated_at", ["日期"]), hint: "治疗日期原文", fallback: .firstDateInRegion),
        f("treatment_type", .enumerated(domain: TreatmentRecord.treatmentTypes), req: true, aliases: labels("treatment_type"), hint: "治疗类型原文"),
        hospital(),
        department(),
        doctor(),
        f("executor", .text(maxChars: 20), aliases: labels("executor"), hint: "执行者原文"),
        f("diagnosis_text", .narrative(maxChars: 300), aliases: ["诊断", "診斷", "临床诊断", "臨床診斷", "Diagnosis"], hint: "诊断原文"),
        f("content", .narrative(maxChars: 400), aliases: labels("content"), hint: "治疗内容整段原文"),
        f("drugs_text", .narrative(maxChars: 400), aliases: labels("drugs_text"), hint: "药物原文整段（不拆行）"),
        f("session", .text(maxChars: 20), aliases: labels("session"), hint: "治疗次数原文"),
        f("adverse_reaction", .narrative(maxChars: 400), aliases: labels("adverse_reaction"), hint: "不良反应原文"),
        f("result", .text(maxChars: 60), aliases: labels("result"), hint: "治疗结果原文"),
        f("note", .text(maxChars: 60), aliases: ["备注", "備註", "Notes"], hint: "备注原文"),
    ], row: [], rowAnchor: nil, maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)

    /// 目录顺序 = `CardKindRegistry.entries` 顺序（候选去重与 UI 呈现同序）。
    public static let specs: [ExtractionSpec] = [
        metricSampleSpec, encounterSpec, hospitalizationSpec, diagnosisSpec, examReportSpec, prescriptionSpec, claimSpec,
        medicationSpec, immunizationSpec, healthExamSpec, clinicalConclusionSpec, surgerySpec, treatmentRecordSpec,
    ]

    public static func spec(for kind: String) -> ExtractionSpec? { specs.first { $0.kind == kind } }

    /// 文档类型稳定键（主 + 次候选）→ 候选 spec（`DocumentTypeKey.targetCardKinds` ∩ 已登记，保持目录顺序去重）。
    public static func candidates(documentTypeKeys: [String]) -> [ExtractionSpec] {
        let kinds = documentTypeKeys.compactMap(DocumentTypeKey.init(rawValue:)).flatMap(\.targetCardKinds)
        var seen = Set<String>()
        return kinds.filter { seen.insert($0).inserted }.compactMap(spec(for:))
    }
}
