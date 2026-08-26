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
        public var consentRecords: [ConsentRecord]
        public var timeline: [TimelineDocumentEntry]
        public var plans: [PlanExport]
        public var appointments: [AppointmentExport]

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
        public init(schemaVersion: Int = 1, exportedAt: TimeInterval = 0,
                    owner: LocalOwner? = nil, consentRecords: [ConsentRecord] = [],
                    timeline: [TimelineDocumentEntry] = [], plans: [PlanExport] = [],
                    appointments: [AppointmentExport] = []) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.owner = owner
            self.consentRecords = consentRecords
            self.timeline = timeline
            self.plans = plans
            self.appointments = appointments
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
            return Envelope(schemaVersion: 1, exportedAt: Date().timeIntervalSince1970,
                            owner: owner, consentRecords: consents, timeline: timeline,
                            plans: plans, appointments: appointments)
        }
    }

    /// 导入（往返一致性的一票否决半场）：把 envelope 写回当前库。
    /// FK 拓扑序：patient_profile → local_owner → consent/document/plan/appointment（ERR#35）
    public func importJSON(_ envelope: Envelope) async throws {
        try await writer.write { db in
            if let owner = envelope.owner {
                try db.execute(sql: """
                    INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [owner.id.uuidString, owner.displayName,
                                     owner.selfPatientId?.uuidString, owner.createdAt])
            }
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
                    VALUES (?, '', ?, ?, 'tablet', ?, ?)
                    """, arguments: [medId.uuidString, p.medicationName, p.spec,
                                     p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
                let scheduleJSON = String(data: try JSONEncoder().encode(p.schedule), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO medication_plan
                      (id, patient_id, medication_id, status, schedule_json, start_date, end_date, created_at, updated_at)
                    VALUES (?, '', ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [p.id.uuidString, medId.uuidString, p.status.rawValue, scheduleJSON,
                                     p.startDate.timeIntervalSince1970, p.endDate?.timeIntervalSince1970,
                                     p.startDate.timeIntervalSince1970, p.startDate.timeIntervalSince1970])
            }
            for a in envelope.appointments {
                try db.execute(sql: """
                    INSERT INTO appointment (id, patient_id, hospital, department, starts_at, status, created_at, updated_at)
                    VALUES (?, '', ?, ?, ?, ?, ?, ?)
                    """, arguments: [a.id.uuidString, a.hospital, a.department,
                                     a.startsAt.timeIntervalSince1970, a.status,
                                     a.startsAt.timeIntervalSince1970, a.startsAt.timeIntervalSince1970])
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
