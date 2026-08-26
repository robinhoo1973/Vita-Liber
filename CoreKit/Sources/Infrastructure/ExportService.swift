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

        public struct PlanExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var medicationName: String
            public var spec: String?
            public var schedule: MedicationSchedule
            public var status: PlanStatus
            public var startDate: Date
            public var endDate: Date?
        }
        public struct AppointmentExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var hospital: String
            public var department: String
            public var startsAt: Date
            public var status: String
        }
        public struct ObservationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var kind: String
            public var occurredAt: Date
            public var description: String?
            public var selfMark: String?
        }
        public struct AllergyExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var substance: String
            public var severity: String
            public var occurredAt: Date
        }
        public struct EncounterExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var date: Date
            public var kind: String
            public var diagnosisText: String?
        }
        public struct MetricExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var key: String
            public var value: Double
            public var unit: String
            public var origin: String
            public var measuredAt: Date
        }
        public struct ImmunizationExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var vaccineName: String
            public var administeredAt: Date
        }
        public struct VoiceNoteExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var body: String
            public var occurredAt: Date
        }
        public struct HealthProblemExport: Sendable, Codable, Equatable {
            public var id: UUID
            public var name: String
            public var createdAt: Date
        }
        public init(schemaVersion: Int = 1, exportedAt: TimeInterval = 0,
                    owner: LocalOwner? = nil, selfProfile: PatientProfile? = nil,
                    consentRecords: [ConsentRecord] = [],
                    timeline: [TimelineDocumentEntry] = [], plans: [PlanExport] = [],
                    appointments: [AppointmentExport] = []) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.owner = owner
            self.selfProfile = selfProfile
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
                PatientProfile(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                               displayName: row["display_name"] as String,
                               relation: row["relation"] as String,
                               gender: row["gender"] as String?,
                               birthDate: row["birth_date"] as String?,
                               note: row["note"] as String?,
                               createdAt: row["created_at"] as Double,
                               updatedAt: row["updated_at"] as Double)
            }
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
                SELECT p.id, p.status, p.start_date, p.end_date, p.schedule_json, m.generic_name, m.spec
                FROM medication_plan p JOIN medication m ON m.id = p.medication_id
                """).compactMap { row -> Envelope.PlanExport? in
                guard let json = (row["schedule_json"] as String?)?.data(using: .utf8) else { return nil }
                let schedule: MedicationSchedule
                do { schedule = try JSONDecoder().decode(MedicationSchedule.self, from: json) }
                catch { return nil }   // §7 禁 try?：损坏 schedule_json 跳过该计划
                return Envelope.PlanExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
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
                    hospital: row["hospital"] as String,
                    department: (row["department"] as String?) ?? "",
                    startsAt: Date(timeIntervalSince1970: row["starts_at"] as Double),
                    status: row["status"] as String)
            }
            let observations = try Row.fetchAll(db, sql: "SELECT * FROM observation").map { row in
                Envelope.ObservationExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    kind: row["kind"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
                    description: row["description"] as String?,
                    selfMark: row["self_mark"] as String?)
            }
            let allergies = try Row.fetchAll(db, sql: "SELECT * FROM allergy_event").map { row in
                Envelope.AllergyExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    substance: row["substance"] as String,
                    severity: row["severity"] as String,
                    occurredAt: Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0))
            }
            let encounters = try Row.fetchAll(db, sql: "SELECT * FROM encounter").map { row in
                Envelope.EncounterExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    date: Date(timeIntervalSince1970: row["date"] as Double),
                    kind: row["kind"] as String,
                    diagnosisText: row["diagnosis_text"] as String?)
            }
            let metrics = try Row.fetchAll(db, sql: "SELECT * FROM metric_sample").map { row in
                Envelope.MetricExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    key: row["metric_key"] as String,
                    value: row["value"] as Double,
                    unit: row["unit"] as String,
                    origin: row["origin"] as String,
                    measuredAt: Date(timeIntervalSince1970: row["measured_at"] as Double))
            }
            let immunizations = try Row.fetchAll(db, sql: "SELECT * FROM immunization").map { row in
                Envelope.ImmunizationExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    vaccineName: row["vaccine_name"] as String,
                    administeredAt: Date(timeIntervalSince1970: (row["administered_at"] as Double?) ?? 0))
            }
            let voiceNotes = try Row.fetchAll(db, sql: "SELECT * FROM voice_note").map { row in
                Envelope.VoiceNoteExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    body: row["body"] as String,
                    occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double))
            }
            let healthProblems = try Row.fetchAll(db, sql: "SELECT * FROM health_problem").map { row in
                Envelope.HealthProblemExport(
                    id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    name: row["name"] as String,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
            }
            var envelope = Envelope(schemaVersion: 1, exportedAt: Date().timeIntervalSince1970,
                                    owner: owner, selfProfile: selfProfile, consentRecords: consents,
                                    timeline: timeline, plans: plans, appointments: appointments)
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
    public func importJSON(_ envelope: Envelope) async throws {
        try await writer.write { db in
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
            if let owner = envelope.owner {
                try db.execute(sql: """
                    INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [owner.id.uuidString, owner.displayName,
                                     owner.selfPatientId?.uuidString, owner.createdAt])
            }
            if let profile = envelope.selfProfile, let owner = envelope.owner {
                try db.execute(sql: "UPDATE patient_profile SET owner_local_id = ? WHERE id = ?",
                               arguments: [owner.id.uuidString, profile.id.uuidString])
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
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: [e.id.uuidString, e.patientId.uuidString, "sha:" + e.id.uuidString,
                                     meta, e.occurredAt, e.occurredAt])
            }
            for p in envelope.plans {
                // 药品行先落（medication_plan.medication_id 外键，ERR#35）
                let medId = UUID()
                try db.execute(sql: """
                    INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'tablet', ?, ?)
                    """, arguments: [medId.uuidString, profileId?.uuidString ?? "",
                                       p.medicationName, p.spec,
                                       p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
                let scheduleJSON = String(data: try JSONEncoder().encode(p.schedule), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO medication_plan
                      (id, patient_id, medication_id, status, schedule_json, start_date, end_date, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [p.id.uuidString, profileId?.uuidString ?? "", medId.uuidString, p.status.rawValue, scheduleJSON,
                                     p.startDate.timeIntervalSince1970, p.endDate?.timeIntervalSince1970,
                                     p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
            }
            for a in envelope.appointments {
                try db.execute(sql: """
                    INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [a.id.uuidString, profileId?.uuidString ?? "", a.hospital, a.department,
                                     a.startsAt.timeIntervalSince1970, a.status,
                                     a.startsAt.timeIntervalSince1970, a.startsAt.timeIntervalSince1970])
            }
            for o in envelope.observations {
                try db.execute(sql: """
                    INSERT INTO observation (id, patient_id, kind, occurred_at, description, self_mark, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [o.id.uuidString, profileId?.uuidString ?? "", o.kind,
                                     o.occurredAt.timeIntervalSince1970, o.description, o.selfMark,
                                     o.occurredAt.timeIntervalSince1970, o.occurredAt.timeIntervalSince1970])
            }
            for a in envelope.allergies {
                try db.execute(sql: """
                    INSERT INTO allergy_event (id, patient_id, substance, reaction_tags, severity, occurred_at, created_at, updated_at)
                    VALUES (?, ?, ?, '[]', ?, ?, ?, ?)
                    """, arguments: [a.id.uuidString, profileId?.uuidString ?? "", a.substance, a.severity,
                                     a.occurredAt.timeIntervalSince1970,
                                     a.occurredAt.timeIntervalSince1970, a.occurredAt.timeIntervalSince1970])
            }
            for e in envelope.encounters {
                try db.execute(sql: """
                    INSERT INTO encounter (id, patient_id, date, kind, diagnosis_text, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.id.uuidString, profileId?.uuidString ?? "", e.date.timeIntervalSince1970,
                                     e.kind, e.diagnosisText,
                                     e.date.timeIntervalSince1970, e.date.timeIntervalSince1970])
            }
            for m in envelope.metrics {
                try db.execute(sql: """
                    INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, measured_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [m.id.uuidString, profileId?.uuidString ?? "", m.key, m.value, m.unit, m.origin,
                                     m.origin == "hospital" ? 0 : 1,
                                     m.measuredAt.timeIntervalSince1970, m.measuredAt.timeIntervalSince1970])
            }
            for i in envelope.immunizations {
                try db.execute(sql: """
                    INSERT INTO immunization (id, patient_id, vaccine_name, administered_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [i.id.uuidString, profileId?.uuidString ?? "", i.vaccineName,
                                     i.administeredAt.timeIntervalSince1970,
                                     i.administeredAt.timeIntervalSince1970, i.administeredAt.timeIntervalSince1970])
            }
            for v in envelope.voiceNotes {
                try db.execute(sql: """
                    INSERT INTO voice_note (id, patient_id, body, occurred_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [v.id.uuidString, profileId?.uuidString ?? "", v.body,
                                     v.occurredAt.timeIntervalSince1970,
                                     v.occurredAt.timeIntervalSince1970, v.occurredAt.timeIntervalSince1970])
            }
            for h in envelope.healthProblems {
                try db.execute(sql: """
                    INSERT INTO health_problem (id, patient_id, name, archived, created_at, updated_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    """, arguments: [h.id.uuidString, profileId?.uuidString ?? "", h.name,
                                     h.createdAt.timeIntervalSince1970, h.createdAt.timeIntervalSince1970])
            }
        }
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
