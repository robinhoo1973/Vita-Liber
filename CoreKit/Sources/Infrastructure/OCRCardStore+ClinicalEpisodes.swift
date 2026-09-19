#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// v26 `clinical-episodes`（子项目 D §C.2–§C.5 / D2-3）：住院 / 诊断 / 检查 / 检验表头与定性行的写入助手、
/// 行解码与再确认比对。全部 `static`、同事务、成员隔离（每条 SQL 带 `patient_id`）；跨成员一律 `invalidCard` 回滚。
extension OCRCardStore {
    struct HospitalizationOutcome {
        let entity: UUID
        let encounter: UUID
    }

    // MARK: - 住院期（§C.2）

    /// 住院卡落库：显式归属就诊 → 该就诊的住院期只补空（`UNIQUE(encounter_id)`，绝不重复）；无归属 → 新建
    /// `encounter(kind = intent.encounterKind, date = episodeDate, hospital, department = admitDept)` + `hospitalization`。
    /// 实体 id = 回执 row_id（确定性，与 v25 回填同纪律）。
    static func saveHospitalization(_ intent: EntityCardProjection.HospitalizationIntent, patientId: UUID, documentId: UUID,
                                    associatedEncounter: UUID?, db: Database, now: Date) throws -> HospitalizationOutcome {
        let h = intent.hospitalization
        let encounterId: UUID
        if let existing = associatedEncounter {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                   arguments: [existing.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
            encounterId = existing
            // 就诊枢纽只补空（医院 / 科室；kind/date 由就诊自身持有，不被住院卡改写）。
            try db.execute(sql: """
                UPDATE encounter SET hospital = COALESCE(NULLIF(hospital, ''), ?), department = COALESCE(NULLIF(department, ''), ?), updated_at = ?
                WHERE id = ? AND patient_id = ? AND deleted_at IS NULL
                """, arguments: [h.hospital, h.admitDept, now.timeIntervalSince1970, existing.uuidString, patientId.uuidString])
            guard db.changesCount == 1 else { throw StoreError.invalidAssociation }
        } else {
            encounterId = UUID()
            try db.execute(sql: """
                INSERT INTO encounter (id, patient_id, date, kind, hospital, department, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [encounterId.uuidString, patientId.uuidString, intent.episodeDate.timeIntervalSince1970, intent.encounterKind,
                                 h.hospital, h.admitDept, now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        let entity: UUID
        if let stored = try Row.fetchOne(db, sql: "SELECT id, patient_id FROM hospitalization WHERE encounter_id = ?", arguments: [encounterId.uuidString]) {
            guard (stored["patient_id"] as String) == patientId.uuidString, let id = UUID(uuidString: stored["id"]) else { throw StoreError.invalidCard }
            entity = id
            // 多份原件（入院记录 / 出院小结）为同一住院期补空：COALESCE(NULLIF) 全列，冲突值留在来源卡（与就诊卡同策略）。
            try db.execute(sql: """
                UPDATE hospitalization SET hospital = COALESCE(NULLIF(hospital, ''), ?), medical_record_no = COALESCE(NULLIF(medical_record_no, ''), ?),
                  inpatient_times = COALESCE(inpatient_times, ?), admit_at = COALESCE(admit_at, ?), discharge_at = COALESCE(discharge_at, ?),
                  actual_days = COALESCE(actual_days, ?), admit_dept = COALESCE(NULLIF(admit_dept, ''), ?), discharge_dept = COALESCE(NULLIF(discharge_dept, ''), ?),
                  ward = COALESCE(NULLIF(ward, ''), ?), bed_no = COALESCE(NULLIF(bed_no, ''), ?), admit_route_text = COALESCE(NULLIF(admit_route_text, ''), ?),
                  payment_type_text = COALESCE(NULLIF(payment_type_text, ''), ?), discharge_way_text = COALESCE(NULLIF(discharge_way_text, ''), ?),
                  attending_physician = COALESCE(NULLIF(attending_physician, ''), ?),
                  admit_diagnosis_text = COALESCE(NULLIF(admit_diagnosis_text, ''), ?), discharge_diagnosis_text = COALESCE(NULLIF(discharge_diagnosis_text, ''), ?),
                  admit_condition = COALESCE(NULLIF(admit_condition, ''), ?), treatment_course = COALESCE(NULLIF(treatment_course, ''), ?),
                  discharge_condition = COALESCE(NULLIF(discharge_condition, ''), ?), discharge_orders = COALESCE(NULLIF(discharge_orders, ''), ?),
                  take_home_drugs_text = COALESCE(NULLIF(take_home_drugs_text, ''), ?), total_cost = COALESCE(total_cost, ?),
                  summary_doctor = COALESCE(NULLIF(summary_doctor, ''), ?), summary_date = COALESCE(summary_date, ?),
                  confirmed = 1, updated_at = ?
                WHERE id = ? AND patient_id = ?
                """, arguments: StatementArguments(hospitalizationFacts(h) + [now.timeIntervalSince1970, entity.uuidString, patientId.uuidString]))
            guard db.changesCount == 1 else { throw StoreError.invalidAssociation }
        } else {
            entity = h.id
            let head: [DatabaseValueConvertible?] = [entity.uuidString, patientId.uuidString, encounterId.uuidString, documentId.uuidString]
            let tail: [DatabaseValueConvertible?] = [now.timeIntervalSince1970, now.timeIntervalSince1970]
            try db.execute(sql: """
                INSERT INTO hospitalization (id, patient_id, encounter_id, document_file_id,
                  hospital, medical_record_no, inpatient_times, admit_at, discharge_at, actual_days, admit_dept, discharge_dept, ward, bed_no,
                  admit_route_text, payment_type_text, discharge_way_text, attending_physician, admit_diagnosis_text, discharge_diagnosis_text,
                  admit_condition, treatment_course, discharge_condition, discharge_orders, take_home_drugs_text, total_cost, summary_doctor, summary_date,
                  source, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ocr', 1, ?, ?)
                """, arguments: StatementArguments(head + hospitalizationFacts(h) + tail))
        }
        return HospitalizationOutcome(entity: entity, encounter: encounterId)
    }

    /// `hospitalization` 事实列（DDL 同序，不含 id/外键/来源/时间戳）；文本经 `normalized`（空串视同 NULL）。
    static func hospitalizationFacts(_ h: Hospitalization) -> [DatabaseValueConvertible?] {
        [normalized(h.hospital), normalized(h.medicalRecordNo), h.inpatientTimes, h.admitAt?.timeIntervalSince1970, h.dischargeAt?.timeIntervalSince1970,
         h.actualDays, normalized(h.admitDept), normalized(h.dischargeDept), normalized(h.ward), normalized(h.bedNo),
         normalized(h.admitRouteText), normalized(h.paymentTypeText), normalized(h.dischargeWayText), normalized(h.attendingPhysician),
         normalized(h.admitDiagnosisText), normalized(h.dischargeDiagnosisText),
         normalized(h.admitCondition), normalized(h.treatmentCourse), normalized(h.dischargeCondition), normalized(h.dischargeOrders),
         normalized(h.takeHomeDrugsText), h.totalCost, normalized(h.summaryDoctor), h.summaryDate?.timeIntervalSince1970]
    }

    // MARK: - 检验表头 / 定性行（§C.5）

    /// 同卡表头幂等建/补：`source_card_id = card.id`（UNIQUE）；新表头 id = card.id（与 v26 SQL 回填 `id = card_id` 同一确定性规则）。
    /// 既有表头只补空（多批提交同一卡：先数值行、后定性行共用一条）；跨成员表头 → `invalidCard`。
    /// v27（子项目 J）：`healthExamId` / `reportSource` 写 `health_exam_id` / `report_source`（体检枢纽回指 + 报告来源；
    /// 既有表头同样只补空——v27 前的表头 NULL 不回填）。体检枢纽须同成员，否则 `invalidCard`。
    static func ensureLabReport(_ header: EntityCardProjection.LabReportIntent, card: MatchedCard, patientId: UUID, documentId: UUID,
                                encounterId: UUID?, db: Database, now: Date,
                                healthExamId: UUID? = nil, reportSource: String? = nil) throws -> UUID {
        if let healthExamId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_exam WHERE id = ? AND patient_id = ?",
                                   arguments: [healthExamId.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidCard }
        }
        if let reportSource { guard ReportSource(rawValue: reportSource) != nil else { throw StoreError.invalidCard } }
        let facts: [DatabaseValueConvertible?] = [
            normalized(header.hospital), normalized(header.department), normalized(header.labName), normalized(header.reportNo),
            normalized(header.specimenType), normalized(header.specimenNo), normalized(header.testClassText), normalized(header.clinicalDiagnosis),
            header.collectedAt?.timeIntervalSince1970, header.receivedAt?.timeIntervalSince1970, header.reportedAt?.timeIntervalSince1970,
            normalized(header.sendDoctor), normalized(header.testDoctor), normalized(header.reviewDoctor),
        ]
        if let stored = try Row.fetchOne(db, sql: "SELECT id, patient_id, document_file_id FROM lab_report WHERE source_card_id = ?", arguments: [card.id.uuidString]) {
            guard (stored["patient_id"] as String) == patientId.uuidString, let id = UUID(uuidString: stored["id"]),
                  (stored["document_file_id"] as String?) == documentId.uuidString else { throw StoreError.invalidCard }
            try db.execute(sql: """
                UPDATE lab_report SET hospital = COALESCE(NULLIF(hospital, ''), ?), department = COALESCE(NULLIF(department, ''), ?),
                  lab_name = COALESCE(NULLIF(lab_name, ''), ?), report_no = COALESCE(NULLIF(report_no, ''), ?),
                  specimen_type = COALESCE(NULLIF(specimen_type, ''), ?), specimen_no = COALESCE(NULLIF(specimen_no, ''), ?),
                  test_class_text = COALESCE(NULLIF(test_class_text, ''), ?), clinical_diagnosis = COALESCE(NULLIF(clinical_diagnosis, ''), ?),
                  collected_at = COALESCE(collected_at, ?), received_at = COALESCE(received_at, ?), reported_at = COALESCE(reported_at, ?),
                  send_doctor = COALESCE(NULLIF(send_doctor, ''), ?), test_doctor = COALESCE(NULLIF(test_doctor, ''), ?), review_doctor = COALESCE(NULLIF(review_doctor, ''), ?),
                  encounter_id = COALESCE(encounter_id, ?), health_exam_id = COALESCE(health_exam_id, ?), report_source = COALESCE(report_source, ?),
                  confirmed = 1, updated_at = ?
                WHERE id = ? AND patient_id = ?
                """, arguments: StatementArguments(facts + [encounterId?.uuidString, healthExamId?.uuidString, reportSource,
                                                           now.timeIntervalSince1970, id.uuidString, patientId.uuidString]))
            guard db.changesCount == 1 else { throw StoreError.invalidCard }
            return id
        }
        let id = card.id
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report WHERE id = ?", arguments: [id.uuidString]) == 0 else { throw StoreError.corruptReceipt }
        let head: [DatabaseValueConvertible?] = [id.uuidString, patientId.uuidString, encounterId?.uuidString, documentId.uuidString]
        let tail: [DatabaseValueConvertible?] = [card.id.uuidString, now.timeIntervalSince1970, now.timeIntervalSince1970,
                                                 reportSource, healthExamId?.uuidString]
        try db.execute(sql: """
            INSERT INTO lab_report (id, patient_id, encounter_id, document_file_id, hospital, department, lab_name, report_no,
              specimen_type, specimen_no, test_class_text, clinical_diagnosis, collected_at, received_at, reported_at,
              send_doctor, test_doctor, review_doctor, source_card_id, source, confirmed, created_at, updated_at,
              report_source, health_exam_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'ocr', 1, ?, ?, ?, ?)
            """, arguments: StatementArguments(head + facts + tail))
        return id
    }

    /// `lab_result` 全列 INSERT（DDL 同名同序；结果/参考范围/标记一律原文，BR-004/006/012）。
    static func insertLabResult(_ result: LabResult, db: Database) throws {
        guard result.patientId != FactPlaceholder.unassignedId, result.labReportId != FactPlaceholder.unassignedId else { throw StoreError.invalidCard }
        try db.execute(sql: """
            INSERT INTO lab_result (id, patient_id, lab_report_id, ordinal, item_name, item_code_text, result_text, comparator, unit,
              reference_text, abnormal_flag, method, code_concept_id, source_page, source_row_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [result.id.uuidString, result.patientId.uuidString, result.labReportId.uuidString, result.ordinal, result.itemName,
                             normalized(result.itemCodeText), result.resultText, normalized(result.comparator), normalized(result.unit),
                             normalized(result.referenceText), normalized(result.abnormalFlag), normalized(result.method), result.codeConceptId,
                             result.sourcePage, result.sourceRowId?.uuidString, result.createdAt.timeIntervalSince1970])
    }

    // MARK: - 诊断 / 检查（§C.3 / §C.4）

    static func insertDiagnosis(_ d: Diagnosis, db: Database) throws {
        guard d.patientId != FactPlaceholder.unassignedId else { throw StoreError.invalidCard }
        try db.execute(sql: """
            INSERT INTO diagnosis (id, patient_id, encounter_id, ordinal, diagnosis_type, name, code_text, code_system_text, diagnosed_at,
              health_problem_id, note, source_page, source_row_id, document_file_id, confirmed, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [d.id.uuidString, d.patientId.uuidString, d.encounterId?.uuidString, d.ordinal, d.diagnosisType, d.name,
                             normalized(d.codeText), normalized(d.codeSystemText), d.diagnosedAt?.timeIntervalSince1970,
                             d.healthProblemId?.uuidString, normalized(d.note), d.sourcePage, d.sourceRowId?.uuidString, d.documentFileId?.uuidString,
                             d.confirmed ? 1 : 0, d.createdAt.timeIntervalSince1970, d.updatedAt.timeIntervalSince1970])
    }

    /// v27：`report_source` / `health_exam_id` 随实体写入（体检枢纽须同成员；`reportSource` 须为 CHECK 枚举）。
    static func insertExamReport(_ r: ExamReport, db: Database) throws {
        guard r.patientId != FactPlaceholder.unassignedId else { throw StoreError.invalidCard }
        if let source = r.reportSource { guard ReportSource(rawValue: source) != nil else { throw StoreError.invalidCard } }
        if let exam = r.healthExamId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_exam WHERE id = ? AND patient_id = ?",
                                   arguments: [exam.uuidString, r.patientId.uuidString]) == 1 else { throw StoreError.invalidCard }
        }
        try db.execute(sql: """
            INSERT INTO exam_report (id, patient_id, encounter_id, document_file_id, report_type, hospital, department, report_no, exam_part, exam_method,
              exam_at, reported_at, findings, impression, apply_doctor, report_doctor, review_doctor, source, confirmed, created_at, updated_at,
              report_source, health_exam_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [r.id.uuidString, r.patientId.uuidString, r.encounterId?.uuidString, r.documentFileId?.uuidString, r.reportType,
                             normalized(r.hospital), normalized(r.department), normalized(r.reportNo), normalized(r.examPart), normalized(r.examMethod),
                             r.examAt?.timeIntervalSince1970, r.reportedAt?.timeIntervalSince1970, normalized(r.findings), normalized(r.impression),
                             normalized(r.applyDoctor), normalized(r.reportDoctor), normalized(r.reviewDoctor), r.source.rawValue,
                             r.confirmed ? 1 : 0, r.createdAt.timeIntervalSince1970, r.updatedAt.timeIntervalSince1970,
                             r.reportSource, r.healthExamId?.uuidString])
    }

    // MARK: - 行解码（读面共用：detail / EncounterStore / 再确认比对）

    static func hospitalization(from row: Row) throws -> Hospitalization {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let encounter = UUID(uuidString: row["encounter_id"]), let source = FactSource(rawValue: row["source"]) else { throw StoreError.corruptReceipt }
        return Hospitalization(
            id: id, patientId: patient, encounterId: encounter, documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
            hospital: row["hospital"], medicalRecordNo: row["medical_record_no"], inpatientTimes: row["inpatient_times"],
            admitAt: (row["admit_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            dischargeAt: (row["discharge_at"] as Double?).map(Date.init(timeIntervalSince1970:)), actualDays: row["actual_days"],
            admitDept: row["admit_dept"], dischargeDept: row["discharge_dept"], ward: row["ward"], bedNo: row["bed_no"],
            admitRouteText: row["admit_route_text"], paymentTypeText: row["payment_type_text"], dischargeWayText: row["discharge_way_text"],
            attendingPhysician: row["attending_physician"], admitDiagnosisText: row["admit_diagnosis_text"], dischargeDiagnosisText: row["discharge_diagnosis_text"],
            admitCondition: row["admit_condition"], treatmentCourse: row["treatment_course"], dischargeCondition: row["discharge_condition"],
            dischargeOrders: row["discharge_orders"], takeHomeDrugsText: row["take_home_drugs_text"], totalCost: row["total_cost"],
            summaryDoctor: row["summary_doctor"], summaryDate: (row["summary_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
            source: source, confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    static func diagnosis(from row: Row) throws -> Diagnosis {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]) else { throw StoreError.corruptReceipt }
        return Diagnosis(
            id: id, patientId: patient, encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)), ordinal: row["ordinal"],
            diagnosisType: row["diagnosis_type"], name: row["name"], codeText: row["code_text"], codeSystemText: row["code_system_text"],
            diagnosedAt: (row["diagnosed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            healthProblemId: (row["health_problem_id"] as String?).flatMap(UUID.init(uuidString:)), note: row["note"],
            sourcePage: row["source_page"], sourceRowId: (row["source_row_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)), confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    static func examReport(from row: Row) throws -> ExamReport {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let source = FactSource(rawValue: row["source"]) else { throw StoreError.corruptReceipt }
        return ExamReport(
            id: id, patientId: patient, encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)), reportType: row["report_type"],
            hospital: row["hospital"], department: row["department"], reportNo: row["report_no"], examPart: row["exam_part"], examMethod: row["exam_method"],
            examAt: (row["exam_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            reportedAt: (row["reported_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            findings: row["findings"], impression: row["impression"],
            applyDoctor: row["apply_doctor"], reportDoctor: row["report_doctor"], reviewDoctor: row["review_doctor"],
            source: source, confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            reportSource: row.hasColumn("report_source") ? row["report_source"] : nil,
            healthExamId: row.hasColumn("health_exam_id") ? (row["health_exam_id"] as String?).flatMap(UUID.init(uuidString:)) : nil)
    }

    static func labReport(from row: Row) throws -> LabReport {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let source = FactSource(rawValue: row["source"]) else { throw StoreError.corruptReceipt }
        return LabReport(
            id: id, patientId: patient, encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
            hospital: row["hospital"], department: row["department"], labName: row["lab_name"], reportNo: row["report_no"],
            specimenType: row["specimen_type"], specimenNo: row["specimen_no"], testClassText: row["test_class_text"], clinicalDiagnosis: row["clinical_diagnosis"],
            collectedAt: (row["collected_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            receivedAt: (row["received_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            reportedAt: (row["reported_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            sendDoctor: row["send_doctor"], testDoctor: row["test_doctor"], reviewDoctor: row["review_doctor"],
            sourceCardId: (row["source_card_id"] as String?).flatMap(UUID.init(uuidString:)),
            source: source, confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            reportSource: row.hasColumn("report_source") ? row["report_source"] : nil,
            healthExamId: row.hasColumn("health_exam_id") ? (row["health_exam_id"] as String?).flatMap(UUID.init(uuidString:)) : nil)
    }

    static func labResult(from row: Row) throws -> LabResult {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let report = UUID(uuidString: row["lab_report_id"]) else { throw StoreError.corruptReceipt }
        return LabResult(
            id: id, patientId: patient, labReportId: report, ordinal: row["ordinal"], itemName: row["item_name"], itemCodeText: row["item_code_text"],
            resultText: row["result_text"], comparator: row["comparator"], unit: row["unit"], referenceText: row["reference_text"],
            abnormalFlag: row["abnormal_flag"], method: row["method"], codeConceptId: row["code_concept_id"],
            sourcePage: row["source_page"], sourceRowId: (row["source_row_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    /// 检验数值行读面（`metric_sample` 医院来源行；`abnormalFlag` 为报告打印原文，只呈现不解释）。
    public struct LabSampleRow: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let rawLabel: String
        public let value: Double
        public let unit: String
        public let refLow: Double?
        public let refHigh: Double?
        public let abnormalFlag: String?
        public let measuredAt: Date
        public let excluded: Bool
    }

    static func labSampleRow(from row: Row) throws -> LabSampleRow {
        guard let id = UUID(uuidString: row["id"]) else { throw StoreError.corruptReceipt }
        return LabSampleRow(id: id, rawLabel: (row["raw_label"] as String?) ?? (row["metric_key"] as String), value: row["value"], unit: row["unit"],
                            refLow: row["ref_low"], refHigh: row["ref_high"], abnormalFlag: row["abnormal_flag"],
                            measuredAt: Date(timeIntervalSince1970: row["measured_at"]), excluded: (row["excluded"] as Int?) == 1)
    }

    // MARK: - 再确认比对（已提交行的事实列必须仍与回执一致）

    /// 已提交检验行：数值行按回执 entity_id 回到 metric_sample、定性行回到 lab_result，逐列比对（provenance 列不比）。
    static func labRowsMatch(_ lab: EntityCardProjection.LabProjection, receipts: [Row], patientId: String, db: Database) throws -> Bool {
        guard lab.remainingRows.isEmpty else { return false }
        var entityByRow: [String: (table: String, id: String)] = [:]
        for receipt in receipts { entityByRow[receipt["row_id"]] = (receipt["entity_table"], receipt["entity_id"]) }
        for (rowId, sample) in zip(lab.rowIds, lab.samples) {
            guard let entity = entityByRow[rowId.uuidString], entity.table == "metric_sample",
                  let stored = try Row.fetchOne(db, sql: "SELECT * FROM metric_sample WHERE id = ? AND patient_id = ?", arguments: [entity.id, patientId]) else { return false }
            let texts: [(String?, String?)] = [(stored["raw_label"], sample.rawLabel), (stored["unit"], sample.unit), (stored["abnormal_flag"], sample.abnormalFlag)]
            let numbers: [(Double?, Double?)] = [(stored["value"], sample.value), (stored["ref_low"], sample.refLow), (stored["ref_high"], sample.refHigh),
                                                 (stored["measured_at"], sample.measuredAt.timeIntervalSince1970)]
            guard texts.allSatisfy({ normalized($0.0) == normalized($0.1) }), numbers.allSatisfy({ $0.0 == $0.1 }) else { return false }
        }
        for item in lab.qualitative {
            guard let entity = entityByRow[item.rowId.uuidString], entity.table == "lab_result",
                  let stored = try Row.fetchOne(db, sql: "SELECT * FROM lab_result WHERE id = ? AND patient_id = ?", arguments: [entity.id, patientId]) else { return false }
            let r = item.result
            let texts: [(String?, String?)] = [(stored["item_name"], r.itemName), (stored["result_text"], r.resultText), (stored["comparator"], r.comparator),
                                               (stored["unit"], r.unit), (stored["reference_text"], r.referenceText), (stored["abnormal_flag"], r.abnormalFlag),
                                               (stored["method"], r.method)]
            guard texts.allSatisfy({ normalized($0.0) == normalized($0.1) }) else { return false }
        }
        return true
    }

    /// 已提交诊断行（id = 回执 row_id）：名称 / 类型 / 编码原文 / 备注必须与其行意图一致；缺行或不一致 → false。
    static func diagnosesMatch(_ intents: [EntityCardProjection.DiagnosisIntent], patientId: String, db: Database) throws -> Bool {
        for item in intents {
            guard let stored = try Row.fetchOne(db, sql: "SELECT * FROM diagnosis WHERE (id = ? OR source_row_id = ?) AND patient_id = ? AND confirmed = 1",
                                                arguments: [item.rowId.uuidString, item.rowId.uuidString, patientId]) else { return false }
            let d = item.diagnosis
            let texts: [(String?, String?)] = [(stored["name"], d.name), (stored["diagnosis_type"], d.diagnosisType), (stored["code_text"], d.codeText),
                                               (stored["code_system_text"], d.codeSystemText), (stored["note"], d.note)]
            guard texts.allSatisfy({ normalized($0.0) == normalized($0.1) }) else { return false }
        }
        return true
    }

    // MARK: - 详情读面的日期呈现

    /// REAL 日期列 → 卡字段同型的 `yyyy-MM-dd`（与 `EntityCardProjection.parseDate` 的当日零点互逆；非本地化展示串，App 层再格式化）。
    static func dateString(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: seconds))
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
#endif
