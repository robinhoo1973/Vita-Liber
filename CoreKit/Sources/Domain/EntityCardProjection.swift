import Foundation

/// FR6.9 V3.61：已确认的实体卡 → 持久化意图（纯 Domain，零 IO）。
/// 纪律：行级必填缺失/非数值行**跳过不阻断**；日期解析失败即不落库（不猜日期）；
/// 编码只在字段携带用户确认的 `codeResolution` 时回填（BR-003/FR25.11）；医学数值零硬编码。
public enum EntityCardProjection {
    public struct HospitalProjection: Sendable, Equatable {
        public var samples: [HospitalSample]
        public var skippedRows: Int
    }

    public struct PrescriptionIntent: Sendable, Equatable {
        public var hospital: String?
        public var doctor: String?
        public var adviceText: String
        public var prescribedAt: Date?
    }

    /// OCR 日期：yyyy-MM-dd / yyyy/M/d / yyyy年M月d日（含「日期：」前缀）→ 当日零点；解析失败 nil。
    public static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{4})\s*[-/年.]\s*(\d{1,2})\s*[-/月.]\s*(\d{1,2})"#),   // try?-ok: 静态字面量，构造不会失败
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let y = Range(match.range(at: 1), in: text), let m = Range(match.range(at: 2), in: text),
              let d = Range(match.range(at: 3), in: text),
              let year = Int(text[y]), let month = Int(text[m]), let day = Int(text[d]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        components.hour = 0; components.minute = 0; components.second = 0
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// 检验卡 → 医院来源样本。无有效日期 → 全部跳过（measured_at 必填，不猜）。
    public static func hospitalSamples(from card: MatchedCard, calendar: Calendar) -> HospitalProjection {
        let shared = dictionary(card.shared)
        guard let measuredAt = shared["measured_at"].flatMap({ parseDate($0, calendar: calendar) }) else {
            return HospitalProjection(samples: [], skippedRows: card.rows.count)
        }
        var samples: [HospitalSample] = []
        var skipped = 0
        for row in card.rows {
            let fields = dictionary(row.fields)
            guard row.missingRequired.isEmpty,
                  let label = fields["raw_label"], !label.isEmpty,
                  let valueText = fields["value"], let value = Double(valueText), value.isFinite,
                  let unit = fields["unit"], !unit.isEmpty else { skipped += 1; continue }
            let code = row.fields.first { $0.key == "raw_label" }?.codeResolution
            samples.append(HospitalSample(
                metricKey: fields["metric_key"] ?? "lab.\(label)", rawLabel: label, value: value, unit: unit,
                measuredAt: measuredAt,
                refLow: fields["ref_low"].flatMap(Double.init), refHigh: fields["ref_high"].flatMap(Double.init),
                refSourceLabel: shared["hospital"],
                codeConceptId: code?.conceptId))
        }
        return HospitalProjection(samples: samples, skippedRows: skipped)
    }

    /// 就诊卡 → 就诊草稿（日期必填；kind 缺省门诊）。
    public static func encounterDraft(from card: MatchedCard, patientId: UUID, calendar: Calendar) -> EncounterDraft? {
        let shared = dictionary(card.shared)
        guard let date = shared["date"].flatMap({ parseDate($0, calendar: calendar) }) else { return nil }
        return EncounterDraft(patientId: patientId, date: date,
                              kind: shared["kind"] ?? EncounterKind.outpatient.rawValue,
                              hospital: shared["hospital"], department: shared["department"],
                              doctor: shared["doctor"], chiefComplaint: shared["chief_complaint"],
                              diagnosisText: shared["diagnosis_text"], adviceText: shared["advice_text"])
    }

    /// 处方卡 → 处方行意图（医嘱文本 = 药品行按序换行；空卡 nil）。
    public static func prescriptionIntent(from card: MatchedCard) -> PrescriptionIntent? {
        let drugs = card.rows.compactMap { dictionary($0.fields)["drug_name"] }.filter { !$0.isEmpty }
        guard !drugs.isEmpty else { return nil }
        let shared = dictionary(card.shared)
        return PrescriptionIntent(hospital: shared["hospital"], doctor: shared["doctor"],
                                  adviceText: drugs.joined(separator: "\n"),
                                  prescribedAt: shared["prescribed_at"].flatMap { parseDate($0, calendar: Calendar(identifier: .gregorian)) })
    }

    /// 卡内全部字段 → 确认卡字段（共享先、逐行后；显示标签由 App 层 L10n 注入）。
    public static func candidateFields(from card: MatchedCard, labelFor: (String) -> String) -> [CandidateField] {
        card.allFields.map { draft in
            CandidateField(key: draft.key, displayLabel: labelFor(draft.key), rawText: draft.rawText ?? draft.value,
                           confidence: draft.confidence, value: draft.value, codeResolution: draft.codeResolution)
        }
    }

    private static func dictionary(_ fields: [FieldDraft]) -> [String: String] {
        var map: [String: String] = [:]
        for field in fields where !field.value.isEmpty && map[field.key] == nil { map[field.key] = field.value }
        return map
    }
}
