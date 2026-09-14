import Foundation

/// 卡内选择只在用户保存卡后成为关系。none不能与尚未选择合并，避免后续偷偷回填。
/// v27（子项目 J · recognition-remediation-design §0.4 改判）：识别出的子卡永远有父——无可挂接主卡时以 `.newHub` 携带
/// D 级主卡草稿，与子卡同流确认、同事务落库；`.existingHub` 表达已存在的非就诊主卡（体检）。
public enum EncounterAssociation: Codable, Sendable, Equatable {
    case unselected
    case none
    case existing(UUID)
    case suggested(UUID, evidence: String)
    /// v27（§0.4 改判）：无可挂接主卡 → 与子卡同流确认、同事务新建的主卡草稿（D 级）。
    case newHub(HubDraft)
    /// v27：已存在的非就诊主卡（体检）；就诊沿用 `.existing`（`.existingHub(.encounter/.hospitalization, id)` 与之同义）。
    case existingHub(RecordHub, UUID)

    /// 就诊 id（体检枢纽 / 草稿 → nil）。
    public var encounterID: UUID? {
        switch self {
        case .existing(let id), .suggested(let id, _): return id
        case .existingHub(.encounter, let id), .existingHub(.hospitalization, let id): return id
        default: return nil
        }
    }

    /// 已存在主卡的 (枢纽, id)；草稿尚无 id → nil。
    public var hubID: (hub: RecordHub, id: UUID)? {
        switch self {
        case .existing(let id), .suggested(let id, _): return (.encounter, id)
        case .existingHub(let hub, let id): return (hub, id)
        default: return nil
        }
    }
}

/// 主卡草稿（D 级）：字段键 = 主卡卡类模板键（encounter: date/kind/hospital/department/doctor/diagnosis_text；
/// health_exam: exam_date/org_name/exam_no）。全部字段须 `FieldDraft.confirm()` 后方可转实体（BR-003）。
public struct HubDraft: Codable, Sendable, Equatable {
    public var hub: RecordHub
    public var fields: [FieldDraft]
    /// = `EncounterResolver.evidenceKey(for: 子卡)`；证据字段被编辑即失效（与 `.suggested` 同纪律）。
    public var evidence: String

    public init(hub: RecordHub, fields: [FieldDraft], evidence: String) { self.hub = hub; self.fields = fields; self.evidence = evidence }

    /// 该枢纽草稿的日期键（就诊 `date` / 体检 `exam_date`）——缺席时确认页显示补填按钮。
    public var dateKey: String {
        switch hub {
        case .encounter, .hospitalization: return "date"
        case .healthExam: return "exam_date"
        }
    }

    /// 草稿是否已带非空日期字段（不校验可解析性）。
    public var hasDate: Bool {
        fields.contains { $0.key == dateKey && $0.grade != .rejected && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 可转实体：全部字段已确认 ∧ 日期可解析 ∧（就诊）kind 为 `EncounterKind` 枚举——与 store 校验同口径（J4 `canSave` 复用）。
    public func isComplete(calendar: Calendar) -> Bool {
        guard !fields.isEmpty, fields.allSatisfy(\.isConfirmed) else { return false }
        let values = Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard values[dateKey].flatMap({ EntityCardProjection.parseDate($0, calendar: calendar) }) != nil else { return false }
        if hub != .healthExam, values["kind"].flatMap(EncounterKind.init(rawValue:)) == nil { return false }
        return true
    }
}

/// §0.4 改判：只搬子卡共享字段**原文**为主卡草稿，不推断；`kind` 只由文档类型键派生（`DocumentTypeKey.encounterKindHint`）。
public enum ParentCardDraftRules {
    /// 归就诊枢纽的子卡类（immunization / medication 为 FR4.6 预防保健 / 药箱档案，例外不派生；hospitalization 自建就诊）。
    public static let encounterChildren: Set<String> = ["prescription", "claim_item", "diagnosis", "exam_report", "metric_sample", "surgery", "treatment_record"]
    /// 恒归体检枢纽的子卡类。
    public static let healthExamChildren: Set<String> = ["clinical_conclusion"]
    /// 体检文档上改归体检枢纽的检验 / 检查卡。
    static let checkupRedirected: Set<String> = ["metric_sample", "exam_report"]
    /// 子卡共享面日期键候选（首个已有值胜出）。
    static let dateKeys = ["date", "exam_date", "prescribed_at", "measured_at", "collected_at", "reported_at", "exam_at", "diagnosed_at", "surgery_at", "treated_at"]

    /// 子卡应挂的枢纽：结论卡 → 体检；体检文档上的检验 / 检查 → 体检；其余就诊族 → 就诊；无枢纽卡类 / 主卡自身 → nil。
    public static func hub(for child: MatchedCard, documentTypeKey: String?) -> RecordHub? {
        if healthExamChildren.contains(child.kind) { return .healthExam }
        if documentTypeKey == DocumentTypeKey.checkupReport.rawValue, checkupRedirected.contains(child.kind) { return .healthExam }
        return encounterChildren.contains(child.kind) ? .encounter : nil
    }

    /// 子卡 → 主卡草稿：只搬映射表内的共享字段原文（D 级、未确认）；无日期时仍返回草稿（确认页要求补填），无枢纽 → nil。
    public static func deriveHub(from child: MatchedCard, documentTypeKey: String?) -> HubDraft? {
        guard let hub = hub(for: child, documentTypeKey: documentTypeKey) else { return nil }
        func shared(_ keys: [String]) -> FieldDraft? {
            for key in keys {
                if let field = child.shared.first(where: { $0.key == key && $0.grade != .rejected && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return field
                }
            }
            return nil
        }
        var fields: [FieldDraft] = []
        func carry(_ target: String, from keys: [String]) {
            guard let source = shared(keys) else { return }
            fields.append(FieldDraft(key: target, value: source.value, confidence: source.confidence, rawText: source.rawText,
                                     source: source.source, grade: .ocrUnconfirmed, sourceLineIndex: source.sourceLineIndex))
        }
        switch hub {
        case .encounter:
            carry("date", from: dateKeys)
            carry("hospital", from: ["hospital", "merchant", "provider"])
            carry("department", from: ["department"])
            carry("doctor", from: ["doctor"])
            carry("diagnosis_text", from: ["clinical_diagnosis", "diagnosis_text"])
            let kind = documentTypeKey.flatMap(DocumentTypeKey.init(rawValue:))?.encounterKindHint ?? .outpatient
            fields.append(FieldDraft(key: "kind", value: kind.rawValue, confidence: 1, source: .heuristic, grade: .ocrUnconfirmed))
        case .healthExam:
            carry("exam_date", from: dateKeys)
            carry("org_name", from: ["org_name", "hospital"])
            carry("exam_no", from: ["exam_no", "report_no"])
        case .hospitalization:
            return nil   // 住院期由住院卡自身建就诊（saveHospitalization），不经草稿
        }
        return HubDraft(hub: hub, fields: fields, evidence: EncounterResolver.evidenceKey(for: child))
    }

    /// 草稿 → 就诊：全部字段已确认且日期可解析、kind 为枚举；否则 nil（store 抛 invalidCard；确认页以 missingRequired 要求补填）。
    public static func encounterDraft(from draft: HubDraft, patientId: UUID, calendar: Calendar) -> EncounterDraft? {
        guard draft.hub == .encounter, draft.isComplete(calendar: calendar) else { return nil }
        let values = Dictionary(draft.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let date = values["date"].flatMap({ EntityCardProjection.parseDate($0, calendar: calendar) }),
              let kind = values["kind"], EncounterKind(rawValue: kind) != nil else { return nil }
        var encounter = EncounterDraft(patientId: patientId, date: date, kind: kind)
        encounter.hospital = values["hospital"]; encounter.department = values["department"]; encounter.doctor = values["doctor"]
        encounter.diagnosisText = values["diagnosis_text"]
        return encounter
    }

    /// 草稿 → 体检表头（`documentFileId`/时间戳由 store 填；`confirmed = true` = 用户已逐字段确认）；否则 nil。
    public static func healthExamDraft(from draft: HubDraft, patientId: UUID, calendar: Calendar) -> HealthExam? {
        guard draft.hub == .healthExam, draft.isComplete(calendar: calendar) else { return nil }
        let values = Dictionary(draft.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let date = values["exam_date"].flatMap({ EntityCardProjection.parseDate($0, calendar: calendar) }) else { return nil }
        return HealthExam(patientId: patientId, orgName: values["org_name"], examNo: values["exam_no"], examDate: date,
                          source: .ocr, confirmed: true, createdAt: FactPlaceholder.unassignedDate, updatedAt: FactPlaceholder.unassignedDate)
    }

    /// 关联区默认裁决（J4 `EncounterAssociationSection.load()` 单入口）：就诊族子卡先跑 `EncounterResolver.suggest`
    /// （±3 日同医院 → `.suggested` 证据化预选优先），无命中 → `.newHub(草稿)`；体检枢纽不走就诊解析器；无枢纽卡类 → `.unselected`。
    public static func association(for child: MatchedCard, documentTypeKey: String?, patientId: UUID,
                                   candidates: [EncounterResolver.Candidate], calendar: Calendar = .current) -> EncounterAssociation {
        guard let hub = hub(for: child, documentTypeKey: documentTypeKey) else { return .unselected }
        if hub == .encounter {
            let context = EncounterResolver.context(for: child, calendar: calendar)
            if let id = EncounterResolver.suggest(date: context.date, hospital: context.hospital, doctor: context.doctor,
                                                  patientId: patientId, candidates: candidates, calendar: calendar) {
                return .suggested(id, evidence: EncounterResolver.evidenceKey(for: child))
            }
        }
        guard let draft = deriveHub(from: child, documentTypeKey: documentTypeKey) else { return .unselected }
        return .newHub(draft)
    }
}

public enum EncounterResolver {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let patientId: UUID
        public let date: Date
        public let hospital: String?
        public let doctor: String?
        public init(id: UUID, patientId: UUID, date: Date, hospital: String?, doctor: String?) {
            self.id = id; self.patientId = patientId; self.date = date; self.hospital = hospital; self.doctor = doctor
        }
    }

    /// 证据字段键：机构 / 医生 / 各卡类共享日期——编辑其一即令 `.suggested` / `.newHub` 失效。
    public static let evidenceKeys: Set<String> = ["hospital", "merchant", "provider", "org_name", "doctor",
                                                   "date", "measured_at", "prescribed_at", "administered_at",
                                                   "exam_date", "exam_at", "diagnosed_at", "surgery_at", "treated_at"]

    public static func suggest(date: Date?, hospital: String?, doctor: String?, patientId: UUID,
                               candidates: [Candidate], calendar: Calendar = .current) -> UUID? {
        guard let date, date.timeIntervalSince1970.isFinite, let hospital, !normalize(hospital).isEmpty else { return nil }
        let scored = candidates.compactMap { candidate -> (UUID, Int)? in
            guard candidate.patientId == patientId,
                  let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: candidate.date)).day,
                  abs(days) <= 3, let name = candidate.hospital else { return nil }
            let similarity = hospitalScore(hospital, name)
            guard similarity > 0 else { return nil }
            let doctorMatch = doctor.map { !normalize($0).isEmpty && normalize($0) == normalize(candidate.doctor ?? "") } ?? false
            return (candidate.id, similarity + (doctorMatch ? 2 : 0) + 3 - abs(days))
        }
        guard let best = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == best }
        return winners.count == 1 ? winners[0].0 : nil
    }

    public static func evidenceKey(for card: MatchedCard) -> String {
        card.shared.filter { evidenceKeys.contains($0.key) }
            .map { $0.key + "=" + $0.value }.sorted().joined(separator: "\n")
    }

    public static func context(for card: MatchedCard, calendar: Calendar = .current) -> (date: Date?, hospital: String?, doctor: String?) {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let field = card.shared.first(where: { $0.key == key && $0.grade != .rejected }) { return field.value }
            }
            return nil
        }
        return (value(ParentCardDraftRules.dateKeys).flatMap { EntityCardProjection.parseDate($0, calendar: calendar) },
                value(["hospital", "merchant", "provider", "org_name"]), value(["doctor"]))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans"))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    private static func hospitalScore(_ a: String, _ b: String) -> Int {
        let a = normalize(a), b = normalize(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 10 }
        let short = a.count <= b.count ? a : b, long = a.count <= b.count ? b : a
        // 弱相似仅作可更改预选；不删除“医院”等词去匹配所有机构。
        return short.count >= 4 && long.contains(short) && Double(short.count) / Double(long.count) >= 0.6 ? 6 : 0
    }
}
