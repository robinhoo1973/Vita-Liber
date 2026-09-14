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
        // v27 §E.1 体检首页（子项目 J）：机构 / 编号 / 套餐 / 日期 / 总检医师 + 一般检查（数值原文；「数值 单位」由 pageFields 拆值/单位槽位）
        ("org_name", ["体检机构", "体检单位", "体检中心", "體檢機構", "體檢單位", "體檢中心", "Examination Center", "Checkup Center", "Institution"]),
        ("exam_no", ["体检编号", "体检号", "体检流水号", "體檢編號", "體檢號", "體檢流水號", "Checkup No", "Physical Exam No"]),
        ("package_name", ["体检套餐", "套餐名称", "套餐", "體檢套餐", "套餐名稱", "Package"]),
        ("exam_date", ["体检日期", "体检时间", "體檢日期", "體檢時間", "Checkup Date", "Physical Exam Date"]),
        ("total_doctor", ["总检医师", "总检医生", "主检医师", "總檢醫師", "總檢醫生", "主檢醫師", "Chief Examiner", "Summary Doctor"]),
        ("height", ["身高", "Height"]),
        ("weight", ["体重", "體重", "Weight"]),
        ("bmi", ["BMI", "体重指数", "體重指數", "Body Mass Index"]),
        ("blood_pressure", ["血压", "血壓", "Blood Pressure", "BP"]),
        ("systolic", ["收缩压", "收縮壓", "Systolic"]),
        ("diastolic", ["舒张压", "舒張壓", "Diastolic"]),
        ("pulse", ["脉搏", "脉率", "脈搏", "脈率", "Pulse", "Pulse Rate"]),
        ("waist", ["腰围", "腰圍", "Waist", "Waist Circumference"]),
        ("vision_left", ["左眼视力", "视力（左）", "视力(左)", "左眼視力", "視力（左）", "視力(左)", "Left Vision", "Vision (L)", "Vision (Left)"]),
        ("vision_right", ["右眼视力", "视力（右）", "视力(右)", "右眼視力", "視力（右）", "視力(右)", "Right Vision", "Vision (R)", "Vision (Right)"]),
        ("overall_conclusion", ["总检结论", "总检意见", "体检结论", "综合结论", "总结论", "總檢結論", "總檢意見", "體檢結論", "綜合結論", "總結論",
                                "Overall Conclusion", "Summary Conclusion", "General Conclusion"]),
        ("health_guidance", ["健康指导", "健康建议", "保健建议", "健康指導", "健康建議", "保健建議", "Health Guidance", "Health Advice"]),
        // v27 §C.8 手术记录：编码 / 级别 / 植入物 / 出血量等打印原文（术前/术后诊断同时是诊断类型标签——诊断行与手术列各取其一）
        ("surgery_at", ["手术日期", "手术时间", "手术开始时间", "手術日期", "手術時間", "手術開始時間", "Surgery Date", "Operation Date", "Date of Surgery", "Date of Operation"]),
        ("ended_at", ["手术结束时间", "结束时间", "手術結束時間", "結束時間", "Surgery End", "End Time"]),
        ("surgery_name", ["手术名称", "手术方式", "术式", "手術名稱", "手術方式", "術式", "Surgery Name", "Procedure Name", "Operation Name"]),
        ("surgery_code", ["手术编码", "手术代码", "手术操作编码", "手術編碼", "手術代碼", "手術操作編碼", "ICD-9-CM-3", "Procedure Code"]),
        ("surgery_level", ["手术级别", "手术等级", "手術級別", "手術等級", "Surgery Level", "Procedure Level"]),
        ("surgeon", ["手术医师", "手术医生", "手术者", "术者", "主刀医师", "主刀", "手術醫師", "手術醫生", "手術者", "術者", "主刀醫師", "Surgeon", "Operator"]),
        ("assistants", ["助手", "手术助手", "一助", "手術助手", "Assistant", "Assistants"]),
        ("anesthesiologist", ["麻醉医师", "麻醉医生", "麻醉师", "麻醉醫師", "麻醉醫生", "麻醉師", "Anesthesiologist", "Anesthetist"]),
        ("anesthesia_method", ["麻醉方式", "麻醉方法", "Anesthesia Method", "Anesthesia Type"]),
        ("preop_diagnosis", ["术前诊断", "術前診斷", "Preoperative Diagnosis", "Pre-op Diagnosis"]),
        ("postop_diagnosis", ["术后诊断", "術後診斷", "Postoperative Diagnosis", "Post-op Diagnosis"]),
        ("procedure_course", ["手术经过", "手术过程", "手术步骤", "手術經過", "手術過程", "手術步驟", "Operative Course", "Procedure Description", "Description of Procedure"]),
        ("intraop_findings", ["术中所见", "术中发现", "术中探查", "術中所見", "術中發現", "術中探查", "Intraoperative Findings", "Operative Findings"]),
        ("implants", ["植入物", "植入材料", "内置物", "內置物", "Implants", "Implant"]),
        ("specimen", ["手术标本", "切除标本", "送检标本", "手術標本", "切除標本", "送檢標本", "Surgical Specimen", "Specimen Sent"]),
        ("blood_loss", ["出血量", "术中出血", "失血量", "術中出血", "Blood Loss", "Estimated Blood Loss", "EBL"]),
        ("transfusion", ["输血", "输血量", "輸血", "輸血量", "Transfusion"]),
        ("drainage", ["引流", "引流管", "引流情况", "引流情況", "Drainage", "Drain"]),
        ("postop_orders", ["术后医嘱", "术后注意事项", "术后处理", "術後醫囑", "術後注意事項", "術後處理", "Postoperative Orders", "Post-op Instructions"]),
        ("complications", ["并发症", "术中并发症", "併發症", "術中併發症", "Complications"]),
        // v27 §C.9 治疗记录：类型经 normalized 归一；药物原文不拆行
        ("treatment_type", ["治疗类型", "治疗方式", "治疗项目", "治療類型", "治療方式", "治療項目", "Treatment Type"]),
        ("treated_at", ["治疗日期", "治疗时间", "执行时间", "输液日期", "治療日期", "治療時間", "執行時間", "輸液日期", "Treatment Date", "Treatment Time"]),
        ("executor", ["执行者", "执行护士", "操作护士", "執行者", "執行護士", "操作護士", "Executed by", "Performed by", "Nurse"]),
        ("content", ["治疗内容", "处置", "治疗措施", "治療內容", "處置", "治療措施", "Treatment Content"]),
        ("drugs_text", ["输液药物", "注射药物", "用药内容", "药物及剂量", "輸液藥物", "注射藥物", "用藥內容", "藥物及劑量", "Infusion Drugs", "Drugs Given", "Medications Given"]),
        ("session", ["治疗次数", "疗程", "治療次數", "療程", "Session", "Sessions"]),
        ("adverse_reaction", ["不良反应", "输液反应", "不良反應", "輸液反應", "Adverse Reaction", "Adverse Reactions"]),
        ("result", ["治疗结果", "治疗效果", "治療結果", "治療效果", "Treatment Result", "Outcome"]),
    ]

    /// v27 结论类型标签（值归一 + 行首标签成行）。标签本身即类型；值为结论原文。
    public static let conclusionTypeLabels: [(type: String, labels: [String])] = [
        ("lab", ["检验结论", "检验小结", "檢驗結論", "檢驗小結", "Lab Conclusion", "Laboratory Conclusion"]),
        ("exam", ["检查结论", "检查小结", "檢查結論", "檢查小結", "Exam Conclusion", "Examination Conclusion"]),
        ("health_exam_summary", ["总检", "总检结论", "总检意见", "综合结论", "體檢總結", "總檢", "總檢結論", "總檢意見", "綜合結論", "Overall Conclusion", "Summary"]),
        ("abnormal_finding", ["异常发现", "异常结果", "阳性发现", "阳性结果", "異常發現", "異常結果", "陽性發現", "陽性結果", "Abnormal Finding", "Abnormal Findings"]),
        ("health_advice", ["健康建议", "健康指导", "保健建议", "健康建議", "健康指導", "保健建議", "Health Advice", "Health Guidance"]),
        ("recheck_advice", ["复查建议", "随访建议", "復查建議", "隨訪建議", "Recheck", "Recheck Advice", "Follow-up Advice"]),
        ("visit_advice", ["就医建议", "就诊建议", "专科建议", "转诊建议", "就醫建議", "就診建議", "專科建議", "轉診建議", "Visit Advice", "Referral", "Referral Advice"]),
    ]

    /// 行首结论标签成行时排除的类型：总检结论 / 健康建议是体检首页叙事块（`overall_conclusion` / `health_guidance`），不重复成结论行。
    private static let headerNarrativeConclusionTypes: Set<String> = ["health_exam_summary", "health_advice"]

    /// v27 治疗类型词表（首命中即定；值归一为 treatment_record.treatment_type CHECK 枚举）。
    public static let treatmentTypeVocabulary: [(type: String, tokens: [String])] = [
        ("infusion", ["输液", "輸液", "静脉输液", "靜脈輸液", "静滴", "靜滴", "点滴", "點滴", "Infusion", "IV Drip"]),
        ("injection", ["注射", "肌注", "皮下注射", "静推", "靜推", "Injection", "Shot"]),
        ("physiotherapy", ["理疗", "理療", "物理治疗", "物理治療", "康复治疗", "康復治療", "针灸", "針灸", "Physiotherapy", "Physical Therapy", "Rehabilitation"]),
        ("dressing", ["换药", "換藥", "伤口换药", "傷口換藥", "清创", "清創", "Dressing", "Wound Care"]),
        ("other", ["其他", "其它", "Other"]),
    ]

    /// 体检一般检查数值键（标签直配时按「数值 单位」拆值/单位槽位；拆不开则整段原文保留）。
    public static let generalExamKeys: Set<String> = ["height", "weight", "bmi", "blood_pressure", "systolic", "diastolic", "pulse", "waist"]

    /// 「128/82」「128／82 mmHg」→ (收缩, 舒张)；无分隔 / 非数值 → nil（不猜）。
    public static func splitBloodPressure(_ text: String) -> (String, String)? {
        guard let regex = bloodPressurePattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let systolic = Range(match.range(at: 1), in: text), let diastolic = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[systolic]), String(text[diastolic]))
    }

    /// 「65.5 kg」「128/82 mmHg」「72 次/分」→ (值, 单位)；「22.7」→ (值, nil)；非数值开头（「约72」）→ nil（整段原文保留）。
    public static func splitNumberUnit(_ text: String) -> (value: String, unit: String?)? {
        guard let regex = numberUnitPattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let unit = Range(match.range(at: 2), in: text).map { String(text[$0]) }
        return (String(text[valueRange]), unit?.isEmpty == false ? unit : nil)
    }

    private static let bloodPressurePattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"^\s*(\d{2,3}(?:\.\d+)?)\s*[/／]\s*(\d{2,3}(?:\.\d+)?)(?!\d)"#)
    private static let numberUnitPattern: NSRegularExpression? = try? NSRegularExpression(   // try?-ok: 静态字面量，构造不会失败
        pattern: #"^\s*(\d+(?:\.\d+)?(?:\s*[/／]\s*\d+(?:\.\d+)?)?)\s*([^\d\s][^\s]*)?\s*$"#)

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

    /// 叙事键剥标签用的全部标签（`prefixAliases` ∪ 诊断标签 ∪ 结论标签），供 `OCRGrounding.labeledValue`。
    public static let narrativeLabels: Set<String> = Set(prefixAliases.flatMap(\.labels) + diagnosisTypeLabels.flatMap(\.labels) + plainDiagnosisLabels
                                                         + conclusionTypeLabels.flatMap(\.labels))

    /// 行首结论标签 → (类型 canonical raw, 标签)；总检结论 / 健康建议归首页叙事键，不成行（nil）；非结论标签 nil。
    public static func conclusionLabel(prefixOf text: String) -> (type: String, label: String)? {
        for (type, labels) in conclusionTypeLabels where !headerNarrativeConclusionTypes.contains(type) {
            if let label = labels.first(where: { text.hasPrefix($0) }) { return (type, label) }
        }
        return nil
    }

    /// 打印标签 → `conclusion_type` canonical raw（已是 canonical 原样；未命中 nil）。
    public static func conclusionType(forLabel value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClinicalConclusion.conclusionTypes.contains(trimmed) { return trimmed }
        for (type, labels) in conclusionTypeLabels where labels.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return type }
        return nil
    }

    /// 印刷治疗类型词 → `treatment_type` canonical raw（已是 canonical 原样；未命中 nil）。
    public static func treatmentType(forValue value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if TreatmentRecord.treatmentTypes.contains(trimmed) { return trimmed }
        for (type, tokens) in treatmentTypeVocabulary where tokens.contains(where: { contains(trimmed, token: $0) }) { return type }
        return nil
    }

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
