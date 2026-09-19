#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// v27（子项目 J · round1 §E.1 / 融合方案 §七-7.2）：体检枢纽只读读面——列表 / 表头 / 子报告（经 `v_clinical_report` 视图）/
/// 结论（按 ordinal）/ 一般检查投影点（`metric_sample.health_exam_id`，不含挂体检的检验行）。写入方为 `OCRCardStore`
///（体检首页卡 / 主卡草稿）；本 store 不写。成员隔离：每条 SQL 带 `patient_id = ?`；跨成员一律 `invalidCard`（不泄露存在性）。
/// BR-004/012：结论 `severityText` 原文只呈现；BR-006：一般检查原文列随表头返回，投影点只是趋势读面。
public actor HealthExamStore {
    public struct HealthExamDetail: Sendable {
        public let exam: HealthExam
        /// 子报告（检验表头 / 检查报告；视图已按外键推断 `reportSource`）。
        public let reports: [ClinicalReportSummary]
        public let conclusions: [ClinicalConclusion]
        /// 一般检查投影点（weight / bloodPressureSys / bloodPressureDia / heartRate；按落库序）。
        public let generalSamples: [OCRCardStore.LabSampleRow]
        /// 原件（体检首页所在文档）。
        public let documentId: UUID?
        public init(exam: HealthExam, reports: [ClinicalReportSummary], conclusions: [ClinicalConclusion],
                    generalSamples: [OCRCardStore.LabSampleRow], documentId: UUID?) {
            self.exam = exam; self.reports = reports; self.conclusions = conclusions
            self.generalSamples = generalSamples; self.documentId = documentId
        }
    }

    /// 体检下的子卡清单（时间轴子卡源同口径的读面：J4 体检详情 / 挂接 Picker 复用）。
    public struct Children: Sendable, Equatable {
        public let labReports: [LabReport]
        public let examReports: [ExamReport]
        public let conclusions: [ClinicalConclusion]
        public init(labReports: [LabReport], examReports: [ExamReport], conclusions: [ClinicalConclusion]) {
            self.labReports = labReports; self.examReports = examReports; self.conclusions = conclusions
        }
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 已确认体检（按体检日倒序；`exam_date ?? report_date ?? created_at`）。
    public func list(patientId: UUID, limit: Int = 200) async throws -> [HealthExam] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM health_exam WHERE patient_id = ? AND confirmed = 1
                ORDER BY COALESCE(exam_date, report_date, created_at) DESC, id DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map(OCRCardStore.healthExam(from:))
        }
    }

    /// 单张体检表头（同成员；不存在 / 他人的 → `invalidCard`）。
    public func healthExam(id: UUID, patientId: UUID) async throws -> HealthExam {
        try await writer.read { db in
            try Self.exam(id: id, patientId: patientId, db: db)
        }
    }

    /// 体检下的子卡（检验表头 / 检查报告经 `health_exam_id`；结论按 ordinal）。
    public func children(ofHealthExam id: UUID, patientId: UUID) async throws -> Children {
        try await writer.read { db in
            _ = try Self.exam(id: id, patientId: patientId, db: db)
            let labs = try Row.fetchAll(db, sql: """
                SELECT * FROM lab_report WHERE health_exam_id = ? AND patient_id = ? AND confirmed = 1
                ORDER BY COALESCE(collected_at, reported_at, created_at) DESC, id
                """, arguments: [id.uuidString, patientId.uuidString]).map(OCRCardStore.labReport(from:))
            let exams = try Row.fetchAll(db, sql: """
                SELECT * FROM exam_report WHERE health_exam_id = ? AND patient_id = ? AND confirmed = 1
                ORDER BY COALESCE(exam_at, reported_at, created_at) DESC, id
                """, arguments: [id.uuidString, patientId.uuidString]).map(OCRCardStore.examReport(from:))
            return Children(labReports: labs, examReports: exams, conclusions: try Self.conclusions(examId: id, patientId: patientId, db: db))
        }
    }

    /// 体检详情读面：表头 → 子报告（视图）→ 结论 → 一般检查投影点 → 原件。
    public func detail(id: UUID, patientId: UUID) async throws -> HealthExamDetail {
        try await writer.read { db in
            let exam = try Self.exam(id: id, patientId: patientId, db: db)
            let reports = try Row.fetchAll(db, sql: """
                SELECT * FROM v_clinical_report WHERE health_exam_id = ? AND patient_id = ? AND report_type <> 'health_exam' AND confirmed = 1
                ORDER BY report_date DESC, report_id
                """, arguments: [id.uuidString, patientId.uuidString]).map(OCRCardStore.clinicalReportSummary(from:))
            let samples = try Row.fetchAll(db, sql: """
                SELECT * FROM metric_sample WHERE health_exam_id = ? AND patient_id = ? AND lab_report_id IS NULL AND excluded = 0
                ORDER BY created_at, rowid
                """, arguments: [id.uuidString, patientId.uuidString]).map(OCRCardStore.labSampleRow(from:))
            return HealthExamDetail(exam: exam, reports: reports, conclusions: try Self.conclusions(examId: id, patientId: patientId, db: db),
                                    generalSamples: samples, documentId: exam.documentFileId)
        }
    }

    private static func exam(id: UUID, patientId: UUID, db: Database) throws -> HealthExam {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM health_exam WHERE id = ? AND patient_id = ?",
                                         arguments: [id.uuidString, patientId.uuidString]) else { throw OCRCardStore.StoreError.invalidCard }
        return try OCRCardStore.healthExam(from: row)
    }

    private static func conclusions(examId: UUID, patientId: UUID, db: Database) throws -> [ClinicalConclusion] {
        try Row.fetchAll(db, sql: "SELECT * FROM clinical_conclusion WHERE health_exam_id = ? AND patient_id = ? ORDER BY ordinal, created_at",
                         arguments: [examId.uuidString, patientId.uuidString]).map(OCRCardStore.clinicalConclusion(from:))
    }
}
#endif
