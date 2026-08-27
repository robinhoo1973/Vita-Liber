// 平台守卫镜像 Package.swift（ERR#8 纪律）
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// FR4.5/FR4.6 疫苗接种记录仓储（actor）。
///
/// 语义边界（FR4.6）：
/// - 疫苗记录属**预防保健档案**而非就诊事件（encounter_id 可空）；
/// - App **不提供接种建议、不自动判定漏种责任、不内置免疫计划判定**——
///   只如实记录，剂次提醒复用预约状态机由用户登记计划后驱动；
/// - 来源与确认状态：手动录入 = C 级已确认；文档 OCR 派生 = D 级待确认（BR-003）。
public actor ImmunizationStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct Record: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var vaccineName: String
        public var doseNumber: Int
        public var administeredAt: Date?
        public var provider: String
        public var lotNumber: String
        public var source: String          // manual / ocr / provider
        public var confirmed: Bool
        public init(id: UUID, vaccineName: String, doseNumber: Int, administeredAt: Date?,
                    provider: String, lotNumber: String, source: String, confirmed: Bool) {
            self.id = id; self.vaccineName = vaccineName; self.doseNumber = doseNumber
            self.administeredAt = administeredAt; self.provider = provider
            self.lotNumber = lotNumber; self.source = source; self.confirmed = confirmed
        }
    }

    /// 手动录入 = C 级已确认（FR4.5）；OCR 派生走 `create(confirmed: false)`（D 级）。
    public func create(id: UUID = UUID(), patientId: UUID, vaccineName: String,
                       doseNumber: Int = 1, administeredAt: Date?,
                       provider: String = "", lotNumber: String = "",
                       confirmed: Bool = true, source: String = "manual") async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO immunization
                  (id, patient_id, vaccine_name, dose_number, administered_at,
                   provider, lot_number, source, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, vaccineName,
                                 doseNumber, administeredAt?.timeIntervalSince1970,
                                 provider, lotNumber, source, confirmed ? 1 : 0,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    /// 按成员列出（时间倒序；未确认记录一并返回，由 UI 区分待确认态）
    public func list(patientId: UUID) async throws -> [Record] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM immunization
                WHERE patient_id = ?
                ORDER BY administered_at DESC
                """, arguments: [patientId.uuidString])
            return rows.map { row in
                Record(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                       vaccineName: row["vaccine_name"] as String,
                       doseNumber: row["dose_number"] as Int? ?? 1,
                       administeredAt: (row["administered_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                       provider: row["provider"] as String? ?? "",
                       lotNumber: row["lot_number"] as String? ?? "",
                       source: row["source"] as String? ?? "manual",
                       confirmed: (row["confirmed"] as Int?) == 1)
            }
        }
    }

    /// 同疫苗的下一次剂次序号（无记录=1）——只做**如实建议显示**，
    /// 不内置「该打什么疫苗」的判定（FR4.6 边界）
    public func nextDoseNumber(patientId: UUID, vaccineName: String) async throws -> Int {
        let records = try await list(patientId: patientId)
        return records.filter { $0.vaccineName == vaccineName }.map(\.doseNumber).max().map { $0 + 1 } ?? 1
    }
}
#endif
