import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols

// binds: SU-M2-PENDINGCARD (FR3 / FR11.4 / FR23 / BR-001 / BR-003 · recognition-remediation-design §0.3 需求 1)
/// 子项目 D · D4-2「资料建议」接受流：`collect` 只读已确认回执、零写入；`accept` 逐项单事务写
/// `patient_profile.blood_type` / `health_problem` / `allergy_event` + 审计（`profile_suggestion_accepted`，meta 含留痕）；
/// 已有值不覆盖（`.skippedExisting`）；过敏严重度只能由用户给出；跨成员一律 `invalidCard`；忽略持久化不再复现。
@MainActor
final class ProfileSuggestionStoreTests: XCTestCase {
    private func fixture() async throws -> (GRDBStore, UUID, UUID) {
        let store = try GRDBStore.inMemory()
        let patient = UUID()
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'A', 'other', 0, 0)", arguments: [patient.uuidString])
        }
        let document = try await DocumentStore(writer: store.writer).save(
            patientId: patient, docType: "outpatient_record", sha256: "suggestion-test", mimeType: "image/png",
            origin: "import", isSensitive: false, metaJSON: nil, title: "病历", grade: "C",
            pages: [.init(index: 0, text: "第一页"), .init(index: 1, text: "第二页")])
        return (store, patient, document)
    }

    private func encounterCard(past: String? = nil, allergy: String? = nil, page: Int = 0) -> MatchedCard {
        var shared: [FieldDraft] = [.init(key: "date", value: "2026-03-01"), .init(key: "kind", value: "outpatient"), .init(key: "hospital", value: "医院")]
        if let past { shared.append(.init(key: "past_history", value: past)) }
        if let allergy { shared.append(.init(key: "allergy_history", value: allergy)) }
        return MatchedCard(kind: "encounter", pageIndex: page, shared: shared, rows: [MatchedCardRow(fields: [])],
                           allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
    }

    private func labCard(_ rows: [(String, String)], page: Int = 1) -> MatchedCard {
        MatchedCard(kind: "metric_sample", pageIndex: page,
                    shared: [.init(key: "measured_at", value: "2026-03-01"), .init(key: "hospital", value: "医院")],
                    rows: rows.map { MatchedCardRow(fields: [.init(key: "raw_label", value: $0.0), .init(key: "value", value: $0.1)]) },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
    }

    private func diagnosisCard(_ rows: [(String, String?)], page: Int = 0) -> MatchedCard {
        MatchedCard(kind: "diagnosis", pageIndex: page, shared: [.init(key: "diagnosed_at", value: "2026-03-01")],
                    rows: rows.map { row in
                        var fields: [FieldDraft] = [.init(key: "name", value: row.0)]
                        if let code = row.1 { fields.append(.init(key: "code_text", value: code)) }
                        return MatchedCardRow(fields: fields)
                    },
                    allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).confirmingAllFields()
    }

    private func count(_ db: GRDBStore, _ sql: String, _ arguments: StatementArguments = []) async throws -> Int {
        try await db.writer.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
    }

    // MARK: - collect

    func test_collectReadsConfirmedReceiptsAndWritesNothing() async throws {
        let (db, patient, document) = try await fixture()
        let cards = OCRCardStore(writer: db.writer)
        let card = encounterCard(past: "高血压病史10年", allergy: "青霉素")
        _ = try await cards.save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)

        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.map(\.kind), [.pastHistory, .allergy])
        XCTAssertEqual(out.map(\.value), ["高血压病史10年", "青霉素"])
        XCTAssertTrue(out.allSatisfy { $0.grade == .ocrUnconfirmed })
        let encounterId = try await db.writer.read { try String.fetchOne($0, sql: "SELECT id FROM encounter") }
        XCTAssertEqual(out.first?.provenance.entityTable, "encounter")
        XCTAssertEqual(out.first?.provenance.entityId.uuidString, encounterId)
        XCTAssertEqual(out.first?.provenance.documentId, document)
        XCTAssertEqual(out.first?.provenance.pageIndex, 0)
        XCTAssertEqual(out.first?.provenance.cardKind, "encounter")

        // 零写入：三目标表不变
        let bloodType = try await db.writer.read { try String.fetchOne($0, sql: "SELECT blood_type FROM patient_profile WHERE id = ?", arguments: [patient.uuidString]) }
        XCTAssertNil(bloodType)
        let problems = try await count(db, "SELECT COUNT(*) FROM health_problem")
        let allergies = try await count(db, "SELECT COUNT(*) FROM allergy_event")
        let audits = try await count(db, "SELECT COUNT(*) FROM audit_event")
        XCTAssertEqual([problems, allergies, audits], [0, 0, 0])

        // 计划签名（cardKind + entityIds）与 cardId 路径同结果
        let byEntity = try await store.collect(cardKind: "encounter", entityIds: [UUID(uuidString: encounterId ?? "")].compactMap { $0 }, patientId: patient)
        XCTAssertEqual(byEntity.map(\.dedupeKey), out.map(\.dedupeKey))
        // 他人的卡 → 无回执可读，零建议（不泄露存在性）
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let leaked = try await store.collect(cardId: card.id, patientId: other)
        XCTAssertTrue(leaked.isEmpty)
    }

    func test_collectNeverSurfacesUnconfirmedRows() async throws {
        let (db, patient, document) = try await fixture()
        // 未确认卡只建 D 级待办草稿、无回执 → 零建议（BR-003：建议只来自已确认字段）
        var draft = encounterCard(past: "哮喘")
        for i in draft.shared.indices { draft.shared[i].reenable() }
        let result = try await OCRCardStore(writer: db.writer).save(card: draft, patientId: patient, documentId: document)
        XCTAssertEqual(result.writtenCount, 0)
        let out = try await ProfileSuggestionStore(writer: db.writer).collect(cardId: draft.id, patientId: patient)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - accept · 血型

    func test_acceptBloodTypeWritesProfileAndAuditsProvenance() async throws {
        let (db, patient, document) = try await fixture()
        let card = labCard([("ABO血型", "A"), ("血红蛋白", "阴性")])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.map(\.kind), [.bloodType])
        XCTAssertEqual(out.first?.value, "A")
        XCTAssertEqual(out.first?.provenance.entityTable, "lab_result")
        XCTAssertEqual(out.first?.provenance.pageIndex, 1)

        let outcome = try await store.accept(out[0], patientId: patient)
        XCTAssertEqual(outcome, .written)
        let bloodType = try await db.writer.read { try String.fetchOne($0, sql: "SELECT blood_type FROM patient_profile WHERE id = ?", arguments: [patient.uuidString]) }
        XCTAssertEqual(bloodType, "A")
        let audit = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT action, entity_type, meta_json FROM audit_event") }
        XCTAssertEqual(audit?["action"] as String?, ProfileSuggestionStore.auditAction)
        XCTAssertEqual(audit?["entity_type"] as String?, "patient_profile")
        let meta = (audit?["meta_json"] as String?) ?? ""
        XCTAssertTrue(meta.contains("lab_result") && meta.contains(out[0].provenance.entityId.uuidString) && meta.contains("bloodType"))
        XCTAssertFalse(meta.contains("\"A\""), "审计只记留痕不记医疗内容")
        // 已接受的建议不再复现
        let again = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertTrue(again.isEmpty)
    }

    func test_acceptBloodTypeNeverOverwritesExistingValue() async throws {
        let (db, patient, document) = try await fixture()
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE patient_profile SET blood_type = 'B' WHERE id = ?", arguments: [patient.uuidString])
        }
        let card = labCard([("ABO血型", "A")])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.map(\.value), ["A"], "与已记录值不同仍建议，由用户裁定")
        let outcome = try await store.accept(out[0], patientId: patient)
        XCTAssertEqual(outcome, .skippedExisting)
        let bloodType = try await db.writer.read { try String.fetchOne($0, sql: "SELECT blood_type FROM patient_profile WHERE id = ?", arguments: [patient.uuidString]) }
        XCTAssertEqual(bloodType, "B")
        let audits = try await count(db, "SELECT COUNT(*) FROM audit_event")
        XCTAssertEqual(audits, 0, "未写入即无审计")
        // 「已有记录」的建议登记为已处理，不再复现
        let again = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: - accept · 慢性病 / 既往史 → health_problem

    func test_acceptChronicConditionCreatesHealthProblemAndBackfillsDiagnosis() async throws {
        let (db, patient, document) = try await fixture()
        let card = diagnosisCard([("高血压", "I10"), ("2型糖尿病", nil)])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.map(\.value), ["高血压", "2型糖尿病"])
        XCTAssertEqual(out.first?.codeText, "I10")
        XCTAssertEqual(out.first?.provenance.entityTable, "diagnosis")

        let outcome = try await store.accept(out[0], patientId: patient)
        XCTAssertEqual(outcome, .written)
        let problem = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT id, name, archived FROM health_problem WHERE patient_id = ?", arguments: [patient.uuidString]) }
        XCTAssertEqual(problem?["name"] as String?, "高血压")
        XCTAssertEqual(problem?["archived"] as Int?, 0)
        // FR11.4：采用为健康问题后回填 diagnosis.health_problem_id
        let backfilled = try await db.writer.read {
            try String.fetchOne($0, sql: "SELECT health_problem_id FROM diagnosis WHERE id = ?", arguments: [out[0].provenance.entityId.uuidString])
        }
        XCTAssertEqual(backfilled, problem?["id"] as String?)
        let audit = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT action, entity_type FROM audit_event") }
        XCTAssertEqual(audit?["action"] as String?, "profile_suggestion_accepted")
        XCTAssertEqual(audit?["entity_type"] as String?, "health_problem")
        // 已记录的问题不再建议；同名再接受 → skippedExisting、不重复建行
        let again = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(again.map(\.value), ["2型糖尿病"])
        let repeated = try await store.accept(out[0], patientId: patient)
        XCTAssertEqual(repeated, .skippedExisting)
        let problems = try await count(db, "SELECT COUNT(*) FROM health_problem")
        XCTAssertEqual(problems, 1)
    }

    func test_acceptPastHistoryWritesWholePassageAsHealthProblem() async throws {
        let (db, patient, document) = try await fixture()
        let card = encounterCard(past: "高血压病史10年、糖尿病5年")
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.map(\.kind), [.pastHistory])
        let outcome = try await store.accept(out[0], patientId: patient)
        XCTAssertEqual(outcome, .written)
        let name = try await db.writer.read { try String.fetchOne($0, sql: "SELECT name FROM health_problem WHERE patient_id = ?", arguments: [patient.uuidString]) }
        XCTAssertEqual(name, "高血压病史10年、糖尿病5年", "整段原文，不切分")
    }

    // MARK: - accept · 过敏 → allergy_event

    func test_acceptAllergyRequiresUserSeverityAndWritesEvent() async throws {
        let (db, patient, document) = try await fixture()
        let card = encounterCard(allergy: "青霉素")
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.map(\.kind), [.allergy])

        do {
            _ = try await store.accept(out[0], patientId: patient)
            XCTFail("严重度只能由用户给出，不占位、不推断")
        } catch OCRCardStore.StoreError.invalidCard {}
        do {
            _ = try await store.accept(out[0], patientId: patient, allergySeverity: "unknown")
            XCTFail("非 CHECK 枚举值必须拒绝")
        } catch OCRCardStore.StoreError.invalidCard {}
        let none = try await count(db, "SELECT COUNT(*) FROM allergy_event")
        XCTAssertEqual(none, 0)

        let written = try await store.accept(out[0], patientId: patient, allergySeverity: "moderate")
        XCTAssertEqual(written, .written)
        let row = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT substance, severity, note, reaction_tags, encounter_id, occurred_at FROM allergy_event WHERE patient_id = ?", arguments: [patient.uuidString]) }
        XCTAssertEqual(row?["substance"] as String?, "青霉素")
        XCTAssertEqual(row?["severity"] as String?, "moderate")
        XCTAssertEqual(row?["note"] as String?, "source:profile_suggestion")
        XCTAssertEqual(row?["reaction_tags"] as String?, "[]")
        XCTAssertEqual(row?["encounter_id"] as String?, out[0].provenance.entityId.uuidString)
        XCTAssertEqual(row?["occurred_at"] as Double?, out[0].occurredAt?.timeIntervalSince1970, "发生时间取来源就诊日期")
        let audit = try await db.writer.read { try Row.fetchOne($0, sql: "SELECT entity_type FROM audit_event") }
        XCTAssertEqual(audit?["entity_type"] as String?, "allergy_event")
        // 展示词（中）也接受（AllergyStore 同口径）
        let outcome = try await store.accept(out[0], patientId: patient, allergySeverity: "中")
        XCTAssertEqual(outcome, .skippedExisting, "同一过敏原已记录不重复建行")
    }

    // MARK: - 成员隔离 / 忽略

    func test_acceptRejectsCrossMemberProvenance() async throws {
        let (db, patient, document) = try await fixture()
        let other = UUID()
        try await db.writer.write { db in
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'B', 'other', 0, 0)", arguments: [other.uuidString])
        }
        let card = labCard([("ABO血型", "A")])
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        do {
            _ = try await store.accept(out[0], patientId: other)
            XCTFail("来源实体属于他人 → invalidCard")
        } catch OCRCardStore.StoreError.invalidCard {}
        let otherBlood = try await db.writer.read { try String.fetchOne($0, sql: "SELECT blood_type FROM patient_profile WHERE id = ?", arguments: [other.uuidString]) }
        XCTAssertNil(otherBlood)
        let audits = try await count(db, "SELECT COUNT(*) FROM audit_event")
        XCTAssertEqual(audits, 0)
        // 伪造来源表名不得进入 SQL
        var forged = out[0]
        forged.provenance.entityTable = "patient_profile; DROP TABLE audit_event"
        do {
            _ = try await store.accept(forged, patientId: patient)
            XCTFail("白名单外的来源表 → invalidCard")
        } catch OCRCardStore.StoreError.invalidCard {}
    }

    func test_dismissPersistsAndSuppressesResuggestion() async throws {
        let (db, patient, document) = try await fixture()
        let card = encounterCard(past: "哮喘病史", allergy: "海鲜")
        _ = try await OCRCardStore(writer: db.writer).save(card: card, patientId: patient, documentId: document)
        let store = ProfileSuggestionStore(writer: db.writer)
        let out = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(out.count, 2)
        try await store.dismiss(out[0], patientId: patient)
        let after = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertEqual(after.map(\.value), ["海鲜"])
        let states = try await count(db, "SELECT COUNT(*) FROM notification_state WHERE kind = 'profile_suggestion' AND archived_at IS NOT NULL")
        XCTAssertEqual(states, 1)
        // 忽略只登记键、不写事实、不审计
        let problems = try await count(db, "SELECT COUNT(*) FROM health_problem")
        let audits = try await count(db, "SELECT COUNT(*) FROM audit_event")
        XCTAssertEqual([problems, audits], [0, 0])
        try await store.dismiss(after, patientId: patient)
        let remaining = try await store.collect(cardId: card.id, patientId: patient)
        XCTAssertTrue(remaining.isEmpty)
        // 忽略键按成员分域：另一成员同值建议不受影响（通知中心六源聚合按键读取，不扫本 kind）
        let readback = try await NotificationStateStore(writer: db.writer).states(for: ["suggestion-none"])
        XCTAssertTrue(readback.isEmpty)
    }
}
