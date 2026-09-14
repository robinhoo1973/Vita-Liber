#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// v27 `card-hierarchy`（子项目 J · round1 §E.1 / §0.4 改判 / 原 D3 §C.8–§C.9）：体检表头（第三枢纽）幂等建/补、
/// 结论行 / 手术 / 治疗记录写入助手、主卡草稿建就诊、行解码与再确认比对。全部 `static`、同事务、成员隔离
///（每条 SQL 带 `patient_id`）；跨成员一律 `invalidCard` 回滚。
///
/// 纪律：BR-003（主卡草稿 D 级须逐字段确认，由 `ParentCardDraftRules.*Draft` 在 Domain 侧裁定，这里只落库）；
/// BR-004/012（`severity_text` 只存打印文本，不编码不排序不着色）；BR-006/007（一般检查 `*_text` 原文，投影由 Domain 白名单裁定）。
extension OCRCardStore {
    /// 结论行的恰一父键（`clinical_conclusion` CHECK 三外键恰一非空）。
    struct ConclusionParent {
        let table: String       // health_exam / lab_report / exam_report（静态字面量，可安全拼入 SQL）
        let column: String      // health_exam_id / lab_report_id / exam_report_id
        let id: UUID
    }

    // MARK: - 就诊（主卡草稿 / 就诊卡共用 INSERT）

    /// `encounter` 全列 INSERT（就诊卡新建与 §0.4 主卡草稿同列同序；`kind` 已由 Domain 校验为 `EncounterKind`）。
    static func insertEncounter(_ encounter: EncounterDraft, patientId: UUID, db: Database, now: Date) throws {
        guard encounter.patientId == patientId, EncounterKind(rawValue: encounter.kind) != nil else { throw StoreError.invalidCard }
        try db.execute(sql: """
            INSERT INTO encounter (id, patient_id, date, kind, hospital, department, doctor,
              chief_complaint, diagnosis_text, advice_text, created_at, updated_at,
              present_illness, visit_summary, past_history, physical_exam, allergy_history)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [encounter.id.uuidString, patientId.uuidString, encounter.date.timeIntervalSince1970,
                encounter.kind, normalized(encounter.hospital), normalized(encounter.department), normalized(encounter.doctor),
                normalized(encounter.chiefComplaint), normalized(encounter.diagnosisText), normalized(encounter.adviceText),
                now.timeIntervalSince1970, now.timeIntervalSince1970,
                normalized(encounter.presentIllness), normalized(encounter.visitSummary), normalized(encounter.pastHistory),
                normalized(encounter.physicalExam), normalized(encounter.allergyHistory)])
    }

    // MARK: - 体检表头（§E.1 第三枢纽）

    /// 体检表头幂等建/补：幂等键 `(patient_id, document_file_id)` = 同一份原件一份体检（首页卡与结论页草稿会合到同一行）。
    /// 命中 → 全列 `COALESCE(NULLIF(col, ''), ?)` 只补空 + `confirmed = 1`（多页原件不覆盖既有列，冲突值留在来源卡）；
    /// 未命中 → INSERT（`id = exam.id` = 回执 row_id 或草稿新 UUID）。跨成员（同文档已有他人体检）→ `invalidCard`。
    static func ensureHealthExam(_ exam: HealthExam, documentId: UUID, db: Database, now: Date) throws -> UUID {
        let patientId = exam.patientId
        guard patientId != FactPlaceholder.unassignedId else { throw StoreError.invalidCard }
        let facts = healthExamFacts(exam)
        if let stored = try Row.fetchOne(db, sql: "SELECT id, patient_id FROM health_exam WHERE document_file_id = ? ORDER BY created_at, id LIMIT 1",
                                         arguments: [documentId.uuidString]) {
            guard (stored["patient_id"] as String) == patientId.uuidString, let id = UUID(uuidString: stored["id"]) else { throw StoreError.invalidCard }
            try db.execute(sql: """
                UPDATE health_exam SET org_name = COALESCE(NULLIF(org_name, ''), ?), exam_no = COALESCE(NULLIF(exam_no, ''), ?),
                  package_name = COALESCE(NULLIF(package_name, ''), ?), exam_date = COALESCE(exam_date, ?),
                  total_doctor = COALESCE(NULLIF(total_doctor, ''), ?), report_date = COALESCE(report_date, ?),
                  height_text = COALESCE(NULLIF(height_text, ''), ?), weight_text = COALESCE(NULLIF(weight_text, ''), ?), bmi_text = COALESCE(NULLIF(bmi_text, ''), ?),
                  systolic_text = COALESCE(NULLIF(systolic_text, ''), ?), diastolic_text = COALESCE(NULLIF(diastolic_text, ''), ?),
                  pulse_text = COALESCE(NULLIF(pulse_text, ''), ?), waist_text = COALESCE(NULLIF(waist_text, ''), ?),
                  vision_left_text = COALESCE(NULLIF(vision_left_text, ''), ?), vision_right_text = COALESCE(NULLIF(vision_right_text, ''), ?),
                  overall_conclusion = COALESCE(NULLIF(overall_conclusion, ''), ?), health_guidance = COALESCE(NULLIF(health_guidance, ''), ?),
                  confirmed = 1, updated_at = ?
                WHERE id = ? AND patient_id = ?
                """, arguments: StatementArguments(facts + [now.timeIntervalSince1970, id.uuidString, patientId.uuidString]))
            guard db.changesCount == 1 else { throw StoreError.invalidCard }
            return id
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_exam WHERE id = ?", arguments: [exam.id.uuidString]) == 0 else { throw StoreError.corruptReceipt }
        let head: [DatabaseValueConvertible?] = [exam.id.uuidString, patientId.uuidString, documentId.uuidString]
        let tail: [DatabaseValueConvertible?] = [exam.source.rawValue, now.timeIntervalSince1970, now.timeIntervalSince1970]
        try db.execute(sql: """
            INSERT INTO health_exam (id, patient_id, document_file_id, org_name, exam_no, package_name, exam_date, total_doctor, report_date,
              height_text, weight_text, bmi_text, systolic_text, diastolic_text, pulse_text, waist_text, vision_left_text, vision_right_text,
              overall_conclusion, health_guidance, source, confirmed, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """, arguments: StatementArguments(head + facts + tail))
        return exam.id
    }

    /// `health_exam` 事实列（DDL 同序，不含 id/外键/来源/时间戳）；文本经 `normalized`（空串视同 NULL）；一般检查列一律原文。
    static func healthExamFacts(_ e: HealthExam) -> [DatabaseValueConvertible?] {
        [normalized(e.orgName), normalized(e.examNo), normalized(e.packageName), e.examDate?.timeIntervalSince1970,
         normalized(e.totalDoctor), e.reportDate?.timeIntervalSince1970,
         normalized(e.heightText), normalized(e.weightText), normalized(e.bmiText),
         normalized(e.systolicText), normalized(e.diastolicText), normalized(e.pulseText), normalized(e.waistText),
         normalized(e.visionLeftText), normalized(e.visionRightText),
         normalized(e.overallConclusion), normalized(e.healthGuidance)]
    }

    // MARK: - 结论行（§E.1 / 融合方案 §六-6.3）

    /// 结论卡的父：显式/草稿体检枢纽优先；无体检枢纽时取同文档、同成员**唯一**的已确认检验表头，再取唯一的检查报告；
    /// 两者皆无或不唯一 → `invalidCard`（不猜父；注册表 `hub(for:)` 恒给结论卡体检草稿，正常流不会到达此分支）。
    static func conclusionParent(healthExamId: UUID?, patientId: UUID, documentId: UUID, db: Database) throws -> ConclusionParent {
        if let exam = healthExamId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_exam WHERE id = ? AND patient_id = ?",
                                   arguments: [exam.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidCard }
            return ConclusionParent(table: "health_exam", column: "health_exam_id", id: exam)
        }
        for (table, column) in [("lab_report", "lab_report_id"), ("exam_report", "exam_report_id")] {
            let ids = try String.fetchAll(db, sql: "SELECT id FROM \(table) WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1",
                                          arguments: [documentId.uuidString, patientId.uuidString])
            if ids.count == 1, let id = UUID(uuidString: ids[0]) { return ConclusionParent(table: table, column: column, id: id) }
            if ids.count > 1 { throw StoreError.invalidCard }
        }
        throw StoreError.invalidCard
    }

    /// `clinical_conclusion` 全列 INSERT：三外键恰一非空（值侧 `hasExactlyOneParent` 先拒，DDL CHECK 兜底）、父同成员；
    /// `severity_text` 原文（BR-004/012）。
    static func insertClinicalConclusion(_ c: ClinicalConclusion, db: Database) throws {
        guard c.patientId != FactPlaceholder.unassignedId, c.hasExactlyOneParent,
              ClinicalConclusion.conclusionTypes.contains(c.conclusionType), !c.content.isEmpty else { throw StoreError.invalidCard }
        let parents: [(String, UUID?)] = [("health_exam", c.healthExamId), ("lab_report", c.labReportId), ("exam_report", c.examReportId)]
        for (table, id) in parents {
            guard let id else { continue }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ? AND patient_id = ?",
                                   arguments: [id.uuidString, c.patientId.uuidString]) == 1 else { throw StoreError.invalidCard }
        }
        try db.execute(sql: """
            INSERT INTO clinical_conclusion (id, patient_id, lab_report_id, exam_report_id, health_exam_id, conclusion_type, content, severity_text,
              ordinal, source_page, source_row_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [c.id.uuidString, c.patientId.uuidString, c.labReportId?.uuidString, c.examReportId?.uuidString, c.healthExamId?.uuidString,
                             c.conclusionType, c.content, normalized(c.severityText), c.ordinal, c.sourcePage, c.sourceRowId?.uuidString,
                             c.createdAt.timeIntervalSince1970])
    }

    // MARK: - 手术 / 治疗（原 D3 §C.8 / §C.9）

    /// `surgery` 全列 INSERT（DDL 同名同序；编码/级别/植入物/出血量等一律原文 `*_text`）。
    static func insertSurgery(_ s: Surgery, db: Database) throws {
        guard s.patientId != FactPlaceholder.unassignedId, !s.surgeryName.isEmpty else { throw StoreError.invalidCard }
        if let encounter = s.encounterId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                   arguments: [encounter.uuidString, s.patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
        }
        let head: [DatabaseValueConvertible?] = [s.id.uuidString, s.patientId.uuidString, s.encounterId?.uuidString, s.documentFileId?.uuidString]
        let tail: [DatabaseValueConvertible?] = [s.source.rawValue, s.confirmed ? 1 : 0, s.createdAt.timeIntervalSince1970, s.updatedAt.timeIntervalSince1970]
        try db.execute(sql: """
            INSERT INTO surgery (id, patient_id, encounter_id, document_file_id, hospital, department, surgery_at, ended_at,
              surgery_name, surgery_code_text, surgery_level_text, surgeon, assistants, anesthesiologist, anesthesia_method,
              preop_diagnosis_text, postop_diagnosis_text, procedure_course, intraop_findings,
              implants_text, specimen_text, blood_loss_text, transfusion_text, drainage_text, postop_orders, complications_text,
              source, confirmed, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: StatementArguments(head + surgeryFacts(s) + tail))
    }

    /// `surgery` 事实列（DDL 同序，不含 id/外键/来源/时间戳）。
    static func surgeryFacts(_ s: Surgery) -> [DatabaseValueConvertible?] {
        [normalized(s.hospital), normalized(s.department), s.surgeryAt?.timeIntervalSince1970, s.endedAt?.timeIntervalSince1970,
         s.surgeryName, normalized(s.surgeryCodeText), normalized(s.surgeryLevelText), normalized(s.surgeon), normalized(s.assistants),
         normalized(s.anesthesiologist), normalized(s.anesthesiaMethod), normalized(s.preopDiagnosisText), normalized(s.postopDiagnosisText),
         normalized(s.procedureCourse), normalized(s.intraopFindings), normalized(s.implantsText), normalized(s.specimenText),
         normalized(s.bloodLossText), normalized(s.transfusionText), normalized(s.drainageText), normalized(s.postopOrders), normalized(s.complicationsText)]
    }

    /// `treatment_record` 全列 INSERT（`drugs_text` 原文不拆行、不进 prescription_line/medication；`allergy_event_id` 只由用户显式关联）。
    static func insertTreatmentRecord(_ t: TreatmentRecord, db: Database) throws {
        guard t.patientId != FactPlaceholder.unassignedId, TreatmentRecord.treatmentTypes.contains(t.treatmentType) else { throw StoreError.invalidCard }
        if let encounter = t.encounterId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                   arguments: [encounter.uuidString, t.patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
        }
        if let allergy = t.allergyEventId {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allergy_event WHERE id = ? AND patient_id = ?",
                                   arguments: [allergy.uuidString, t.patientId.uuidString]) == 1 else { throw StoreError.invalidCard }
        }
        let head: [DatabaseValueConvertible?] = [t.id.uuidString, t.patientId.uuidString, t.encounterId?.uuidString, t.documentFileId?.uuidString]
        let tail: [DatabaseValueConvertible?] = [t.source.rawValue, t.confirmed ? 1 : 0, t.createdAt.timeIntervalSince1970, t.updatedAt.timeIntervalSince1970]
        try db.execute(sql: """
            INSERT INTO treatment_record (id, patient_id, encounter_id, document_file_id, treatment_type, treated_at, hospital, department, doctor, executor,
              diagnosis_text, content, drugs_text, session_text, adverse_reaction_text, allergy_event_id, result_text, note,
              source, confirmed, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: StatementArguments(head + treatmentFacts(t) + tail))
    }

    /// `treatment_record` 事实列（DDL 同序，不含 id/外键/来源/时间戳）。
    static func treatmentFacts(_ t: TreatmentRecord) -> [DatabaseValueConvertible?] {
        [t.treatmentType, t.treatedAt?.timeIntervalSince1970, normalized(t.hospital), normalized(t.department), normalized(t.doctor), normalized(t.executor),
         normalized(t.diagnosisText), normalized(t.content), normalized(t.drugsText), normalized(t.sessionText), normalized(t.adverseReactionText),
         t.allergyEventId?.uuidString, normalized(t.resultText), normalized(t.note)]
    }

    // MARK: - 行解码（读面共用：detail / HealthExamStore / ExportService / 再确认比对）

    static func healthExam(from row: Row) throws -> HealthExam {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let source = FactSource(rawValue: row["source"]) else { throw StoreError.corruptReceipt }
        return HealthExam(
            id: id, patientId: patient, documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
            orgName: row["org_name"], examNo: row["exam_no"], packageName: row["package_name"],
            examDate: (row["exam_date"] as Double?).map(Date.init(timeIntervalSince1970:)), totalDoctor: row["total_doctor"],
            reportDate: (row["report_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
            heightText: row["height_text"], weightText: row["weight_text"], bmiText: row["bmi_text"],
            systolicText: row["systolic_text"], diastolicText: row["diastolic_text"], pulseText: row["pulse_text"], waistText: row["waist_text"],
            visionLeftText: row["vision_left_text"], visionRightText: row["vision_right_text"],
            overallConclusion: row["overall_conclusion"], healthGuidance: row["health_guidance"],
            source: source, confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    static func clinicalConclusion(from row: Row) throws -> ClinicalConclusion {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]) else { throw StoreError.corruptReceipt }
        return ClinicalConclusion(
            id: id, patientId: patient,
            labReportId: (row["lab_report_id"] as String?).flatMap(UUID.init(uuidString:)),
            examReportId: (row["exam_report_id"] as String?).flatMap(UUID.init(uuidString:)),
            healthExamId: (row["health_exam_id"] as String?).flatMap(UUID.init(uuidString:)),
            conclusionType: row["conclusion_type"], content: row["content"], severityText: row["severity_text"], ordinal: row["ordinal"],
            sourcePage: row["source_page"], sourceRowId: (row["source_row_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    static func surgery(from row: Row) throws -> Surgery {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let source = FactSource(rawValue: row["source"]) else { throw StoreError.corruptReceipt }
        return Surgery(
            id: id, patientId: patient, encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
            hospital: row["hospital"], department: row["department"],
            surgeryAt: (row["surgery_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            endedAt: (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            surgeryName: row["surgery_name"], surgeryCodeText: row["surgery_code_text"], surgeryLevelText: row["surgery_level_text"],
            surgeon: row["surgeon"], assistants: row["assistants"], anesthesiologist: row["anesthesiologist"], anesthesiaMethod: row["anesthesia_method"],
            preopDiagnosisText: row["preop_diagnosis_text"], postopDiagnosisText: row["postop_diagnosis_text"],
            procedureCourse: row["procedure_course"], intraopFindings: row["intraop_findings"],
            implantsText: row["implants_text"], specimenText: row["specimen_text"], bloodLossText: row["blood_loss_text"],
            transfusionText: row["transfusion_text"], drainageText: row["drainage_text"],
            postopOrders: row["postop_orders"], complicationsText: row["complications_text"],
            source: source, confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    static func treatmentRecord(from row: Row) throws -> TreatmentRecord {
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              let source = FactSource(rawValue: row["source"]) else { throw StoreError.corruptReceipt }
        return TreatmentRecord(
            id: id, patientId: patient, encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
            treatmentType: row["treatment_type"], treatedAt: (row["treated_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            hospital: row["hospital"], department: row["department"], doctor: row["doctor"], executor: row["executor"],
            diagnosisText: row["diagnosis_text"], content: row["content"], drugsText: row["drugs_text"], sessionText: row["session_text"],
            adverseReactionText: row["adverse_reaction_text"],
            allergyEventId: (row["allergy_event_id"] as String?).flatMap(UUID.init(uuidString:)),
            resultText: row["result_text"], note: row["note"],
            source: source, confirmed: (row["confirmed"] as Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    /// `v_clinical_report` 行 → 读模型（视图列：report_id / patient_id / report_type / report_source / report_date / org_name / report_no /
    /// encounter_id / health_exam_id / document_file_id / confirmed）。
    static func clinicalReportSummary(from row: Row) throws -> ClinicalReportSummary {
        guard let id = UUID(uuidString: row["report_id"]), let patient = UUID(uuidString: row["patient_id"]),
              let type = ReportType(rawValue: row["report_type"]) else { throw StoreError.corruptReceipt }
        return ClinicalReportSummary(
            reportId: id, patientId: patient, reportType: type,
            reportSource: (row["report_source"] as String?).flatMap(ReportSource.init(rawValue:)),
            reportDate: (row["report_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
            orgName: row["org_name"], reportNo: row["report_no"],
            encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            healthExamId: (row["health_exam_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentFileId: (row["document_file_id"] as String?).flatMap(UUID.init(uuidString:)),
            confirmed: (row["confirmed"] as Int) == 1)
    }

    // MARK: - 再确认比对（已提交结论行的事实列必须仍与回执一致）

    /// 已提交结论行（id = 回执 row_id）：类型 / 原文 / 严重度原文必须与其行意图一致；缺行或不一致 → false。
    static func conclusionsMatch(_ intents: [EntityCardProjection.ClinicalConclusionIntent], patientId: String, db: Database) throws -> Bool {
        for item in intents {
            guard let stored = try Row.fetchOne(db, sql: "SELECT * FROM clinical_conclusion WHERE (id = ? OR source_row_id = ?) AND patient_id = ?",
                                                arguments: [item.rowId.uuidString, item.rowId.uuidString, patientId]) else { return false }
            let c = item.conclusion
            let texts: [(String?, String?)] = [(stored["conclusion_type"], c.conclusionType), (stored["content"], c.content), (stored["severity_text"], c.severityText)]
            guard texts.allSatisfy({ normalized($0.0) == normalized($0.1) }) else { return false }
        }
        return true
    }
}
#endif
