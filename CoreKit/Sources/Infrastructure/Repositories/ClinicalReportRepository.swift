import Foundation
import Domain
import Protocols

public final class ClinicalReportRepository: ClinicalReportRepositoryProtocol {

    private let db: any DatabaseProtocol

    public init(db: any DatabaseProtocol) {
        self.db = db
    }

    public func save(_ card: ClinicalReport) async throws {
        guard !card.cardId.isEmpty else { throw RepositoryError.invalidId }
        try db.transaction {
            try upsertReport(card)
            try replaceItems(card)
            try replaceConclusions(card)
        }
    }

    public func fetch(id: String) async throws -> ClinicalReport? {
        let rows = try db.query("SELECT * FROM t_clinical_report WHERE report_id = ? LIMIT 1;", params: [.text(id)])
        guard let row = rows.first else { return nil }
        var card = mapReportRow(row)
        card.items = try fetchItems(reportId: id)
        card.conclusions = try fetchConclusions(reportId: id)
        return card
    }

    public func fetchAll(patientId: String?) async throws -> [ClinicalReport] {
        let rows: [[String: SQLiteValue]]
        if let pid = patientId {
            rows = try db.query("SELECT * FROM t_clinical_report WHERE patient_id = ? ORDER BY report_date DESC;", params: [.text(pid)])
        } else {
            rows = try db.query("SELECT * FROM t_clinical_report ORDER BY report_date DESC;")
        }
        return rows.map(mapReportRow)
    }

    public func fetchItems(reportId: String) async throws -> [ClinicalReportItem] {
        let rows = try db.query("SELECT * FROM t_clinical_report_item WHERE report_id = ? ORDER BY item_seq;", params: [.text(reportId)])
        return rows.map { r in
            ClinicalReportItem(
                itemId: r["item_id"]?.string ?? UUID().uuidString,
                category: r["item_category"]?.string,
                type: r["item_type"]?.string,
                code: r["item_code"]?.string,
                name: r["item_name"]?.string ?? "",
                value: r["result_value"]?.string,
                unit: r["result_unit"]?.string,
                referenceRange: r["reference_range"]?.string,
                abnormalFlag: r["abnormal_flag"]?.string,
                method: r["exam_method"]?.string,
                device: r["device_name"]?.string,
                note: r["item_note"]?.string,
                confidence: 1.0
            )
        }
    }

    public func delete(id: String) async throws {
        try db.transaction {
            try db.execute("DELETE FROM t_clinical_report WHERE report_id = ?;", params: [.text(id)])
        }
    }

    private func upsertReport(_ card: ClinicalReport) throws {
        try db.execute("""
            INSERT INTO t_clinical_report
            (report_id, report_no, report_source, report_type, org_name, patient_id,
             patient_name, gender, age, report_doctor, review_doctor, report_date,
             clinical_diagnosis, overall_conclusion, critical_flag, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(report_id) DO UPDATE SET
                report_no = excluded.report_no, org_name = excluded.org_name,
                patient_name = excluded.patient_name, report_doctor = excluded.report_doctor,
                report_date = excluded.report_date, clinical_diagnosis = excluded.clinical_diagnosis,
                overall_conclusion = excluded.overall_conclusion, updated_at = excluded.updated_at;
            """, params: [
                .text(card.cardId),
                .text(card.reportNo ?? card.cardId),
                .text(card.reportSource.rawValue),
                .text(card.reportType.rawValue),
                card.orgName.map { .text($0) } ?? .null,
                .text(card.patientId ?? ""),
                card.patientName.map { .text($0) } ?? .null,
                card.gender.map { .text($0) } ?? .null,
                card.age.map { .text($0) } ?? .null,
                card.reportDoctor.map { .text($0) } ?? .null,
                card.reviewDoctor.map { .text($0) } ?? .null,
                card.reportDate.map { .text(dateString($0)) } ?? .null,
                card.clinicalDiagnosis.map { .text($0) } ?? .null,
                card.overallConclusion.map { .text($0) } ?? .null,
                .integer(card.criticalFlag ? 1 : 0),
                .real(card.createdAt.timeIntervalSince1970),
                .real(card.updatedAt.timeIntervalSince1970)
            ])
    }

    private func replaceItems(_ card: ClinicalReport) throws {
        try db.execute("DELETE FROM t_clinical_report_item WHERE report_id = ?;", params: [.text(card.cardId)])
        for (idx, item) in card.items.enumerated() {
            try db.execute("""
                INSERT INTO t_clinical_report_item
                (item_id, report_id, item_category, item_type, item_code, item_name,
                 result_value, result_unit, reference_range, abnormal_flag, item_seq, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, params: [
                    .text(item.itemId), .text(card.cardId),
                    .text(item.category ?? "检验"), .text(item.type ?? "1"),
                    item.code.map { .text($0) } ?? .null, .text(item.name),
                    item.value.map { .text($0) } ?? .null,
                    item.unit.map { .text($0) } ?? .null,
                    item.referenceRange.map { .text($0) } ?? .null,
                    item.abnormalFlag.map { .text($0) } ?? .null,
                    .integer(Int64(idx)), .real(Date().timeIntervalSince1970)
                ])
        }
    }

    private func replaceConclusions(_ card: ClinicalReport) throws {
        try db.execute("DELETE FROM t_clinical_report_conclusion WHERE report_id = ?;", params: [.text(card.cardId)])
        for (idx, c) in card.conclusions.enumerated() {
            try db.execute("""
                INSERT INTO t_clinical_report_conclusion
                (conclusion_id, report_id, conclusion_type, conclusion_content, severity_level, seq_no)
                VALUES (?,?,?,?,?,?);
                """, params: [
                    .text(c.conclusionId), .text(card.cardId), .text(c.type),
                    .text(c.content), c.severity.map { .text($0) } ?? .null,
                    .integer(Int64(idx))
                ])
        }
    }

    private func fetchConclusions(reportId: String) throws -> [ClinicalReportConclusion] {
        let rows = try db.query("SELECT * FROM t_clinical_report_conclusion WHERE report_id = ? ORDER BY seq_no;", params: [.text(reportId)])
        return rows.map { r in
            ClinicalReportConclusion(type: r["conclusion_type"]?.string ?? "", content: r["conclusion_content"]?.string ?? "", severity: r["severity_level"]?.string)
        }
    }

    private func mapReportRow(_ row: [String: SQLiteValue]) -> ClinicalReport {
        var card = ClinicalReport()
        card.cardId            = row["report_id"]?.string ?? UUID().uuidString
        card.reportNo          = row["report_no"]?.string
        card.reportSource      = ClinicalReportSource(rawValue: row["report_source"]?.string ?? "1") ?? .outpatient
        card.reportType        = ClinicalReportType(rawValue: row["report_type"]?.string ?? "1") ?? .lab
        card.orgName           = row["org_name"]?.string
        card.patientId         = row["patient_id"]?.string
        card.patientName       = row["patient_name"]?.string
        card.gender            = row["gender"]?.string
        card.age               = row["age"]?.string
        card.reportDoctor      = row["report_doctor"]?.string
        card.reviewDoctor      = row["review_doctor"]?.string
        card.reportDate        = row["report_date"]?.string.flatMap { dateFromString($0) }
        card.clinicalDiagnosis = row["clinical_diagnosis"]?.string
        card.overallConclusion = row["overall_conclusion"]?.string
        card.criticalFlag      = row["critical_flag"]?.bool ?? false
        card.createdAt         = row["created_at"]?.date ?? Date()
        card.updatedAt         = row["updated_at"]?.date ?? card.createdAt
        return card
    }

    private func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private func dateFromString(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
    }
}
