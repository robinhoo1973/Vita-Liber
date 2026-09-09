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

    public struct PrescriptionIntent: Sendable, Equatable {
        public var hospital: String?
        public var doctor: String?
        public var adviceText: String
        public var prescribedAt: Date
    }

    /// OCR 日期：yyyy-MM-dd / yyyy/M/d / yyyy年M月d日（含「日期：」前缀）→ 当日零点；解析失败 nil。
    public static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{4})\s*[-/年.]\s*(\d{1,2})\s*[-/月.]\s*(\d{1,2})(?!\d)"#),   // try?-ok: 静态字面量，构造不会失败
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let y = Range(match.range(at: 1), in: text), let m = Range(match.range(at: 2), in: text),
              let d = Range(match.range(at: 3), in: text),
              let year = Int(text[y]), let month = Int(text[m]), let day = Int(text[d]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var components = DateComponents(year: year, month: month, day: day)
        components.hour = 0; components.minute = 0; components.second = 0
        guard let date = gregorian.date(from: components), date.timeIntervalSince1970.isFinite,
              gregorian.component(.year, from: date) == year,
              gregorian.component(.month, from: date) == month, gregorian.component(.day, from: date) == day else { return nil }
        return date
    }

    /// 检验卡 → 医院来源样本。无有效日期 → 全部跳过（measured_at 必填，不猜）。
    public static func hospitalSamples(from card: MatchedCard, calendar: Calendar) -> HospitalProjection {
        let shared = dictionary(card.shared)
        var samples: [HospitalSample] = []
        var rowIds: [UUID] = []
        var remaining: [MatchedCardRow] = []
        for row in card.rows {
            let invalid = invalidFields(in: card, row: row, calendar: calendar)
            let fields = dictionary(row.fields)
            guard invalid.isEmpty, let measuredAt = shared["measured_at"].flatMap({ parseDate($0, calendar: calendar) }),
                  let label = fields["raw_label"], let value = fields["value"].flatMap(Double.init),
                  let unit = fields["unit"] else {
                var residual = row; residual.missingRequired = invalid
                remaining.append(residual)
                continue
            }
            let labelField = row.fields.first { $0.key == "raw_label" }
            let approval = labelField?.codeApproval
            let code = approval?.label == label && approval?.unit == unit && labelField?.isConfirmed == true
                && approval?.resolution.kind == .metric
                && approval?.resolution == labelField?.codeResolution ? approval?.resolution : nil
            samples.append(HospitalSample(
                metricKey: code.map { "code.\($0.canonicalCode)" } ?? "lab.\(label)", rawLabel: label, value: value, unit: unit,
                measuredAt: measuredAt,
                refLow: fields["ref_low"].flatMap(Double.init), refHigh: fields["ref_high"].flatMap(Double.init),
                refSourceLabel: shared["hospital"],
                codeConceptId: code?.conceptId))
            rowIds.append(row.id)
        }
        return HospitalProjection(samples: samples, skippedRows: remaining.count, rowIds: rowIds, remainingRows: remaining)
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
                              diagnosisText: shared["diagnosis_text"], adviceText: shared["advice_text"])
    }

    /// 处方卡 → 处方行意图（医嘱文本 = 药品行按序换行；空卡 nil）。
    public static func prescriptionIntent(from card: MatchedCard) -> PrescriptionIntent? {
        let calendar = Calendar(identifier: .gregorian)
        guard card.kind == "prescription", !card.rows.isEmpty,
              card.rows.allSatisfy({ invalidFields(in: card, row: $0, calendar: calendar).isEmpty }) else { return nil }
        let drugs = card.rows.compactMap { dictionary($0.fields)["drug_name"] }.filter { !$0.isEmpty }
        guard !drugs.isEmpty else { return nil }
        let shared = dictionary(card.shared)
        guard let date = shared["prescribed_at"].flatMap({ parseDate($0, calendar: calendar) }) else { return nil }
        return PrescriptionIntent(hospital: shared["hospital"], doctor: shared["doctor"],
                                  adviceText: ([shared["advice_text"]].compactMap { $0 } + drugs).joined(separator: "\n"),
                                  prescribedAt: date)
    }

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
    public static func invalidFields(in card: MatchedCard, row: MatchedCardRow, calendar: Calendar) -> [String] {
        let sharedRequired: Set<String>, rowRequired: Set<String>, sharedAllowed: Set<String>, rowAllowed: Set<String>
        switch card.kind {
        case "metric_sample":
            sharedRequired = ["measured_at"]; rowRequired = ["raw_label", "value", "unit"]
            sharedAllowed = ["measured_at", "hospital"]
            rowAllowed = ["raw_label", "value", "unit", "ref_low", "ref_high", "metric_key"]
        case "encounter":
            sharedRequired = ["date", "kind"]; rowRequired = []
            sharedAllowed = ["date", "kind", "hospital", "department", "doctor", "chief_complaint", "diagnosis_text", "advice_text"]
            rowAllowed = []
        case "prescription":
            sharedRequired = ["prescribed_at"]; rowRequired = ["drug_name"]
            sharedAllowed = ["prescribed_at", "hospital", "doctor", "advice_text"]
            rowAllowed = ["drug_name"]
        default: return ["card_kind"]
        }
        var invalid = Set<String>()
        for (fields, required, allowed) in [(card.shared, sharedRequired, sharedAllowed), (row.fields, rowRequired, rowAllowed)] {
            let values = dictionary(fields)
            invalid.formUnion(required.filter { values[$0] == nil })
            var seen = Set<String>()
            for field in fields where field.grade != .rejected && !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if card.kind == "metric_sample", field.key == "metric_key" { continue }
                if !allowed.contains(field.key) || !field.isConfirmed || !seen.insert(field.key).inserted { invalid.insert(field.key) }
            }
        }
        let shared = dictionary(card.shared), values = dictionary(row.fields)
        let dateKey = card.kind == "metric_sample" ? "measured_at" : (card.kind == "encounter" ? "date" : "prescribed_at")
        if shared[dateKey].flatMap({ parseDate($0, calendar: calendar) }) == nil { invalid.insert(dateKey) }
        if card.kind == "encounter", shared["kind"].flatMap(EncounterKind.init(rawValue:)) == nil { invalid.insert("kind") }
        if card.kind == "metric_sample" {
            for key in ["value", "ref_low", "ref_high"] {
                if let text = values[key], Double(text)?.isFinite != true { invalid.insert(key) }
            }
            if let low = values["ref_low"].flatMap(Double.init), let high = values["ref_high"].flatMap(Double.init), low > high {
                invalid.formUnion(["ref_low", "ref_high"])
            }
        }
        return invalid.sorted()
    }

    public static func isDiscarded(_ row: MatchedCardRow, in card: MatchedCard) -> Bool {
        let fields = card.kind == "encounter" ? card.shared : row.fields.filter { $0.key != "metric_key" }
        return !fields.isEmpty && fields.allSatisfy { $0.grade == .rejected }
    }

    private static func dictionary(_ fields: [FieldDraft]) -> [String: String] {
        var map: [String: String] = [:]
        for field in fields where field.isConfirmed && map[field.key] == nil {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { map[field.key] = value }
        }
        return map
    }
}
