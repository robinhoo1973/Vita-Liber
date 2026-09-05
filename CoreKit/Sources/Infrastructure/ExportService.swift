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
                SELECT * FROM patient_profile
                WHERE deleted_at IS NULL
                  AND id != COALESCE((SELECT self_patient_id FROM local_owner LIMIT 1), '')
                ORDER BY created_at
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

    // MARK: - ADR-019 冲突预览与逐项裁决（keep/adopt/coexist）

    /// 冲突条目（同一主键在目标库与备份中同时存在）。
    public struct ConflictItem: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var table: String          // 表名（UI 映射为可读类别）
        public var backupTitle: String?   // 备份侧摘要
        public var existingTitle: String? // 目标库摘要
        public init(id: UUID, table: String, backupTitle: String?, existingTitle: String?) {
            self.id = id; self.table = table
            self.backupTitle = backupTitle; self.existingTitle = existingTitle
        }
    }

    /// 逐项裁决（ADR-019：保留本机 / 采用备份 / 并存——绝不静默覆盖或丢弃）。
    public enum ConflictResolution: String, Sendable, Equatable {
        case keep      // 保留本机，跳过备份行
        case adopt     // 采用备份，覆盖本机行（用户显式选择）
        case coexist   // 并存：备份行以新 id 落库，子行外键随映射重写
    }

    /// 冲突预览：备份与目标库的同名主键清单 + 双方摘要（UI 逐项呈现）。
    public func conflictReport(_ envelope: Envelope) async throws -> [ConflictItem] {
        try await writer.read { db in
            func conflictIds(table: String, ids: [String], column: String = "id") throws -> [String] {
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                return try String.fetchAll(db, sql: """
                    SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))
                    """, arguments: StatementArguments(ids))
            }
            let memberProfiles = envelope.members ?? []
            let profileIds = ([envelope.selfProfile].compactMap { $0 }.map(\.id)
                              + memberProfiles.map(\.id)).map(\.uuidString)
            var items: [ConflictItem] = []
            func add(_ table: String, ids: [String],
                     backupTitle: (String) -> String?, existingTitle: (String) -> String?) throws {
                for id in try conflictIds(table: table, ids: ids) {
                    let uid = UUID(uuidString: id) ?? UUID()
                    items.append(ConflictItem(id: uid, table: table,
                                              backupTitle: backupTitle(id),
                                              existingTitle: existingTitle(id)))
                }
            }
            let profileById = { (id: String) in
                memberProfiles.first { $0.id.uuidString == id }?.displayName
                    ?? (envelope.selfProfile?.id.uuidString == id ? envelope.selfProfile?.displayName : nil)
            }
            func existingTitle(_ table: String, _ id: String, _ column: String = "display_name") -> String? {
                (try? String.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE id = ?", arguments: [id])) ?? nil   // try?-ok: 摘要列缺失即 nil（纯展示）
            }
            try add("patient_profile", ids: profileIds,
                    backupTitle: { profileById($0) },
                    existingTitle: { existingTitle("patient_profile", $0) })
            try add("local_owner", ids: [envelope.owner].compactMap { $0 }.map { $0.id.uuidString },
                    backupTitle: { _ in envelope.owner?.displayName },
                    existingTitle: { existingTitle("local_owner", $0) })
            try add("consent_record", ids: envelope.consentRecords.map { $0.id.uuidString },
                    backupTitle: { id in envelope.consentRecords.first { $0.id.uuidString == id }?.key },
                    existingTitle: { existingTitle("consent_record", $0, "key") })
            try add("document_file", ids: envelope.timeline.map { $0.id.uuidString },
                    backupTitle: { id in envelope.timeline.first { $0.id.uuidString == id }?.title },
                    existingTitle: { existingTitle("document_file", $0, "title") })
            try add("medication_plan", ids: envelope.plans.map { $0.id.uuidString },
                    backupTitle: { id in envelope.plans.first { $0.id.uuidString == id }?.medicationName },
                    existingTitle: { _ in nil })
            try add("appointment", ids: envelope.appointments.map { $0.id.uuidString },
                    backupTitle: { id in envelope.appointments.first { $0.id.uuidString == id }?.hospital },
                    existingTitle: { existingTitle("appointment", $0, "hospital") })
            try add("observation", ids: envelope.observations.map { $0.id.uuidString },
                    backupTitle: { id in envelope.observations.first { $0.id.uuidString == id }?.kind },
                    existingTitle: { existingTitle("observation", $0, "kind") })
            try add("allergy_event", ids: envelope.allergies.map { $0.id.uuidString },
                    backupTitle: { id in envelope.allergies.first { $0.id.uuidString == id }?.substance },
                    existingTitle: { existingTitle("allergy_event", $0, "substance") })
            try add("encounter", ids: envelope.encounters.map { $0.id.uuidString },
                    backupTitle: { id in envelope.encounters.first { $0.id.uuidString == id }?.kind },
                    existingTitle: { existingTitle("encounter", $0, "kind") })
            try add("metric_sample", ids: envelope.metrics.map { $0.id.uuidString },
                    backupTitle: { id in envelope.metrics.first { $0.id.uuidString == id }?.key },
                    existingTitle: { existingTitle("metric_sample", $0, "metric_key") })
            try add("immunization", ids: envelope.immunizations.map { $0.id.uuidString },
                    backupTitle: { id in envelope.immunizations.first { $0.id.uuidString == id }?.vaccineName },
                    existingTitle: { existingTitle("immunization", $0, "vaccine_name") })
            try add("voice_note", ids: envelope.voiceNotes.map { $0.id.uuidString },
                    backupTitle: { id in envelope.voiceNotes.first { $0.id.uuidString == id }?.body },
                    existingTitle: { existingTitle("voice_note", $0, "body") })
            try add("health_problem", ids: envelope.healthProblems.map { $0.id.uuidString },
                    backupTitle: { id in envelope.healthProblems.first { $0.id.uuidString == id }?.name },
                    existingTitle: { existingTitle("health_problem", $0, "name") })
            return items
        }
    }

    /// 导入（往返一致性的一票否决半场）：把 envelope 写回当前库。
    /// FK 拓扑序：patient_profile → local_owner → consent/document/plan/appointment（ERR#35）
    /// ADR-019：冲突项必须有逐项裁决（keep/adopt/coexist）；未裁决的冲突
    /// 抛 .conflict（绝不静默覆盖、绝不静默丢弃）。
    public func importJSON(_ envelope: Envelope,
                           resolutions: [UUID: ConflictResolution] = [:]) async throws {
        try await writer.write { db in
            // 冲突检测（ADR-019）：不静默覆盖、不静默丢弃——存在即需裁决
            func conflictingIds(table: String, ids: [String], column: String = "id") throws -> Set<String> {
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                return Set(try String.fetchAll(db, sql: """
                    SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))
                    """, arguments: StatementArguments(ids)))
            }
            func resolution(_ id: UUID) -> ConflictResolution {
                resolutions[id] ?? .keep
            }
            // 裁决缺失的冲突行 → 抛错（UI 必须先把 preview 呈现给用户——
            // 缺省不得静默按 keep 处理，否则「未裁决即恢复」退化为静默丢弃）
            func rejectUnresolved(_ table: String, _ ids: Set<String>, allowResolutions: [ConflictResolution]) throws {
                for id in ids {
                    guard let uid = UUID(uuidString: id) else { continue }
                    guard let chosen = resolutions[uid], allowResolutions.contains(chosen) else {
                        throw ExportError.conflict(table: table, id: id)
                    }
                }
            }
            let memberProfiles = envelope.members ?? []
            let allProfileIds = ([envelope.selfProfile].compactMap { $0 }.map(\.id)
                                 + memberProfiles.map(\.id)).map(\.uuidString)

            // 身份行（keep/adopt；coexist 也允许——见 idMap 外键重写）
            let profileConflicts = try conflictingIds(table: "patient_profile", ids: allProfileIds)
            try rejectUnresolved("patient_profile", profileConflicts,
                                 allowResolutions: [.keep, .adopt, .coexist])
            let ownerConflicts = try conflictingIds(
                table: "local_owner", ids: [envelope.owner].compactMap { $0 }.map { $0.id.uuidString })
            try rejectUnresolved("local_owner", ownerConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let consentConflicts = try conflictingIds(table: "consent_record",
                                                      ids: envelope.consentRecords.map { $0.id.uuidString })
            try rejectUnresolved("consent_record", consentConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let timelineConflicts = try conflictingIds(table: "document_file",
                                                       ids: envelope.timeline.map { $0.id.uuidString })
            try rejectUnresolved("document_file", timelineConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let planConflicts = try conflictingIds(table: "medication_plan",
                                                   ids: envelope.plans.map { $0.id.uuidString })
            try rejectUnresolved("medication_plan", planConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let aptConflicts = try conflictingIds(table: "appointment",
                                                  ids: envelope.appointments.map { $0.id.uuidString })
            try rejectUnresolved("appointment", aptConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let obsConflicts = try conflictingIds(table: "observation",
                                                  ids: envelope.observations.map { $0.id.uuidString })
            try rejectUnresolved("observation", obsConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let allergyConflicts = try conflictingIds(table: "allergy_event",
                                                      ids: envelope.allergies.map { $0.id.uuidString })
            try rejectUnresolved("allergy_event", allergyConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let encConflicts = try conflictingIds(table: "encounter",
                                                  ids: envelope.encounters.map { $0.id.uuidString })
            try rejectUnresolved("encounter", encConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let metricConflicts = try conflictingIds(table: "metric_sample",
                                                     ids: envelope.metrics.map { $0.id.uuidString })
            try rejectUnresolved("metric_sample", metricConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let immConflicts = try conflictingIds(table: "immunization",
                                                  ids: envelope.immunizations.map { $0.id.uuidString })
            try rejectUnresolved("immunization", immConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let noteConflicts = try conflictingIds(table: "voice_note",
                                                   ids: envelope.voiceNotes.map { $0.id.uuidString })
            try rejectUnresolved("voice_note", noteConflicts, allowResolutions: [.keep, .adopt, .coexist])
            let problemConflicts = try conflictingIds(table: "health_problem",
                                                      ids: envelope.healthProblems.map { $0.id.uuidString })
            try rejectUnresolved("health_problem", problemConflicts, allowResolutions: [.keep, .adopt, .coexist])

            // coexist 的 id 重写映射：备份行以新 id 落库，子行外键随映射重写
            var idMap: [UUID: UUID] = [:]
            func remap(_ id: UUID?) -> UUID? {
                guard let id else { return nil }
                return idMap[id] ?? id
            }
            for id in profileConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in ownerConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in consentConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in timelineConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in planConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in aptConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in obsConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in allergyConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in encConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in metricConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in immConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in noteConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }
            for id in problemConflicts {
                guard let uid = UUID(uuidString: id), resolution(uid) == .coexist else { continue }
                idMap[uid] = UUID()
            }

            // FK 拓扑序（ERR#35）：patient_profile 先落——本人档案必须随 envelope
            // 往返（medication/plan/document 的 patient_id 外键目标）
            var profileId = envelope.owner?.selfPatientId ?? envelope.selfProfile?.id
            func putProfile(_ profile: PatientProfile) throws {
                let targetId = remap(profile.id) ?? profile.id
                if let existing = profile.id, profileConflicts.contains(existing.uuidString) {
                    switch resolution(existing) {
                    case .keep:
                        return
                    case .adopt:
                        try db.execute(sql: """
                            UPDATE patient_profile SET display_name = ?, relation = ?, gender = ?,
                              birth_date = ?, note = ?, created_at = ?, updated_at = ? WHERE id = ?
                            """, arguments: [profile.displayName, profile.relation, profile.gender,
                                             profile.birthDate, profile.note, profile.createdAt,
                                             profile.updatedAt, existing.uuidString])
                        return
                    case .coexist:
                        break   // 落到下方 INSERT（新 id）
                    }
                }
                try db.execute(sql: """
                    INSERT INTO patient_profile
                      (id, owner_local_id, display_name, relation, gender, birth_date, note, created_at, updated_at)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [targetId.uuidString, profile.displayName,
                                       profile.relation, profile.gender, profile.birthDate,
                                       profile.note, profile.createdAt, profile.updatedAt])
            }
            if let profile = envelope.selfProfile {
                try putProfile(profile)
            }
            // 成员档案随包落库（BR-001：各成员数据各归其位）。
            // 审查修复：members 含本人（旧包/旧导出）时跳过——本人档案已先落，
            // 重复 INSERT 触发主键冲突导致整包恢复失败
            for member in memberProfiles where member.id != envelope.selfProfile?.id {
                try putProfile(member)
            }
            // 互环 FK 三段式破环（ERR#35 同款）：owner 落（回指 profile）→ 回填 owner_local_id
            if let owner = envelope.owner {
                let targetOwnerId = remap(owner.id) ?? owner.id
                let selfPatientId = remap(owner.selfPatientId) ?? owner.selfPatientId
                if let ownerId = owner.id, ownerConflicts.contains(ownerId.uuidString) {
                    switch resolution(ownerId) {
                    case .keep:
                        break
                    case .adopt:
                        try db.execute(sql: """
                            UPDATE local_owner SET display_name = ?, self_patient_id = ?, created_at = ? WHERE id = ?
                            """, arguments: [owner.displayName, selfPatientId?.uuidString,
                                             owner.createdAt, ownerId.uuidString])
                    case .coexist:
                        try db.execute(sql: """
                            INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [targetOwnerId.uuidString, owner.displayName,
                                             selfPatientId?.uuidString, owner.createdAt])
                    }
                } else {
                    try db.execute(sql: """
                        INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [targetOwnerId.uuidString, owner.displayName,
                                         selfPatientId?.uuidString, owner.createdAt])
                }
                // 本人 + 全部成员的 owner_local_id 回填（coexist 的新 id 同样回填）
                for profile in memberProfiles + [envelope.selfProfile].compactMap({ $0 }) {
                    try db.execute(sql: "UPDATE patient_profile SET owner_local_id = ? WHERE id = ?",
                                   arguments: [targetOwnerId.uuidString,
                                               (remap(profile.id) ?? profile.id).uuidString])
                }
            }
            profileId = remap(envelope.owner?.selfPatientId) ?? profileId
            for c in envelope.consentRecords {
                if consentConflicts.contains(c.id.uuidString) {
                    switch resolution(c.id) {
                    case .keep:
                        continue
                    case .adopt:
                        try db.execute(sql: """
                            UPDATE consent_record SET key = ?, level = ?, version = ?, accepted_at = ? WHERE id = ?
                            """, arguments: [c.key, c.level, c.version, c.acceptedAt, c.id.uuidString])
                        continue
                    case .coexist:
                        break
                    }
                }
                try db.execute(sql: """
                    INSERT INTO consent_record (id, key, level, version, accepted_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [(remap(c.id) ?? c.id).uuidString, c.key, c.level, c.version, c.acceptedAt])
            }
            for e in envelope.timeline {
                if timelineConflicts.contains(e.id.uuidString) {
                    switch resolution(e.id) {
                    case .keep:
                        continue
                    case .adopt:
                        let meta = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? "{}"
                        try db.execute(sql: """
                            UPDATE document_file SET patient_id = ?, meta_json = ?, title = ?, created_at = ?, updated_at = ?
                            WHERE id = ?
                            """, arguments: [(remap(e.patientId) ?? e.patientId).uuidString, meta, e.title,
                                             e.occurredAt, e.occurredAt, e.id.uuidString])
                        continue
                    case .coexist:
                        break
                    }
                }
                let meta = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? "{}"
                let targetId = remap(e.id) ?? e.id
                try db.execute(sql: """
                    INSERT INTO document_file
                      (id, patient_id, doc_type, sha256, mime_type, origin, meta_json, created_at, updated_at)
                    VALUES (?, ?, 'ocr_document', ?, 'application/json', 'scanner', ?, ?, ?)
                    """, arguments: [targetId.uuidString, (remap(e.patientId) ?? e.patientId).uuidString,
                                     "sha:" + targetId.uuidString,
                                     meta, e.occurredAt, e.occurredAt])
            }
            for p in envelope.plans {
                if planConflicts.contains(p.id.uuidString) {
                    switch resolution(p.id) {
                    case .keep:
                        continue
                    case .adopt:
                        let scheduleJSON = String(data: try JSONEncoder().encode(p.schedule), encoding: .utf8) ?? "{}"
                        try db.execute(sql: """
                            UPDATE medication_plan SET status = ?, schedule_json = ?, start_date = ?, end_date = ?
                            WHERE id = ?
                            """, arguments: [p.status.rawValue, scheduleJSON,
                                             p.startDate.timeIntervalSince1970,
                                             p.endDate?.timeIntervalSince1970, p.id.uuidString])
                        continue
                    case .coexist:
                        break
                    }
                }
                // 药品行先落（medication_plan.medication_id 外键，ERR#35）
                let planPatient = remap(p.patientId) ?? p.patientId ?? profileId
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
                    """, arguments: [(remap(p.id) ?? p.id).uuidString, planPatient?.uuidString ?? "", medId.uuidString, p.status.rawValue, scheduleJSON,
                                     p.startDate.timeIntervalSince1970, p.endDate?.timeIntervalSince1970,
                                     p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
            }
            func adoptOrSkip(_ conflicts: Set<String>, _ id: UUID,
                                adopt: () throws -> Void) throws -> Bool {
                guard conflicts.contains(id.uuidString) else { return false }
                switch resolution(id) {
                case .keep:
                    return true
                case .adopt:
                    try adopt()
                    return true
                case .coexist:
                    return false
                }
            }
            for a in envelope.appointments {
                if try adoptOrSkip(aptConflicts, a.id, adopt: {
                    try db.execute(sql: """
                        UPDATE appointment SET patient_id = ?, hospital = ?, department = ?, starts_at = ?, status = ?
                        WHERE id = ?
                        """, arguments: [(remap(a.patientId) ?? a.patientId)?.uuidString ?? "", a.hospital,
                                         a.department, a.startsAt.timeIntervalSince1970, a.status, a.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(a.id) ?? a.id).uuidString, (remap(a.patientId) ?? a.patientId)?.uuidString ?? profileId?.uuidString ?? "", a.hospital, a.department,
                                     a.startsAt.timeIntervalSince1970, a.status,
                                     a.startsAt.timeIntervalSince1970, a.startsAt.timeIntervalSince1970])
            }
            for o in envelope.observations {
                if try adoptOrSkip(obsConflicts, o.id, adopt: {
                    try db.execute(sql: """
                        UPDATE observation SET patient_id = ?, kind = ?, occurred_at = ?, description = ?, self_mark = ?
                        WHERE id = ?
                        """, arguments: [(remap(o.patientId) ?? o.patientId)?.uuidString ?? "", o.kind,
                                         o.occurredAt.timeIntervalSince1970, o.description, o.selfMark, o.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO observation (id, patient_id, kind, occurred_at, description, self_mark, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(o.id) ?? o.id).uuidString, (remap(o.patientId) ?? o.patientId)?.uuidString ?? profileId?.uuidString ?? "", o.kind,
                                     o.occurredAt.timeIntervalSince1970, o.description, o.selfMark,
                                     o.occurredAt.timeIntervalSince1970, o.occurredAt.timeIntervalSince1970])
            }
            for a in envelope.allergies {
                if try adoptOrSkip(allergyConflicts, a.id, adopt: {
                    try db.execute(sql: """
                        UPDATE allergy_event SET patient_id = ?, substance = ?, severity = ?, occurred_at = ?
                        WHERE id = ?
                        """, arguments: [(remap(a.patientId) ?? a.patientId)?.uuidString ?? "", a.substance,
                                         a.severity, a.occurredAt.timeIntervalSince1970, a.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO allergy_event (id, patient_id, substance, reaction_tags, severity, occurred_at, created_at, updated_at)
                    VALUES (?, ?, ?, '[]', ?, ?, ?, ?)
                    """, arguments: [(remap(a.id) ?? a.id).uuidString, (remap(a.patientId) ?? a.patientId)?.uuidString ?? profileId?.uuidString ?? "", a.substance, a.severity,
                                     a.occurredAt.timeIntervalSince1970,
                                     a.occurredAt.timeIntervalSince1970, a.occurredAt.timeIntervalSince1970])
            }
            for e in envelope.encounters {
                if try adoptOrSkip(encConflicts, e.id, adopt: {
                    try db.execute(sql: """
                        UPDATE encounter SET patient_id = ?, date = ?, kind = ?, diagnosis_text = ?
                        WHERE id = ?
                        """, arguments: [(remap(e.patientId) ?? e.patientId)?.uuidString ?? "", e.date.timeIntervalSince1970,
                                         e.kind, e.diagnosisText, e.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO encounter (id, patient_id, date, kind, diagnosis_text, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(e.id) ?? e.id).uuidString, (remap(e.patientId) ?? e.patientId)?.uuidString ?? profileId?.uuidString ?? "", e.date.timeIntervalSince1970,
                                     e.kind, e.diagnosisText,
                                     e.date.timeIntervalSince1970, e.date.timeIntervalSince1970])
            }
            for m in envelope.metrics {
                if try adoptOrSkip(metricConflicts, m.id, adopt: {
                    try db.execute(sql: """
                        UPDATE metric_sample SET patient_id = ?, metric_key = ?, value = ?, unit = ?, origin = ?, measured_at = ?, excluded = ?, source_ref = ?
                        WHERE id = ?
                        """, arguments: [(remap(m.patientId) ?? m.patientId)?.uuidString ?? "", m.key, m.value, m.unit, m.origin,
                                         m.measuredAt.timeIntervalSince1970, m.excluded ? 1 : 0, m.sourceRef, m.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded, source_ref, measured_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(m.id) ?? m.id).uuidString, (remap(m.patientId) ?? m.patientId)?.uuidString ?? profileId?.uuidString ?? "", m.key, m.value, m.unit, m.origin,
                                     m.origin == "hospital" ? 0 : 1, m.excluded ? 1 : 0, m.sourceRef,
                                     m.measuredAt.timeIntervalSince1970, m.measuredAt.timeIntervalSince1970])
            }
            for i in envelope.immunizations {
                if try adoptOrSkip(immConflicts, i.id, adopt: {
                    try db.execute(sql: """
                        UPDATE immunization SET patient_id = ?, vaccine_name = ?, administered_at = ?
                        WHERE id = ?
                        """, arguments: [(remap(i.patientId) ?? i.patientId)?.uuidString ?? "", i.vaccineName,
                                         i.administeredAt.timeIntervalSince1970, i.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO immunization (id, patient_id, vaccine_name, administered_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(i.id) ?? i.id).uuidString, (remap(i.patientId) ?? i.patientId)?.uuidString ?? profileId?.uuidString ?? "", i.vaccineName,
                                     i.administeredAt.timeIntervalSince1970,
                                     i.administeredAt.timeIntervalSince1970, i.administeredAt.timeIntervalSince1970])
            }
            for v in envelope.voiceNotes {
                if try adoptOrSkip(noteConflicts, v.id, adopt: {
                    let tagsJSON = String(data: (try JSONEncoder().encode(v.tags)), encoding: .utf8) ?? "[]"
                    try db.execute(sql: """
                        UPDATE voice_note SET patient_id = ?, body = ?, occurred_at = ?, tags = ?, in_timeline = ?
                        WHERE id = ?
                        """, arguments: [(remap(v.patientId) ?? v.patientId)?.uuidString ?? "", v.body,
                                         v.occurredAt.timeIntervalSince1970, tagsJSON, v.inTimeline ? 1 : 0, v.id.uuidString])
                }) { continue }
                let tagsJSON = String(data: (try JSONEncoder().encode(v.tags)), encoding: .utf8) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO voice_note (id, patient_id, body, occurred_at, tags, in_timeline, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [(remap(v.id) ?? v.id).uuidString, (remap(v.patientId) ?? v.patientId)?.uuidString ?? profileId?.uuidString ?? "", v.body,
                                     v.occurredAt.timeIntervalSince1970, tagsJSON, v.inTimeline ? 1 : 0,
                                     v.occurredAt.timeIntervalSince1970, v.occurredAt.timeIntervalSince1970])
            }
            // 敏感标记回写（BR-007/008 链必须随往返保持）
            for docId in envelope.sensitiveDocIds {
                try db.execute(sql: "UPDATE document_file SET is_sensitive = 1 WHERE id = ?",
                               arguments: [(remap(docId) ?? docId).uuidString])
            }
            for h in envelope.healthProblems {
                if try adoptOrSkip(problemConflicts, h.id, adopt: {
                    try db.execute(sql: """
                        UPDATE health_problem SET patient_id = ?, name = ?, created_at = ?
                        WHERE id = ?
                        """, arguments: [(remap(h.patientId) ?? h.patientId)?.uuidString ?? "", h.name,
                                         h.createdAt.timeIntervalSince1970, h.id.uuidString])
                }) { continue }
                try db.execute(sql: """
                    INSERT INTO health_problem (id, patient_id, name, archived, created_at, updated_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    """, arguments: [(remap(h.id) ?? h.id).uuidString, (remap(h.patientId) ?? h.patientId)?.uuidString ?? profileId?.uuidString ?? "", h.name,
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
