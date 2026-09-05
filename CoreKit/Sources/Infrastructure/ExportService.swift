#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F13 导出管线（§5.7/5.8）：JSON 往返（含版本 envelope）与 CSV 编码。
/// 往返一致性（M1c 一票否决）：导出 → 全新库导入 → 逐字段相等。
public actor ExportService {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 导出 envelope（VersionedData 语义：版本 + 生成时间 + 数据）
    public struct Envelope: Sendable, Codable, Equatable {
        public var schemaVersion: Int
        public var exportedAt: TimeInterval
        public var owner: LocalOwner?
        public var selfProfile: PatientProfile?
        /// 审查修复（BR-001/FR13.5）：家庭成员档案随包往返。缺失（旧包）时
        /// 兼容回落本人档案——但**不**再发生「全库改挂本人名下」的张冠李戴。
        public var members: [PatientProfile]?
        public var consentRecords: [ConsentRecord]
        public var timeline: [TimelineDocumentEntry]
        public var plans: [PlanExport]
        public var appointments: [AppointmentExport]
        public var observations: [ObservationExport]
        public var allergies: [AllergyExport]
        public var encounters: [EncounterExport]
        public var metrics: [MetricExport]
        public var immunizations: [ImmunizationExport]
        public var voiceNotes: [VoiceNoteExport]
        public var healthProblems: [HealthProblemExport]
        public var sensitiveDocIds: Set<UUID>   // 评审 S1：敏感标记随包往返（BR-007/008 链）

        /// FR13.5 恢复后数据校验报告：导入记录计数（供恢复报告展示，不算附件）
        public var totalRecords: Int {
            (owner != nil ? 1 : 0) + (selfProfile != nil ? 1 : 0) + (members?.count ?? 0)
            + consentRecords.count + timeline.count + plans.count + appointments.count
            + observations.count + allergies.count + encounters.count + metrics.count
            + immunizations.count + voiceNotes.count + healthProblems.count
        }

        public struct PlanExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var medicationName: String
            public var spec: String?
            public var schedule: MedicationSchedule
            public var status: PlanStatus
            public var startDate: Date
            public var endDate: Date?
        }
        public struct AppointmentExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var hospital: String
            public var department: String
            public var startsAt: Date
            public var status: String
        }
        public struct ObservationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var kind: String
            public var occurredAt: Date
            public var description: String?
            public var selfMark: String?
        }
        public struct AllergyExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var substance: String
            public var severity: String
            public var occurredAt: Date
        }
        public struct EncounterExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var date: Date
            public var kind: String
            public var diagnosisText: String?
        }
        public struct MetricExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var key: String
            public var value: Double
            public var unit: String
            public var origin: String
            public var measuredAt: Date
            public var excluded: Bool
            public var sourceRef: String?
        }
        public struct ImmunizationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var vaccineName: String
            public var administeredAt: Date
        }
        public struct VoiceNoteExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var body: String
            public var occurredAt: Date
            public var tags: [String]
            public var inTimeline: Bool
        }
        public struct HealthProblemExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var patientId: UUID?
            public var name: String
            public var createdAt: Date
        }
        public init(schemaVersion: Int = 1, exportedAt: TimeInterval = 0,
                    owner: LocalOwner? = nil, selfProfile: PatientProfile? = nil,
                    members: [PatientProfile]? = nil,
                    consentRecords: [ConsentRecord] = [],
                    timeline: [TimelineDocumentEntry] = [], plans: [PlanExport] = [],
                    appointments: [AppointmentExport] = []) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.owner = owner
            self.selfProfile = selfProfile
            self.members = members
            self.consentRecords = consentRecords
            self.timeline = timeline
            self.plans = plans
            self.appointments = appointments
            self.observations = []
            self.allergies = []
            self.encounters = []
            self.metrics = []
            self.immunizations = []
            self.voiceNotes = []
            self.healthProblems = []
            self.sensitiveDocIds = []
        }
    }

    /// 全量导出为 JSON envelope（数据所有权不随付费状态改变——comercial §1）
    public func exportJSON() async throws -> Envelope {
        try await writer.read { db in
            let ownerRow = try Row.fetchOne(db, sql: "SELECT * FROM local_owner LIMIT 1")
            let owner = ownerRow.map { row in
                LocalOwner(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                           displayName: row["display_name"] as String,
                           selfPatientId: (row["self_patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                           createdAt: row["created_at"] as Double)
            }
            let selfProfile = try Row.fetchOne(db, sql: """
                SELECT p.* FROM patient_profile p
                JOIN local_owner o ON o.self_patient_id = p.id
                LIMIT 1
                """).map { row in
                Self.profileRow(row)
            }
            // 审查修复（BR-001/FR13.5）：全部未删除成员档案随包往返——
            // 恢复时各成员数据各归其位，绝不再静默改挂本人名下
            let members = try Row.fetchAll(db, sql: """
                SELECT * FROM patient_profile WHERE deleted_at IS NULL ORDER BY created_at
                """).map(Self.profileRow)
            let consents = try Row.fetchAll(db, sql: "SELECT * FROM consent_record ORDER BY accepted_at").map { row in
                ConsentRecord(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                              key: row["key"] as String,
                              level: row["level"] as Int,
                              version: row["version"] as String,
                              acceptedAt: row["accepted_at"] as Double)
            }
            let timeline = try Row.fetchAll(db, sql: """
                SELECT meta_json FROM document_file WHERE meta_json IS NOT NULL ORDER BY created_at
                """).compactMap { row -> TimelineDocumentEntry? in
                guard let json = row["meta_json"] as String?, let data = json.data(using: .utf8) else { return nil }
                do { return try JSONDecoder().decode(TimelineDocumentEntry.self, from: data) }
                catch { return nil }
            }
            let plans = try Row.fetchAll(db, sql: """
                SELECT p.id, p.patient_id, p.status, p.start_date, p.end_date, p.schedule_json, m.generic_name, m.spec
                FROM medication_plan p JOIN medication m ON m.id = p.medication_id
                """).compactMap { row -> Envelope.PlanExport? in
                guard let json = (row["schedule_json"] as String?)?.data(using: .utf8) else { return nil }
                let schedule: MedicationSchedule
                do { schedule = try JSONDecoder().decode(MedicationSchedule.self, from: json) }
                catch { return nil }   // §7 禁 try?：损坏 schedule_json 跳过该计划
                return Envelope.PlanExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    schedule: schedule,
                    status: PlanStatus(rawValue: row["status"] as String) ?? .active,
                    startDate: Date(timeIntervalSince1970: row["start_date"] as Double),
                    endDate: (row["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) })
            }
            let appointments = try Row.fetchAll(db, sql: "SELECT * FROM appointment").map { row in
                Envelope.AppointmentExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    hospital: row["hospital"] as String,
                    department: (row["department"] as String?) ?? "",
                    startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
                    status: row["status"] as String)
            }
            let observations = try Row.fetchAll(db, sql: "SELECT * FROM observation").map { row in
                Envelope.ObservationExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    kind: row["kind"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    description: row["description"] as String?,
                    selfMark: row["self_mark"] as String?)
            }
            let allergies = try Row.fetchAll(db, sql: "SELECT * FROM allergy_event").map { row in
                Envelope.AllergyExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    substance: row["substance"] as String,
                    severity: row["severity"] as String,
                    occurredAt: Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0))
            }
            let encounters = try Row.fetchAll(db, sql: "SELECT * FROM encounter").map { row in
                Envelope.EncounterExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    date: Date(timeIntervalSince1970: row["date"] as Double),
                    kind: row["kind"] as String,
                    diagnosisText: row["diagnosis_text"] as String?)
            }
            let metrics = try Row.fetchAll(db, sql: "SELECT * FROM metric_sample").map { row in
                Envelope.MetricExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    key: row["metric_key"] as String,
                    value: row["value"] as Double,
                    unit: row["unit"] as String,
                    origin: row["origin"] as String,
                    measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double),
                    excluded: (row["excluded"] as Int?) == 1,
                    sourceRef: row["source_ref"] as String?)
            }
            let immunizations = try Row.fetchAll(db, sql: "SELECT * FROM immunization").map { row in
                Envelope.ImmunizationExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    vaccineName: row["vaccine_name"] as String,
                    administeredAt: Date(timeIntervalSince1970: (row["administered_at"] as Double?) ?? 0))
            }
            let voiceNotes = try Row.fetchAll(db, sql: "SELECT * FROM voice_note").map { row in
                let tags: [String] = (row["tags"] as String?).flatMap { json in
                    guard let data = json.data(using: .utf8) else { return [] }
                    do { return try JSONDecoder().decode([String].self, from: data) }
                    catch { return [] }
                } ?? []
                return Envelope.VoiceNoteExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    body: row["body"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    tags: tags,
                    inTimeline: (row["in_timeline"] as Int?) == 1)
            }
            let healthProblems = try Row.fetchAll(db, sql: "SELECT * FROM health_problem").map { row in
                Envelope.HealthProblemExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)),
                    name: row["name"] as String,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
            }
            let sensitiveIds = try String.fetchAll(db, sql: "SELECT id FROM document_file WHERE is_sensitive = 1")
                .compactMap { UUID(uuidString: $0) }
            var envelope = Envelope(schemaVersion: 1, exportedAt: Date().timeIntervalSince1970,
                                    owner: owner, selfProfile: selfProfile, members: members,
                                    consentRecords: consents,
                                    timeline: timeline, plans: plans, appointments: appointments)
            envelope.sensitiveDocIds = Set(sensitiveIds)
            envelope.observations = observations
            envelope.allergies = allergies
            envelope.encounters = encounters
            envelope.metrics = metrics
            envelope.immunizations = immunizations
            envelope.voiceNotes = voiceNotes
            envelope.healthProblems = healthProblems
            return envelope
        }
    }

    /// 导入（往返一致性的一票否决半场）：把 envelope 写回当前库。
    /// FK 拓扑序：patient_profile → local_owner → consent/document/plan/appointment（ERR#35）
    /// 审查修复（ADR-019）：导入前对身份/档案/同意/时间轴做冲突检测——
    /// 目标库已有同名 id 时抛 .conflict（绝不静默覆盖、绝不静默丢弃），
    /// 由 UI 呈现「目标设备已有数据」而非误导性的校验失败。
    public func importJSON(_ envelope: Envelope) async throws {
        try await writer.write { db in
            // 冲突检测（ADR-019）：不静默覆盖、不静默丢弃——存在即整体拒绝
            func rejectIfExists(table: String, ids: [String], column: String = "id") throws {
                guard !ids.isEmpty else { return }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let existing = try String.fetchAll(db, sql: """
                    SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))
                    """, arguments: StatementArguments(ids))
                guard existing.isEmpty else {
                    throw ExportError.conflict(table: table, id: existing[0])
                }
            }
            let memberProfiles = envelope.members ?? []
            let allProfileIds = ([envelope.selfProfile].compactMap { $0 }.map(\.id)
                                 + memberProfiles.map(\.id)).map(\.uuidString)
            try rejectIfExists(table: "patient_profile", ids: allProfileIds)
            try rejectIfExists(table: "local_owner", ids: [envelope.owner].compactMap { $0 }.map { $0.id.uuidString })
            try rejectIfExists(table: "consent_record", ids: envelope.consentRecords.map { $0.id.uuidString })
            try rejectIfExists(table: "document_file", ids: envelope.timeline.map { $0.id.uuidString })
            try rejectIfExists(table: "medication_plan", ids: envelope.plans.map { $0.id.uuidString })
            try rejectIfExists(table: "appointment", ids: envelope.appointments.map { $0.id.uuidString })
            try rejectIfExists(table: "observation", ids: envelope.observations.map { $0.id.uuidString })
            try rejectIfExists(table: "allergy_event", ids: envelope.allergies.map { $0.id.uuidString })
            try rejectIfExists(table: "encounter", ids: envelope.encounters.map { $0.id.uuidString })
            try rejectIfExists(table: "metric_sample", ids: envelope.metrics.map { $0.id.uuidString })
            try rejectIfExists(table: "immunization", ids: envelope.immunizations.map { $0.id.uuidString })
            try rejectIfExists(table: "voice_note", ids: envelope.voiceNotes.map { $0.id.uuidString })
            try rejectIfExists(table: "health_problem", ids: envelope.healthProblems.map { $0.id.uuidString })

            // FK 拓扑序（ERR#35）：patient_profile 先落——本人档案必须随 envelope
            // 往返（medication/plan/document 的 patient_id 外键目标）
            var profileId = envelope.owner?.selfPatientId ?? envelope.selfProfile?.id
            // 互环 FK 三段式破环（ERR#35 同款）：profile 先落（owner_local_id 暂空）
            // → owner 落（回指 profile）→ 回填 profile.owner_local_id
            if let profile = envelope.selfProfile {
                try db.execute(sql: """
                    INSERT INTO patient_profile
                      (id, owner_local_id, display_name, relation, gender, birth_date, note, created_at, updated_at)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [profile.id.uuidString, profile.displayName,
                                       profile.relation, profile.gender, profile.birthDate,
                                       profile.note, profile.createdAt, profile.updatedAt])
            }
            // 成员档案随包落库（BR-001：各成员数据各归其位）
            for member in memberProfiles {
                try db.execute(sql: """
                    INSERT INTO patient_profile
                      (id, owner_local_id, display_name, relation, gender, birth_date, note, created_at, updated_at)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [member.id.uuidString, member.displayName,
                                       member.relation, member.gender, member.birthDate,
                                       member.note, member.createdAt, member.updatedAt])
            }
            if let owner = envelope.owner {
                try db.execute(sql: """
                    INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [owner.id.uuidString, owner.displayName,
                                     owner.selfPatientId?.uuidString, owner.createdAt])
            }
            if let owner = envelope.owner {
                // 本人 + 全部成员的 owner_local_id 回填
                for profile in memberProfiles + [envelope.selfProfile].compactMap({ $0 }) {
                    try db.execute(sql: "UPDATE patient_profile SET owner_local_id = ? WHERE id = ?",
                                   arguments: [owner.id.uuidString, profile.id.uuidString])
                }
            }
            profileId = profileId ?? envelope.owner?.selfPatientId
            for c in envelope.consentRecords {
                try db.execute(sql: """
                    INSERT INTO consent_record (id, key, level, version, accepted_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [c.id.uuidString, c.key, c.level, c.version, c.acceptedAt])
            }
            for e in envelope.timeline {
                let meta = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO document_file
                      (id, patient_id, doc_type, sha256, mime_type, origin, meta_json, created_at, updated_at)
                    VALUES (?, ?, 'ocr_document', ?, 'application/json', 'scanner', ?, ?, ?)
                    """, arguments: [e.id.uuidString, e.patientId.uuidString, "sha:" + e.id.uuidString,
                                     meta, e.occurredAt, e.occurredAt])
            }
            for p in envelope.plans {
                // 药品行先落（medication_plan.medication_id 外键，ERR#35）
                let planPatient = p.patientId ?? profileId
                let medId = UUID()
                try db.execute(sql: """
                    INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'tablet', ?, ?)
                    """, arguments: [medId.uuidString, planPatient?.uuidString ?? "",
                                       p.medicationName, p.spec,
                                       p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
                let scheduleJSON = String(data: try JSONEncoder().encode(p.schedule), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO medication_plan
                      (id, patient_id, medication_id, status, schedule_json, start_date, end_date, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [p.id.uuidString, planPatient?.uuidString ?? "", medId.uuidString, p.status.rawValue, scheduleJSON,
                                     p.startDate.timeIntervalSince1970, p.endDate?.timeIntervalSince1970,
                                     p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
            }
            for a in envelope.appointments {
                try db.execute(sql: """
                    INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [a.id.uuidString, a.patientId?.uuidString ?? profileId?.uuidString ?? "", a.hospital, a.department,
                                     a.startsAt.timeIntervalSince1970, a.status,
                                     a.startsAt.timeIntervalSince1970, a.startsAt.timeIntervalSince1970])
            }
            for o in envelope.observations {
                try db.execute(sql: """
                    INSERT INTO observation (id, patient_id, kind, occurred_at, description, self_mark, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [o.id.uuidString, o.patientId?.uuidString ?? profileId?.uuidString ?? "", o.kind,
                                     o.occurredAt.timeIntervalSince1970, o.description, o.selfMark,
                                     o.occurredAt.timeIntervalSince1970, o.occurredAt.timeIntervalSince1970])
            }
            for a in envelope.allergies {
                try db.execute(sql: """
                    INSERT INTO allergy_event (id, patient_id, substance, reaction_tags, severity, occurred_at, created_at, updated_at)
                    VALUES (?, ?, ?, '[]', ?, ?, ?, ?)
                    """, arguments: [a.id.uuidString, a.patientId?.uuidString ?? profileId?.uuidString ?? "", a.substance, a.severity,
                                     a.occurredAt.timeIntervalSince1970,
                                     a.occurredAt.timeIntervalSince1970, a.occurredAt.timeIntervalSince1970])
            }
            for e in envelope.encounters {
                try db.execute(sql: """
                    INSERT INTO encounter (id, patient_id, date, kind, diagnosis_text, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.id.uuidString, e.patientId?.uuidString ?? profileId?.uuidString ?? "", e.date.timeIntervalSince1970,
                                     e.kind, e.diagnosisText,
                                     e.date.timeIntervalSince1970, e.date.timeIntervalSince1970])
            }
            for m in envelope.metrics {
                try db.execute(sql: """
                    INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded, source_ref, measured_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [m.id.uuidString, m.patientId?.uuidString ?? profileId?.uuidString ?? "", m.key, m.value, m.unit, m.origin,
                                     m.origin == "hospital" ? 0 : 1, m.excluded ? 1 : 0, m.sourceRef,
                                     m.measuredAt.timeIntervalSince1970, m.measuredAt.timeIntervalSince1970])
            }
            for i in envelope.immunizations {
                try db.execute(sql: """
                    INSERT INTO immunization (id, patient_id, vaccine_name, administered_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [i.id.uuidString, i.patientId?.uuidString ?? profileId?.uuidString ?? "", i.vaccineName,
                                     i.administeredAt.timeIntervalSince1970,
                                     i.administeredAt.timeIntervalSince1970, i.administeredAt.timeIntervalSince1970])
            }
            for v in envelope.voiceNotes {
                let tagsJSON = String(data: (try JSONEncoder().encode(v.tags)), encoding: .utf8) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO voice_note (id, patient_id, body, occurred_at, tags, in_timeline, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [v.id.uuidString, v.patientId?.uuidString ?? profileId?.uuidString ?? "", v.body,
                                     v.occurredAt.timeIntervalSince1970, tagsJSON, v.inTimeline ? 1 : 0,
                                     v.occurredAt.timeIntervalSince1970, v.occurredAt.timeIntervalSince1970])
            }
            // 敏感标记回写（BR-007/008 链必须随往返保持）
            for docId in envelope.sensitiveDocIds {
                try db.execute(sql: "UPDATE document_file SET is_sensitive = 1 WHERE id = ?",
                               arguments: [docId.uuidString])
            }
            for h in envelope.healthProblems {
                try db.execute(sql: """
                    INSERT INTO health_problem (id, patient_id, name, archived, created_at, updated_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    """, arguments: [h.id.uuidString, h.patientId?.uuidString ?? profileId?.uuidString ?? "", h.name,
                                     h.createdAt.timeIntervalSince1970, h.createdAt.timeIntervalSince1970])
            }
        }
    }

    /// 审查修复：ADR-019 冲突显式错误——UI 据此呈现「目标设备已有数据」，
    /// 不再把合法备份误报为「校验失败」。
    public enum ExportError: Error, Sendable, Equatable {
        case conflict(table: String, id: String)
    }

    /// patient_profile 行 → PatientProfile 实体（本人/成员共用一条映射）
    private static func profileRow(_ row: Row) -> PatientProfile {
        PatientProfile(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                       displayName: row["display_name"] as String,
                       relation: row["relation"] as String,
                       gender: row["gender"] as String?,
                       birthDate: row["birth_date"] as String?,
                       note: row["note"] as String?,
                       createdAt: row["created_at"] as Double,
                       updatedAt: row["updated_at"] as Double)
    }

    /// 编码 envelope 为 JSON Data（含 UTF-8）
    public func encode(_ envelope: Envelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }

    /// CSV 导出（配药清单等表格型数据，FR13.3/FR13.8）：复用 Domain CSVWriter
    public func csv(headers: [String], rows: [[String]]) -> Data {
        CSVWriter.encode(headers: headers, rows: rows)
    }
}
#endif
