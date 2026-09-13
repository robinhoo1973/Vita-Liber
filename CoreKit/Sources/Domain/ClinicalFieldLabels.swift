import Foundation

/// v26（子项目 D §C.2–§C.5 / D2-2）临床文书字段的**打印标签别名**（简 / 繁 / 英）单一事实源。
/// 只做两件事，均为词表匹配、非推断：
/// 1. 兜底轨「标签：值」直配（`DocumentTypeClassifierFallback.pageFields`）——只取印刷值，不推导；
/// 2. 叙事键标签剥离（`OCRGrounding.labeledValue`）——模型返回「标签后整段」即接受，禁止摘要/截断（BR-002/003）。
/// 枚举列（`report_type` / `diagnosis_type`）的词表归一在 `OCRGrounding.normalized` 经本表 `reportTypeVocabulary` /
/// `diagnosisTypeLabels` 完成；未命中原样透传，由 `EntityCardProjection.invalidFields` 交用户复核。
public enum ClinicalFieldLabels {
    /// 理解层键 → 标签前缀别名（行须含「:」/「：」，前缀命中即取冒号后的值）。
    public static let prefixAliases: [(key: String, labels: [String])] = [
        // §C.2 住院期
        ("admit_at", ["入院日期", "入院时间", "入院日期时间", "入院時間", "入院日期時間", "Admission Date", "Admitted", "Date of Admission"]),
        ("discharge_at", ["出院日期", "出院时间", "出院日期时间", "出院時間", "出院日期時間", "Discharge Date", "Discharged", "Date of Discharge"]),
        ("admit_dept", ["入院科别", "入院科室", "入院科別", "Admitting Department", "Admission Dept"]),
        ("discharge_dept", ["出院科别", "出院科室", "出院科別", "Discharge Department", "Discharge Dept"]),
        ("ward", ["病区", "病區", "Ward"]),
        ("bed_no", ["床号", "床位号", "床位", "床號", "床位號", "Bed No", "Bed"]),
        ("medical_record_no", ["病案号", "住院号", "住院病历号", "病历号", "病案號", "住院號", "住院病歷號", "病歷號", "Medical Record No", "MRN", "Inpatient No"]),
        ("inpatient_times", ["住院次数", "住院次數", "Admission Count"]),
        ("actual_days", ["实际住院天数", "实际住院日", "住院天数", "實際住院天數", "住院天數", "Length of Stay", "Hospital Days"]),
        ("admit_route", ["入院途径", "入院途徑", "Admission Route", "Admission Source"]),
        ("payment_type", ["医疗付费方式", "付费方式", "费别", "医保类型", "醫療付費方式", "付費方式", "費別", "醫保類型", "Payment Type", "Payer"]),
        ("discharge_way", ["离院方式", "出院方式", "離院方式", "Discharge Disposition", "Discharge Type"]),
        ("attending_physician", ["主治医师", "主治医生", "主治醫師", "主治醫生", "Attending Physician", "Attending"]),
        ("admit_diagnosis", ["入院诊断", "入院診斷", "Admission Diagnosis", "Admitting Diagnosis"]),
        ("discharge_diagnosis", ["出院诊断", "出院診斷", "Discharge Diagnosis"]),
        ("admit_condition", ["入院情况", "入院时情况", "入院情況", "入院時情況", "Condition on Admission", "Admission Condition"]),
        ("treatment_course", ["诊疗经过", "诊疗过程", "治疗经过", "住院经过", "診療經過", "治療經過", "住院經過", "Hospital Course", "Treatment Course"]),
        ("discharge_condition", ["出院情况", "出院时情况", "出院情況", "出院時情況", "Condition at Discharge", "Discharge Condition"]),
        ("discharge_orders", ["出院医嘱", "出院建议", "出院醫囑", "出院建議", "Discharge Instructions", "Discharge Orders"]),
        ("take_home_drugs", ["出院带药", "出院用药", "出院帶藥", "出院用藥", "Discharge Medications", "Take-home Medications"]),
        ("total_cost", ["住院总费用", "总费用", "住院费用", "住院總費用", "總費用", "住院費用", "Total Cost", "Total Charges"]),
        ("summary_doctor", ["小结医师", "记录医师", "小結醫師", "記錄醫師", "Summary Physician"]),
        ("summary_date", ["小结日期", "记录日期", "小結日期", "記錄日期", "Summary Date"]),
        // §C.4 检查报告
        ("exam_part", ["检查部位", "檢查部位", "部位", "Body Part", "Exam Part", "Region"]),
        ("exam_method", ["检查方法", "检查技术", "扫描方法", "檢查方法", "檢查技術", "掃描方法", "Technique", "Protocol"]),
        ("exam_at", ["检查日期", "检查时间", "檢查日期", "檢查時間", "Exam Date", "Examination Date", "Study Date"]),
        ("reported_at", ["报告日期", "报告时间", "報告日期", "報告時間", "Report Date", "Report Time", "Reported"]),
        ("findings", ["检查所见", "影像所见", "影像学表现", "影像学所见", "超声所见", "超声描述", "镜下所见", "肉眼所见", "内镜所见", "检查描述",
                      "檢查所見", "影像所見", "影像學表現", "影像學所見", "超聲所見", "超聲描述", "鏡下所見", "肉眼所見", "內鏡所見", "檢查描述",
                      "Findings", "Description"]),
        ("impression", ["检查结论", "诊断意见", "影像诊断", "超声诊断", "病理诊断", "诊断结果", "印象", "结论", "提示",
                        "檢查結論", "診斷意見", "影像診斷", "超聲診斷", "病理診斷", "診斷結果", "結論",
                        "Impression", "Conclusion"]),
        ("apply_doctor", ["申请医师", "申请医生", "开单医生", "申請醫師", "申請醫生", "Requesting Physician", "Referring Physician", "Ordering Physician"]),
        ("report_doctor", ["报告医师", "报告医生", "诊断医师", "报告者", "報告醫師", "報告醫生", "診斷醫師", "報告者", "Reporting Physician", "Radiologist", "Reported by"]),
        ("review_doctor", ["审核医师", "审核医生", "审核者", "复核医师", "審核醫師", "審核醫生", "審核者", "復核醫師", "Reviewed by", "Verified by", "Reviewer"]),
        ("report_no", ["报告编号", "报告单号", "报告号", "检查号", "影像号", "報告編號", "報告單號", "報告號", "檢查號", "影像號", "Report No", "Accession No", "Exam No"]),
        // §C.5 检验表头
        ("specimen_type", ["标本类型", "标本种类", "样本类型", "标本", "標本類型", "標本種類", "樣本類型", "標本", "Specimen Type", "Sample Type", "Specimen"]),
        ("specimen_no", ["标本号", "样本号", "条码号", "標本號", "樣本號", "條碼號", "Specimen No", "Sample No", "Barcode"]),
        ("lab_name", ["检验科室", "实验室", "檢驗科室", "實驗室", "Laboratory"]),
        ("test_class", ["检验类别", "检验类型", "檢驗類別", "檢驗類型", "Test Class", "Test Category", "Panel"]),
        ("collected_at", ["采集时间", "采样时间", "抽血时间", "标本采集时间", "采集日期", "採集時間", "採樣時間", "抽血時間", "標本採集時間", "採集日期",
                          "Collected", "Collection Time", "Collection Date", "Sampled"]),
        ("received_at", ["接收时间", "签收时间", "送检时间", "接收時間", "簽收時間", "送檢時間", "Received"]),
        ("send_doctor", ["送检医师", "送检医生", "送檢醫師", "送檢醫生", "Sending Physician"]),
        ("test_doctor", ["检验者", "检验医师", "检验人", "检验师", "操作者", "檢驗者", "檢驗醫師", "檢驗人", "檢驗師", "操作者", "Tested by", "Technologist", "Analyst"]),
        ("clinical_diagnosis", ["临床诊断", "臨床診斷", "Clinical Diagnosis"]),
    ]

    /// 诊断标签 → `diagnosis_type` canonical raw（标签本身即类型；值为诊断名称原文）。
    public static let diagnosisTypeLabels: [(type: String, labels: [String])] = [
        ("primary", ["主要诊断", "主诊断", "主要診斷", "主診斷", "Principal Diagnosis", "Primary Diagnosis", "Main Diagnosis"]),
        ("secondary", ["次要诊断", "其他诊断", "次要診斷", "其他診斷", "Secondary Diagnosis", "Other Diagnosis", "Other Diagnoses"]),
        ("admission", ["入院诊断", "入院診斷", "Admission Diagnosis", "Admitting Diagnosis"]),
        ("discharge", ["出院诊断", "出院診斷", "Discharge Diagnosis"]),
        ("preop", ["术前诊断", "術前診斷", "Preoperative Diagnosis", "Pre-op Diagnosis"]),
        ("postop", ["术后诊断", "術後診斷", "Postoperative Diagnosis", "Post-op Diagnosis"]),
        ("pathology", ["病理诊断", "病理診斷", "Pathological Diagnosis", "Pathologic Diagnosis"]),
        ("certificate", ["诊断证明", "診斷證明", "Diagnosis Certificate"]),
    ]

    /// 无类型语义的诊断标签（行 → `diagnosis_item`，类型由文档键派生默认）。
    public static let plainDiagnosisLabels: [String] = ["诊断名称", "診斷名稱", "初步诊断", "初步診斷", "诊断", "診斷", "Diagnosis"]

    /// 报告类型词表（首命中即定；核医学在 CT 之前——「PET/CT」归核医学；英文缩写按整词匹配防 DOCTOR 含 CT）。
    public static let reportTypeVocabulary: [(type: String, tokens: [String])] = [
        ("nuclear", ["PET", "SPECT", "ECT", "核医学", "核醫學", "放射性核素", "Nuclear"]),
        ("mri", ["MRI", "MR", "磁共振", "核磁", "Magnetic Resonance"]),
        ("ct", ["CT", "电子计算机断层", "計算機斷層", "電腦斷層", "计算机断层"]),
        ("xray", ["X线", "X光", "X線", "X-ray", "X-Ray", "Xray", "胸片", "平片", "钼靶", "鉬靶", "Radiograph"]),
        ("ultrasound", ["超声", "超聲", "B超", "彩超", "Ultrasound", "Sonograph", "Doppler"]),
        ("ecg", ["心电图", "心電圖", "心电", "心電", "ECG", "EKG", "Electrocardiogram", "Holter", "动态心电", "動態心電"]),
        ("endoscopy", ["内镜", "內鏡", "内窥镜", "內窺鏡", "胃镜", "胃鏡", "肠镜", "腸鏡", "支气管镜", "支氣管鏡", "喉镜", "喉鏡", "膀胱镜", "膀胱鏡",
                       "Endoscop", "Gastroscop", "Colonoscop", "Bronchoscop"]),
        ("pathology", ["病理", "活检", "活檢", "Pathology", "Biopsy", "Histopath", "Cytolog"]),
        ("other", ["其他", "其它", "Other"]),
    ]

    /// 报告标题证据：含「报告/检查/Report/Exam」之一的行才按词表判型（避免正文提及「胃镜」被当标题）。
    private static let reportTitleMarkers = ["报告", "報告", "检查", "檢查", "Report", "Exam", "Study"]

    /// 定性/半定量结果词表与比较符文法（原文抄录）。
    private static let qualitativeResultPattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"^(?:(?:阴性|陰性|阳性|陽性|弱阳性|弱陽性|可疑|未检出|未檢出|未见|未見|正常|异常|異常|Negative|Positive|Neg|Pos|Reactive|Non-?reactive|Nonreactive|Detected|Not\s?detected|Normal|Abnormal|Trace)\S*|[<>≤≥]=?\s*\d\S*|[+\-±]{1,4})$"#,
        options: [.caseInsensitive])

    /// 叙事键剥标签用的全部标签（`prefixAliases` ∪ 诊断标签），供 `OCRGrounding.labeledValue`。
    public static let narrativeLabels: Set<String> = Set(prefixAliases.flatMap(\.labels) + diagnosisTypeLabels.flatMap(\.labels) + plainDiagnosisLabels)

    /// 行首诊断标签 → (类型 canonical raw 或 nil=无类型语义) ；非诊断标签返回 nil。
    public static func diagnosisLabel(prefixOf text: String) -> (type: String?, label: String)? {
        for (type, labels) in diagnosisTypeLabels {
            if let label = labels.first(where: { text.hasPrefix($0) }) { return (type, label) }
        }
        if let label = plainDiagnosisLabels.first(where: { text.hasPrefix($0) }) { return (nil, label) }
        return nil
    }

    /// 打印标签 → `diagnosis_type` canonical raw（已是 canonical 原样；未命中 nil）。
    public static func diagnosisType(forLabel value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if Diagnosis.diagnosisTypes.contains(trimmed) { return trimmed }
        for (type, labels) in diagnosisTypeLabels where labels.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return type }
        return nil
    }

    /// 印刷类型词/标题 → `report_type` canonical raw（已是 canonical 原样；未命中 nil）。
    public static func reportType(forValue value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExamReport.reportTypes.contains(trimmed) { return trimmed }
        for (type, tokens) in reportTypeVocabulary where tokens.contains(where: { contains(trimmed, token: $0) }) { return type }
        return nil
    }

    /// 报告标题行 → `report_type`（须同时含标题证据词与词表词；无则 nil）。
    public static func reportType(inTitle line: String) -> String? {
        guard reportTitleMarkers.contains(where: { line.contains($0) }) else { return nil }
        for (type, tokens) in reportTypeVocabulary where type != "other" && tokens.contains(where: { contains(line, token: $0) }) { return type }
        return nil
    }

    /// 「项目 结果」合体载荷（结果非数值）→ (项目, 结果原文)：尾段（先两词「Not detected」、再单词）为定性词/比较符文法/
    /// 加减号才拆；否则 nil（不猜）。
    public static func splitQualitativeReading(_ value: String) -> (name: String, result: String)? {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count > 1, let regex = qualitativeResultPattern else { return nil }
        for tailCount in [2, 1] where parts.count > tailCount {
            let tail = parts.suffix(tailCount).joined(separator: " ")
            if regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil {
                return (parts.dropLast(tailCount).joined(separator: " "), tail)
            }
        }
        return nil
    }

    /// 词表包含判定：纯 ASCII 字母词按整词（不含相邻字母）匹配，防「DOCTOR」含「CT」、「MRN」含「MR」；其余子串。
    private static func contains(_ text: String, token: String) -> Bool {
        let ascii = token.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
        guard ascii else { return text.contains(token) }
        let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: token) + (token.count <= 3 ? "(?![A-Za-z])" : "")
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
