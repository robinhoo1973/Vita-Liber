import Foundation

/// FR6.9 V3.61：已确认的实体卡 → 持久化意图（纯 Domain，零 IO）。
/// 纪律：行级必填缺失/非数值行**跳过不阻断**；日期解析失败即不落库（不猜日期）；
/// 编码只在字段携带用户确认的 `codeResolution` 时回填（BR-003/FR25.11）；医学数值零硬编码。
public enum EntityCardProjection {
    public struct HospitalProjection: Sendable, Equatable {
        public var samples: [HospitalSample]
        public var skippedRows: Int
        public var rowIds: [UUID]
        public var remainingRows: [MatchedCardRow]
    }

    /// 处方行意图：`line.id = rowId`（与 v25 回填 `id = row_id` 同纪律，确定性）、`sourceRowId = rowId`、
    /// `sourcePage = card.pageIndex`、`ordinal` = 卡内行序（0 起，store 按表内 `MAX(ordinal)+1` 偏移）；
    /// `prescriptionId/patientId = PrescriptionLine.unassignedId` 与 `createdAt/updatedAt` 由 store 填。
    public struct PrescriptionLineIntent: Sendable, Equatable {
        public var rowId: UUID
        public var line: PrescriptionLine
        public init(rowId: UUID, line: PrescriptionLine) { self.rowId = rowId; self.line = line }
    }

    /// 处方卡 → 表头 + 行（v25 §C.6）。`adviceText` 只承担共享「医嘱原文/整段用法」，不再折叠药品行。
    public struct PrescriptionIntent: Sendable, Equatable {
        public var hospital: String?
        public var doctor: String?
        public var adviceText: String
        public var prescribedAt: Date
        public var department: String?
        public var prescriptionNo: String?
        /// canonical raw（general/emergency/pediatric/narcotic/psychotropic/tcm/other），展示经 fieldValueDisplay。
        public var prescriptionType: String?
        public var feeTypeText: String?
        public var clinicalDiagnosis: String?
        public var pharmacistNames: String?
        public var totalAmount: Double?
        public var lines: [PrescriptionLineIntent]
        public init(hospital: String? = nil, doctor: String? = nil, adviceText: String, prescribedAt: Date,
                    department: String? = nil, prescriptionNo: String? = nil, prescriptionType: String? = nil,
                    feeTypeText: String? = nil, clinicalDiagnosis: String? = nil, pharmacistNames: String? = nil,
                    totalAmount: Double? = nil, lines: [PrescriptionLineIntent] = []) {
            self.hospital = hospital; self.doctor = doctor; self.adviceText = adviceText; self.prescribedAt = prescribedAt
            self.department = department; self.prescriptionNo = prescriptionNo; self.prescriptionType = prescriptionType
            self.feeTypeText = feeTypeText; self.clinicalDiagnosis = clinicalDiagnosis; self.pharmacistNames = pharmacistNames
            self.totalAmount = totalAmount; self.lines = lines
        }
    }

    /// 费用明细行意图（v25 `claim_line`）：数量为原文 + 单位；金额按票面（退费行负数原样）。
    public struct ClaimLineIntent: Sendable, Equatable {
        public var rowId: UUID
        public var itemName: String
        public var itemCodeText: String?
        public var insuranceCode: String?
        public var spec: String?
        public var quantityText: String?
        public var quantityUnit: String?
        public var feeCategoryText: String?
        public var executingDept: String?
        public var selfPayRatioText: String?
        public var rawText: String?
        public var unitPrice: Double?
        public var amount: Double?
        public var feeAt: Date?
        public init(rowId: UUID, itemName: String, itemCodeText: String? = nil, insuranceCode: String? = nil, spec: String? = nil,
                    quantityText: String? = nil, quantityUnit: String? = nil, feeCategoryText: String? = nil,
                    executingDept: String? = nil, selfPayRatioText: String? = nil, rawText: String? = nil,
                    unitPrice: Double? = nil, amount: Double? = nil, feeAt: Date? = nil) {
            self.rowId = rowId; self.itemName = itemName; self.itemCodeText = itemCodeText; self.insuranceCode = insuranceCode
            self.spec = spec; self.quantityText = quantityText; self.quantityUnit = quantityUnit
            self.feeCategoryText = feeCategoryText; self.executingDept = executingDept; self.selfPayRatioText = selfPayRatioText
            self.rawText = rawText; self.unitPrice = unitPrice; self.amount = amount; self.feeAt = feeAt
        }
    }

    /// 票据卡 → 表头 + 行（v25 §C.7）。票据页（无明细行）`lines` 为空，表头即实体。
    public struct ClaimIntent: Sendable, Equatable {
        public var itemType: String
        public var amount: Double
        public var currency: String
        public var date: Date
        public var merchant: String?
        public var summary: String?
        public var invoiceNo: String?
        public var insuranceTypeText: String?
        public var reimbursedAmount: Double?
        public var outOfPocket: Double?
        public var personalAccountAmount: Double?
        public var lines: [ClaimLineIntent]
        public init(itemType: String, amount: Double, currency: String, date: Date, merchant: String? = nil, summary: String? = nil,
                    invoiceNo: String? = nil, insuranceTypeText: String? = nil, reimbursedAmount: Double? = nil,
                    outOfPocket: Double? = nil, personalAccountAmount: Double? = nil, lines: [ClaimLineIntent] = []) {
            self.itemType = itemType; self.amount = amount; self.currency = currency; self.date = date
            self.merchant = merchant; self.summary = summary; self.invoiceNo = invoiceNo; self.insuranceTypeText = insuranceTypeText
            self.reimbursedAmount = reimbursedAmount; self.outOfPocket = outOfPocket; self.personalAccountAmount = personalAccountAmount
            self.lines = lines
        }
    }

    /// `prescription_type` CHECK 枚举（SchemaV2 同拼写）。
    public static let prescriptionTypes: Set<String> = ["general", "emergency", "pediatric", "narcotic", "psychotropic", "tcm", "other"]

    /// REAL 列对应的模板键：出现即须可严格解析为有限数，否则判无效交用户复核（不静默丢弃、不换算）。
    /// v26：检验行 `value` 不再在此——非数值结果（阴性 / <0.5 / +）合法，由 `labProjection` 分流进 `lab_result`（§C.5）。
    static let numericKeys: [String: Set<String>] = [
        "metric_sample": ["ref_low", "ref_high"],
        "prescription": ["total_amount", "unit_price", "line_amount"],
        "claim_item": ["reimbursed_amount", "out_of_pocket", "personal_account_amount", "unit_price", "item_amount"],
        "hospitalization": ["total_cost"],
    ]
    /// INTEGER 列对应的模板键：出现即须可解析为整数（住院次数/实际住院天数为打印数字，不推算）。
    static let integerKeys: [String: Set<String>] = [
        "hospitalization": ["inpatient_times", "actual_days"],
    ]
    /// 共享日期键之外的可选日期键：出现即须可解析（不猜日期）。
    static let optionalDateKeys: [String: Set<String>] = [
        "prescription": ["start_date", "end_date"],
        "claim_item": ["fee_at"],
        "metric_sample": ["collected_at", "received_at", "reported_at"],
        "hospitalization": ["admit_at", "discharge_at", "summary_date"],
        "diagnosis": ["diagnosed_at"],
        "exam_report": ["exam_at", "reported_at"],
        // v27（子项目 J）：体检报告日期 / 手术结束时间——出现即须可解析
        "health_exam": ["report_date"],
        "surgery": ["ended_at"],
    ]
    /// `hospitalization` 卡派生就诊类型的许可集（§C.2：kind ∈ inpatient/daySurgery）。
    static let hospitalizationKinds: Set<String> = [EncounterKind.inpatient.rawValue, EncounterKind.daySurgery.rawValue]

    /// OCR 日期 → 当日零点；解析失败 nil。文法**委托** `ExtractionPatterns.dateMatch`（round5 Q4 单文法：
    /// 4/2 位年、全角、OCR 混淆字、紧凑 8 位、标签前缀/时间后缀忽略）——此前本处第五份近似正则。
    /// 本处只负责日历合法性（2 月 30 日 → nil）与时区当日零点。
    public static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        guard let match = ExtractionPatterns.dateMatch(in: text) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var components = DateComponents(year: match.year, month: match.month, day: match.day)
        components.hour = 0; components.minute = 0; components.second = 0
        guard let date = gregorian.date(from: components), date.timeIntervalSince1970.isFinite,
              gregorian.component(.year, from: date) == match.year,
              gregorian.component(.month, from: date) == match.month, gregorian.component(.day, from: date) == match.day else { return nil }
        return date
    }

    /// 共享面日期键取值（「键存在且可解析才取」的单一出口）——五处意图构造
    /// （检验表头/住院/检查/体检/手术）此前各自内联同构闭包。
    static func sharedDate(_ key: String, in shared: [String: String], calendar: Calendar) -> Date? {
        shared[key].flatMap { parseDate($0, calendar: calendar) }
    }

    /// 检验卡 → 医院来源样本（趋势点读面）。v26 起为 `labProjection(from:calendar:).samples` 的薄封装：
    /// 定性/比较符行（进 `lab_result`）与无效行对本读面一并计作跳过；无有效日期 → 全部跳过（不猜）。
    public static func hospitalSamples(from card: MatchedCard, calendar: Calendar) -> HospitalProjection {
        let lab = labProjection(from: card, calendar: calendar)
        let qualitativeIds = Set(lab.qualitative.map(\.rowId))
        let remaining = lab.remainingRows + card.rows.filter { qualitativeIds.contains($0.id) }
        return HospitalProjection(samples: lab.samples, skippedRows: remaining.count, rowIds: lab.rowIds, remainingRows: remaining)
    }

    /// 就诊卡 → 就诊草稿（日期必填；kind 缺省门诊）。
    public static func encounterDraft(from card: MatchedCard, patientId: UUID, calendar: Calendar) -> EncounterDraft? {
        let shared = dictionary(card.shared)
        guard card.kind == "encounter", let row = card.rows.first,
              invalidFields(in: card, row: row, calendar: calendar).isEmpty,
              let date = shared["date"].flatMap({ parseDate($0, calendar: calendar) }), let kind = shared["kind"] else { return nil }
        return EncounterDraft(patientId: patientId, date: date,
                              kind: kind,
                              hospital: shared["hospital"], department: shared["department"],
                              doctor: shared["doctor"], chiefComplaint: shared["chief_complaint"],
                              diagnosisText: shared["diagnosis_text"], adviceText: shared["advice_text"],
                              presentIllness: shared["present_illness"], visitSummary: shared["visit_summary"],
                              pastHistory: shared["past_history"], physicalExam: shared["physical_exam"],
                              allergyHistory: shared["allergy_history"])
    }

    /// 处方卡 → 表头 + 逐行 `PrescriptionLineIntent`（空卡 nil）。`adviceText` 只取共享 `advice_text`
    ///（无则空串）；药品行不再拼串——`dosage→doseText+doseUnit`、`quantity→quantityText+quantityUnit`、
    /// `days→durationText`、`frequency→frequencyText`、`route→routeText`，一律原文（BR-006/007）。
    public static func prescriptionIntent(from card: MatchedCard) -> PrescriptionIntent? {
        let calendar = Calendar(identifier: .gregorian)
        guard card.kind == "prescription", !card.rows.isEmpty,
              card.rows.allSatisfy({ invalidFields(in: card, row: $0, calendar: calendar).isEmpty }) else { return nil }
        let placeholder = Date(timeIntervalSince1970: 0)
        var lines: [PrescriptionLineIntent] = []
        for row in card.rows {
            let dict = dictionary(row.fields)
            guard let name = dict["drug_name"] else { return nil }
            // round5 Q1：键→列写入经 `PrescriptionLineField` 单表（此前字面量映射漏 `unit`，用户补填的剂量单位被静默丢弃）。
            var line = PrescriptionLine(
                id: row.id, prescriptionId: PrescriptionLine.unassignedId, patientId: PrescriptionLine.unassignedId,
                ordinal: lines.count, printedName: name, rawText: rawText(row.fields),
                sourcePage: card.pageIndex, sourceRowId: row.id, confirmed: false,
                createdAt: placeholder, updatedAt: placeholder)
            for field in PrescriptionLineField.allCases where field != .drugName {
                guard let text = dict[field.key] else { continue }
                field.apply(text, unitText: confirmedUnit(row.fields, key: field.key), to: &line, calendar: calendar)
            }
            lines.append(PrescriptionLineIntent(rowId: row.id, line: line))
        }
        let shared = dictionary(card.shared)
        guard let date = shared["prescribed_at"].flatMap({ parseDate($0, calendar: calendar) }) else { return nil }
        return PrescriptionIntent(hospital: shared["hospital"], doctor: shared["doctor"],
                                  adviceText: shared["advice_text"] ?? "", prescribedAt: date,
                                  department: shared["department"], prescriptionNo: shared["prescription_no"],
                                  prescriptionType: shared["prescription_type"], feeTypeText: shared["fee_type"],
                                  clinicalDiagnosis: shared["clinical_diagnosis"], pharmacistNames: shared["pharmacist_names"],
                                  totalAmount: shared["total_amount"].flatMap(Double.init), lines: lines)
    }

    /// 票据卡 → 表头 + 费用明细行（票据页仅一空行 → `lines` 空，沿表头路径）。任一行无效即 nil（与处方同构）。
    public static func claimIntent(from card: MatchedCard, calendar: Calendar) -> ClaimIntent? {
        guard card.kind == "claim_item", !card.rows.isEmpty,
              card.rows.allSatisfy({ invalidFields(in: card, row: $0, calendar: calendar).isEmpty }) else { return nil }
        let shared = dictionary(card.shared)
        guard let amount = shared["amount"].flatMap(Double.init), let currency = shared["currency"], let type = shared["item_type"],
              let date = shared["date"].flatMap({ parseDate($0, calendar: calendar) }) else { return nil }
        var lines: [ClaimLineIntent] = []
        for row in card.rows {
            let dict = dictionary(row.fields)
            guard let name = dict["item_name"] else { continue }   // 空行 = 表头即实体（allowsEmptyRows）
            lines.append(ClaimLineIntent(
                rowId: row.id, itemName: name, itemCodeText: dict["item_code"], insuranceCode: dict["insurance_code"],
                spec: dict["item_spec"], quantityText: dict["item_quantity"], quantityUnit: confirmedUnit(row.fields, key: "item_quantity"),
                feeCategoryText: dict["fee_category"], executingDept: dict["executing_dept"], selfPayRatioText: dict["self_pay_ratio"],
                rawText: rawText(row.fields), unitPrice: dict["unit_price"].flatMap(Double.init),
                amount: dict["item_amount"].flatMap(Double.init),
                feeAt: dict["fee_at"].flatMap { parseDate($0, calendar: calendar) }))
        }
        return ClaimIntent(itemType: type, amount: amount, currency: currency, date: date,
                           merchant: shared["merchant"], summary: shared["summary"], invoiceNo: shared["invoice_no"],
                           insuranceTypeText: shared["insurance_type"],
                           reimbursedAmount: shared["reimbursed_amount"].flatMap(Double.init),
                           outOfPocket: shared["out_of_pocket"].flatMap(Double.init),
                           personalAccountAmount: shared["personal_account_amount"].flatMap(Double.init), lines: lines)
    }

    /// 卡片互联（FR6.9 期二）的归属规则现已由 `EncounterResolver`（同模块
    /// EncounterAssociation.swift）承担——显式用户选择 + 证据化建议，写入侧
    /// 按 `EncounterAssociation` 单值裁决（无信号不猜、明确未关联不被回填
    /// 推翻）。旧的 `EncounterLinker`（同日自动匹配 + 落库回填）随 V3.66 业主
    /// 裁决整体退役并删除；不再存在任何自动归属路径。


    /// 卡内全部字段 → 确认卡字段（共享先、逐行后；显示标签由 App 层 L10n 注入）。
    public static func candidateFields(from card: MatchedCard, labelFor: (String) -> String) -> [CandidateField] {
        card.allFields.map { draft in
            CandidateField(key: draft.key, displayLabel: labelFor(draft.key), rawText: draft.rawText ?? draft.originalValue,
                           confidence: draft.confidence, value: draft.value,
                           grade: draft.grade == .rejected ? .rejected : (draft.isConfirmed ? .userConfirmed : .ocrUnconfirmed),
                           codeResolution: draft.codeResolution, revisionHistory: draft.revisionHistory)
        }
    }

    /// Current values and explicit review are authoritative, never cached missingRequired.
    /// Nonempty unreviewed/unknown optional data remains draft rather than being silently dropped.
    /// allowed/required/日期键均由 `CardKindRegistry` 派生（单一事实源）；本函数只保留值级校验
    ///（日期可解析、枚举 canonical、REAL 列可解析、参考范围有序）。
    public static func invalidFields(in card: MatchedCard, row: MatchedCardRow, calendar: Calendar) -> [String] {
        guard let entry = CardKindRegistry.entry(for: card.kind) else { return ["card_kind"] }
        // 空行 = 「表头即实体」（票据页无明细行）：不受行级必填约束；有字段的行才须齐最小集。
        let rowRequired = entry.effectiveRowRequired(forEmptyRow: row.fields.isEmpty)
        var invalid = Set<String>()
        for (fields, required, allowed) in [(card.shared, entry.sharedRequired, entry.sharedAllowed), (row.fields, rowRequired, entry.rowAllowed)] {
            let values = dictionary(fields)
            invalid.formUnion(required.filter { values[$0] == nil })
            var seen = Set<String>()
            for field in fields where field.grade != .rejected && !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if card.kind == "metric_sample", field.key == "metric_key" { continue }
                if !allowed.contains(field.key) || !field.isConfirmed || !seen.insert(field.key).inserted { invalid.insert(field.key) }
            }
        }
        let shared = dictionary(card.shared), values = dictionary(row.fields)
        if let dateKey = entry.dateKey, shared[dateKey].flatMap({ parseDate($0, calendar: calendar) }) == nil { invalid.insert(dateKey) }
        applyTypedKeyChecks(card: card, shared: shared, values: values, calendar: calendar, into: &invalid)
        applyCardKindChecks(card: card, shared: shared, values: values, calendar: calendar, into: &invalid)
        return invalid.sorted()
    }

    /// 值级键型校验（日期可解析 / REAL 列可解析 / INTEGER 列可解析）——
    /// `optionalDateKeys` / `numericKeys` / `integerKeys` 三表的单一出口。
    private static func applyTypedKeyChecks(card: MatchedCard, shared: [String: String], values: [String: String],
                                            calendar: Calendar, into invalid: inout Set<String>) {
        for key in optionalDateKeys[card.kind] ?? [] {
            for face in [shared, values] where face[key] != nil && face[key].flatMap({ parseDate($0, calendar: calendar) }) == nil { invalid.insert(key) }
        }
        for key in numericKeys[card.kind] ?? [] {
            for face in [shared, values] {
                if let text = face[key], Double(text)?.isFinite != true { invalid.insert(key) }
            }
        }
        for key in integerKeys[card.kind] ?? [] {
            for face in [shared, values] where face[key] != nil && face[key].flatMap(Int.init) == nil { invalid.insert(key) }
        }
    }

    /// 卡类专属规则（CHECK 枚举 / 二择一最小集 / 参考范围有序）——每支只读不写，
    /// 统一汇入 invalid（Set 无序，最后 sorted 出口，分支拆分不改变结果）。
    private static func applyCardKindChecks(card: MatchedCard, shared: [String: String], values: [String: String],
                                            calendar: Calendar, into invalid: inout Set<String>) {
        if card.kind == "encounter", shared["kind"].flatMap(EncounterKind.init(rawValue:)) == nil { invalid.insert("kind") }
        // v26（§C.2–C.4）二择一最小集与 CHECK 枚举：缺席留待办、不猜日期/类型。
        if card.kind == "hospitalization" {
            if let kind = shared["kind"], !hospitalizationKinds.contains(kind) { invalid.insert("kind") }
            if shared["admit_at"].flatMap({ parseDate($0, calendar: calendar) }) == nil,
               shared["discharge_at"].flatMap({ parseDate($0, calendar: calendar) }) == nil { invalid.insert("admit_at") }
        }
        if card.kind == "exam_report" {
            if let type = shared["report_type"], !ExamReport.reportTypes.contains(type) { invalid.insert("report_type") }
            if shared["exam_at"].flatMap({ parseDate($0, calendar: calendar) }) == nil,
               shared["reported_at"].flatMap({ parseDate($0, calendar: calendar) }) == nil { invalid.insert("exam_at") }
            if shared["impression"] == nil, shared["findings"] == nil { invalid.insert("impression") }
        }
        if card.kind == "diagnosis" {
            for face in [shared, values] {
                if let type = face["diagnosis_type"], !Diagnosis.diagnosisTypes.contains(type) { invalid.insert("diagnosis_type") }
            }
        }
        // v27（子项目 J）：结论类型 / 治疗类型 CHECK 枚举；治疗 content | drugs_text 二择一（形态同 exam_report impression ?? findings）。
        // severity 为打印原文，不校验不归一（BR-004/012）。
        if card.kind == "clinical_conclusion" {
            for face in [shared, values] {
                if let type = face["conclusion_type"], !ClinicalConclusion.conclusionTypes.contains(type) { invalid.insert("conclusion_type") }
            }
        }
        if card.kind == "treatment_record" {
            if let type = shared["treatment_type"], !TreatmentRecord.treatmentTypes.contains(type) { invalid.insert("treatment_type") }
            if shared["content"] == nil, shared["drugs_text"] == nil { invalid.insert("content") }
        }
        if card.kind == "metric_sample",
           let low = values["ref_low"].flatMap(Double.init), let high = values["ref_high"].flatMap(Double.init), low > high {
            invalid.formUnion(["ref_low", "ref_high"])
        }
        if card.kind == "prescription", let type = shared["prescription_type"], !prescriptionTypes.contains(type) { invalid.insert("prescription_type") }
        if card.kind == "claim_item" {
            if let amount = shared["amount"].flatMap(Double.init), amount.isFinite, amount >= 0 {} else { invalid.insert("amount") }
            if shared["currency"]?.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) == nil { invalid.insert("currency") }
            if !["invoice", "fee", "receipt"].contains(shared["item_type"] ?? "") { invalid.insert("item_type") }
        }
        if card.kind == "medication", !["tablet", "capsule", "patch", "vial"].contains(values["unit_kind"] ?? "") { invalid.insert("unit_kind") }
        if card.kind == "immunization", (shared["dose_number"].flatMap(Int.init) ?? 0) <= 0 { invalid.insert("dose_number") }
    }

    public static func isDiscarded(_ row: MatchedCardRow, in card: MatchedCard) -> Bool {
        let fields = row.fields.isEmpty ? card.shared : row.fields.filter { $0.key != "metric_key" }
        return !fields.isEmpty && fields.allSatisfy { $0.grade == .rejected }
    }

    public static func confirmedValues(_ fields: [FieldDraft]) -> [String: String] { dictionary(fields) }

    /// 与 `dictionary` 同一取值字段（首个已确认、非空值）的单位——剂量/数量单位随原字段，不跨字段借用。
    static func confirmedUnit(_ fields: [FieldDraft], key: String) -> String? {
        let unit = fields.first { $0.key == key && $0.isConfirmed && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        return unit?.isEmpty == false ? unit : nil
    }

    /// 行原文：各字段 `rawText` 按序去重拼接（同一 OCR 行拆出的多个字段共享同一原文，只保留一次）。
    static func rawText(_ fields: [FieldDraft]) -> String? {
        var seen = Set<String>()
        let lines = fields.filter { $0.isConfirmed && $0.grade != .rejected }.compactMap(\.rawText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 首个已确认、非空值胜出（共享/行两面同一取值纪律）。
    static func dictionary(_ fields: [FieldDraft]) -> [String: String] {
        var map: [String: String] = [:]
        for field in fields where field.isConfirmed && map[field.key] == nil {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { map[field.key] = value }
        }
        return map
    }
}
