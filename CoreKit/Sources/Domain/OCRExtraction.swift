import Foundation

/// 模型只定位原文中的字段，不承担单位换算、诊断生成或药品剂量推断。
public struct OCRExtractedSpan: Sendable, Equatable {
    public let key: String
    public let value: String
    public let unit: String?
    public let lineIndex: Int
    public init(key: String, value: String, unit: String? = nil, lineIndex: Int) {
        self.key = key; self.value = value; self.unit = unit; self.lineIndex = lineIndex
    }
}

public enum OCRGrounding {
    /// 理解层键目录（模板键经 `CardTemplate.mapping` 映射；键集与 `CardKindRegistry` 同源扩展）。
    public static let allowedKeys: Set<String> = [
        "hospital", "doctor", "dept", "report_date", "prescribed_at", "chief_complaint",
        "diagnosis", "treatment", "present_illness", "illness_summary", "visit_summary",
        "lab_item", "reference_range", "drug_name", "advice_text", "generic_name", "brand_name",
        "spec", "unit_kind", "dosage", "quantity", "frequency", "route", "days", "note",
        "amount", "currency", "item_type", "merchant", "summary", "vaccine_name",
        "dose_number", "administered_at", "provider", "lot_number", "reimbursed_amount", "out_of_pocket",
        // v25 就诊叙事（§C.1）
        "past_history", "physical_exam", "allergy_history",
        // v25 处方表头 + 行（§C.6）
        "prescription_no", "prescription_type", "fee_type", "clinical_diagnosis", "pharmacist_names", "total_amount",
        "drug_form", "start_date", "end_date", "as_needed", "medication_notes", "insurance_code", "item_code", "unit_price", "line_amount",
        // v25 票据表头 + 费用明细行（§C.7）
        "personal_account_amount", "invoice_no", "insurance_type",
        "fee_item", "item_amount", "item_quantity", "item_spec", "fee_category", "executing_dept", "self_pay_ratio", "fee_at",
        // v26 住院期（§C.2）
        "admit_at", "discharge_at", "admit_dept", "discharge_dept", "ward", "bed_no", "medical_record_no", "inpatient_times", "actual_days",
        "admit_route", "payment_type", "discharge_way", "attending_physician", "admit_diagnosis", "discharge_diagnosis",
        "admit_condition", "treatment_course", "discharge_condition", "discharge_orders", "take_home_drugs", "total_cost", "summary_doctor", "summary_date",
        // v26 诊断行（§C.3）：编码只存打印文本
        "diagnosis_item", "diagnosis_code", "code_system", "diagnosis_type", "diagnosed_at",
        // v26 检查报告（§C.4）：无 critical_value_flag（BR-004/012）
        "report_type", "report_no", "exam_part", "exam_method", "exam_at", "reported_at", "findings", "impression",
        "apply_doctor", "report_doctor", "review_doctor",
        // v26 检验表头 + 定性行（§C.5）；collect_time/report_time 为 collected_at/reported_at 的理解层别名
        "specimen_type", "specimen_no", "lab_name", "test_class", "collected_at", "collect_time", "received_at", "report_time",
        "send_doctor", "test_doctor", "abnormal_flag", "reference_text", "method",
        // v27 体检首页（子项目 J §E.1）：一般检查为打印原文（blood_pressure「128/82」由匹配器拆 systolic/diastolic）
        "org_name", "exam_no", "package_name", "exam_date", "total_doctor",
        "height", "weight", "bmi", "blood_pressure", "systolic", "diastolic", "pulse", "waist", "vision_left", "vision_right",
        "overall_conclusion", "health_guidance",
        // v27 结论行：severity 为打印原文，不编码（BR-004/012）
        "conclusion_item", "conclusion_type", "severity",
        // v27 手术记录（§C.8）：编码 / 级别 / 植入物 / 出血量等只存打印文本
        "surgery_at", "ended_at", "surgery_name", "surgery_code", "surgery_level", "surgeon", "assistants", "anesthesiologist", "anesthesia_method",
        "preop_diagnosis", "postop_diagnosis", "procedure_course", "intraop_findings", "implants", "specimen", "blood_loss", "transfusion", "drainage",
        "postop_orders", "complications",
        // v27 治疗记录（§C.9）：drugs_text 原文不拆行
        "treatment_type", "treated_at", "executor", "content", "drugs_text", "session", "adverse_reaction", "result",
    ]
    /// 文档类型稳定键 = `DocumentTypeKey` 全部 27 case（v27 定稿；单一事实源在枚举）。
    public static let documentTypes: Set<String> = Set(DocumentTypeKey.allCases.map(\.rawValue))
    /// 叙事键：只接受整行或「已知标签：值」剥离，模型不得摘要/截断/改写（BR-002/003）。
    public static let narrativeKeys: Set<String> = [
        "diagnosis", "diagnosis_text", "chief_complaint", "treatment", "advice_text", "summary",
        "present_illness", "illness_summary", "visit_summary",
        "past_history", "physical_exam", "allergy_history", "medication_notes", "clinical_diagnosis",
        // v26 住院/检查叙事列（§C.2/§C.4）：原文保存，App 不摘要不改写；带药只存原文（BR-006）
        "admit_diagnosis", "discharge_diagnosis", "admit_condition", "treatment_course", "discharge_condition", "discharge_orders", "take_home_drugs",
        "findings", "impression", "exam_part", "exam_method",
        // v27 体检 / 结论 / 手术 / 治疗叙事（子项目 J）：结论与药物原文整段，不摘要（BR-003/006）
        "overall_conclusion", "health_guidance", "conclusion_item", "content",
        "procedure_course", "intraop_findings", "postop_orders", "complications", "drugs_text", "adverse_reaction",
    ]
    public static let numericKeys: Set<String> = [
        "amount", "dose_number", "quantity", "days", "reimbursed_amount", "out_of_pocket",
        "total_amount", "unit_price", "line_amount", "item_amount", "personal_account_amount",
        "total_cost", "inpatient_times", "actual_days",
    ]
    /// 否定/停用守卫（简/繁/英）：行内出现即不得从该行抽药名（BR-006 否定不可删）；`ExtractionSpec.negativeGuards` 同源于此。
    public static let negationGuards: [String] = [
        "禁用", "停用", "不要", "不服用", "未服", "勿服", "过敏", "過敏",
        "allergic", "allergy", "avoid", "do not", "not take", "never", "discontinue", "stop taking",
    ]

    /// 独立于提示词的输出校验：错行、凭空编造、数字子串、删除否定均不得进入确认卡。
    /// 键集参数化（子项目 E2）：默认值 = 理解层静态集（既有调用点零改）；`ExtractionGrounding` 传入 spec 键集 /
    /// 叙事 / 数值键与叙事字段别名（`extraLabels`，如「Chief Complaint」「病情说明」）——同一防线两轨共用。
    public static func fields(_ candidates: [OCRExtractedSpan], lines: [String],
                              allowedKeys: Set<String> = OCRGrounding.allowedKeys,
                              narrativeKeys: Set<String> = OCRGrounding.narrativeKeys,
                              numericKeys: Set<String> = OCRGrounding.numericKeys,
                              extraLabels: Set<String> = []) -> [FieldDraft] {
        var seen = Set<String>()
        return candidates.prefix(128).compactMap { item in
            guard allowedKeys.contains(item.key), lines.indices.contains(item.lineIndex) else { return nil }
            let line = lines[item.lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 2048, line.range(of: value) != nil else { return nil }
            if narrativeKeys.contains(item.key), value != line, value != labeledValue(line, extraLabels: extraLabels) { return nil }
            if numericKeys.contains(item.key) || value.first?.isNumber == true || value.last?.isNumber == true {
                // 数值边界：值须在行内**某一处**以独立数字出现（E3 修正：合体行「0.3g×20 … 3天」中 `3` 首次命中落在
                // 0.3 内会被误拒——逐个出现位置检查，任一处边界合法即通过；仍拒绝只嵌在其他数字里的碎片）。
                guard Self.hasBoundedNumericOccurrence(of: value, in: line, strictLeading: numericKeys.contains(item.key) || value.first?.isNumber == true,
                                                       strictTrailing: numericKeys.contains(item.key) || value.last?.isNumber == true) else { return nil }
            }
            if ["drug_name", "generic_name"].contains(item.key),
               negationGuards.contains(where: { line.localizedCaseInsensitiveContains($0) }) { return nil }
            let unit = item.unit?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard unit == nil || unit?.isEmpty == true || line.contains(unit ?? "") else { return nil }
            if let unit, !unit.isEmpty, let unitRange = line.range(of: unit) {
                let unitLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZμµ/^%0123456789")
                if unitRange.lowerBound > line.startIndex {
                    let before = line[line.index(before: unitRange.lowerBound)]
                    if before.isLetter && before.unicodeScalars.allSatisfy({ $0.value < 128 || $0.value == 181 || $0.value == 956 }) { return nil }
                }
                if unitRange.upperBound < line.endIndex, line[unitRange.upperBound].unicodeScalars.contains(where: unitLetters.contains) { return nil }
            }
            let identity = "\(item.lineIndex)|\(item.key)|\(value)"
            guard seen.insert(identity).inserted else { return nil }
            return FieldDraft(key: item.key, value: normalized(value, key: item.key), unit: unit?.isEmpty == true ? nil : unit,
                confidence: 0.6, rawText: line, source: .foundationModels, sourceLineIndex: item.lineIndex)
        }
    }

    /// 值在行内的全部出现位置中，是否至少有一处两侧不紧邻数字/小数点/比较符（独立数字 token）。
    static func hasBoundedNumericOccurrence(of value: String, in line: String, strictLeading: Bool, strictTrailing: Bool) -> Bool {
        let boundaries = CharacterSet(charactersIn: "0123456789.,+-−<>≤≥")
        var search = line.startIndex
        while search < line.endIndex, let range = line.range(of: value, range: search..<line.endIndex) {
            var ok = true
            if strictLeading, range.lowerBound > line.startIndex,
               line[line.index(before: range.lowerBound)].unicodeScalars.contains(where: boundaries.contains) { ok = false }
            if ok, strictTrailing, range.upperBound < line.endIndex,
               line[range.upperBound].unicodeScalars.contains(where: boundaries.contains) { ok = false }
            if ok { return true }
            search = line.index(after: range.lowerBound)
        }
        return false
    }

    public static func normalized(_ value: String, key: String) -> String {
        if key == "currency", ["人民币", "人民幣", "RMB"].contains(value) { return "CNY" }
        if key == "item_type" {
            switch value { case "发票", "發票": return "invoice"; case "收费单", "收費單", "费用", "費用": return "fee"; case "收据", "收據": return "receipt"; default: break }
        }
        if key == "unit_kind" {
            switch value { case "片": return "tablet"; case "粒", "胶囊", "膠囊": return "capsule"; case "贴", "貼": return "patch"; case "支", "瓶": return "vial"; default: break }
        }
        if key == "prescription_type" {
            // 处方笺印刷类型标签 → canonical raw（prescription.prescription_type CHECK；展示经 fieldValueDisplay）。词表归一，非推断。
            switch value {
            case "普通", "普通处方", "普通處方": return "general"
            case "急诊", "急診", "急诊处方", "急診處方": return "emergency"
            case "儿科", "兒科", "儿科处方", "兒科處方": return "pediatric"
            case "麻醉", "麻醉药品", "麻醉藥品", "麻醉处方", "麻醉處方": return "narcotic"
            case "精神", "精神药品", "精神藥品", "精一", "精二", "第一类精神药品", "第二类精神药品": return "psychotropic"
            case "中药", "中藥", "中草药", "中草藥", "中药饮片", "中藥飲片", "中药处方", "中藥處方": return "tcm"
            default: break
            }
        }
        // v26：检查报告类型 / 诊断类型 → canonical raw（exam_report.report_type / diagnosis.diagnosis_type CHECK）。词表归一，非推断；
        // 未命中原样透传，由 invalidFields 交用户复核（Picker 可改）。
        if key == "report_type", let type = ClinicalFieldLabels.reportType(forValue: value) { return type }
        if key == "diagnosis_type", let type = ClinicalFieldLabels.diagnosisType(forLabel: value) { return type }
        // v27：结论类型 / 治疗类型 → canonical raw（clinical_conclusion.conclusion_type / treatment_record.treatment_type CHECK）。
        // `severity` 刻意不在此归一——打印原文入库（BR-004/012）。
        if key == "conclusion_type", let type = ClinicalFieldLabels.conclusionType(forLabel: value) { return type }
        if key == "treatment_type", let type = ClinicalFieldLabels.treatmentType(forValue: value) { return type }
        return value
    }

    /// 「已知标签：值」→ 值；标签不在已知集（内置 ∪ `ClinicalFieldLabels.narrativeLabels` ∪ `extraLabels`）则原行返回。
    static func labeledValue(_ line: String, extraLabels: Set<String> = []) -> String {
        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return line }
        let label = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        // Only an explicit field label can be removed; arbitrary colon-delimited instructions cannot.
        let labels: Set<String> = [
            "诊断", "診斷", "初步诊断", "初步診斷", "主诉", "主訴", "医嘱", "醫囑", "处理", "處理", "摘要", "Diagnosis", "Instructions", "Summary",
            // v25 叙事列标签（简/繁/英）：现病史 / 病情说明 / 就诊总结 / 既往史 / 体格检查 / 过敏史 / 贮藏 / 注意事项
            "现病史", "現病史", "Present Illness", "History of Present Illness", "HPI",
            "病情说明", "病情說明", "病情", "Illness Summary", "Condition",
            "就诊总结", "就診總結", "就诊小结", "就診小結", "Visit Summary",
            "既往史", "既往病史", "Past History", "Past Medical History", "PMH",
            "体格检查", "體格檢查", "查体", "查體", "Physical Exam", "Physical Examination",
            "过敏史", "過敏史", "药物过敏史", "藥物過敏史", "Allergy History", "Allergies",
            "贮藏", "貯藏", "储藏", "儲藏", "Storage",
            "注意事项", "注意事項", "用药注意事项", "用藥注意事項", "Precautions", "Warnings",
            "临床诊断", "臨床診斷", "Clinical Diagnosis",
        ]
        // v26 住院/检查/检验叙事标签（简/繁/英）与本地集合同为「已知标签」——单一事实源 ClinicalFieldLabels。
        guard labels.contains(label) || ClinicalFieldLabels.narrativeLabels.contains(label) || extraLabels.contains(label) else { return line }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
}
