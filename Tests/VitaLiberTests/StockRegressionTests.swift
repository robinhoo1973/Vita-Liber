import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M2-STOCK（评审修正第二轮回归网）——D3 补录转场 PK 冲突、晚补录宽关联、
// D5 物化幂等/时区重锚、FR5.8 归档收藏组合态、商业化定价锚点。
/// 评审修正第二轮修复的回归防护（GRDB 落库半场；Domain 半场在 CoreKitTests）。
@MainActor
final class StockRegressionTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, MedicationStore, UUID, UUID) {
        try await GRDBStore.inMemoryWithMedication(patientName: "转场测试患者", medName: "阿司匹林", spec: "0.1g")
    }

    /// 种子一条「昨日 08:00」未决议行并补账为 missed（安全线已按计划扣减）。
    private func seedMissedDose(store: GRDBStore, meds: MedicationStore,
                                planId: UUID, patient: UUID, med: UUID,
                                lot: DualTrackInventory) async throws -> (due: Date, units: Double) {
        let units = 1.0
        let due = shanghaiCalendar.date(byAdding: .day, value: -1, to: Date())!
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO medication_dose_log (id, plan_id, scheduled_for, dose_units, delivery_state, user_action)
                VALUES (?, ?, ?, ?, 'planned', NULL)
                """, arguments: [UUID().uuidString, planId.uuidString,
                                 due.timeIntervalSince1970, units])
        }
        _ = try await meds.materializeMissed(now: Date())
        return (due, units)
    }

    /// D5 回归锚点（业主裁决 2026-09-18）：missed 行经**普通「已服」确认**
    /// （confirmTaken，非补录）转 taken——计划轨已被 materializeMissed 扣过，
    /// 转场必须仅补扣确认轨（Domain transitionDeduction），安全线不得双扣。
    /// 原名：test_D5_普通确认missed转taken_计划轨不双扣
    func test_D5_normalConfirmMissedToTaken_planTrackNotDoubleDeducted() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: shanghaiCalendar.date(byAdding: .day, value: -2, to: Date())!,
                                  endDate: nil)
        _ = try await seedMissedDose(store: store, meds: meds, planId: planId,
                                     patient: patient, med: med, lot: lot)
        let notifyId = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM medication_dose_log WHERE plan_id = ?",
                                arguments: [planId.uuidString]) ?? ""
        }
        try await meds.confirmTaken(notifyId: notifyId, patientId: patient)
        let rows = try await store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.user_action, l.remaining_plan_units, l.remaining_confirmed_units,
                       a.planned_units, a.confirmed_units
                FROM medication_dose_log d
                JOIN dose_lot_allocation a ON a.dose_log_id = d.id
                JOIN stock_lot l ON l.id = a.stock_lot_id
                WHERE d.plan_id = ?
                """, arguments: [planId.uuidString])
        }
        XCTAssertEqual((rows.first?["user_action"] as String?) ?? "", "taken")
        XCTAssertEqual((rows.first?["remaining_plan_units"] as Double?) ?? 0, 9,
                       "计划轨只扣一次（missed 已扣，普通确认转场补扣必须为 0）")
        XCTAssertEqual((rows.first?["remaining_confirmed_units"] as Double?) ?? 0, 9,
                       "确认轨随普通确认补扣")
        XCTAssertEqual((rows.first?["planned_units"] as Double?) ?? 0, 1)
        XCTAssertEqual((rows.first?["confirmed_units"] as Double?) ?? 0, 1,
                       "累加式 upsert：分配行双轨合计正确")
    }

    /// D3 转场 PK 冲突修复：missed→taken 补录不得因 dose_lot_allocation 主键冲突
    /// 整事务回滚（此前任何持有库存的补录必然失败）；计划轨不重复扣减。
    /// 原名：test_补录missed转taken_不PK冲突且计划轨不双扣
    func test_makeupMissedToTaken_noPKConflictNoDoubleDeductionOnPlanTrack() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: shanghaiCalendar.date(byAdding: .day, value: -2, to: Date())!,
                                  endDate: nil)
        let (due, _) = try await seedMissedDose(store: store, meds: meds, planId: planId,
                                                patient: patient, med: med, lot: lot)
        // 补录落在排程 ±30min 容差内 → 命中既有 missed 行转场
        try await meds.recordTakenAt(planId: planId, patientId: patient, medicationId: med,
                                     actualTime: due.addingTimeInterval(5 * 60), doseUnits: 1)
        let rows = try await store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.user_action, d.plan_id, l.remaining_plan_units, l.remaining_confirmed_units,
                       a.planned_units, a.confirmed_units
                FROM medication_dose_log d
                JOIN dose_lot_allocation a ON a.dose_log_id = d.id
                JOIN stock_lot l ON l.id = a.stock_lot_id
                WHERE d.plan_id = ?
                """, arguments: [planId.uuidString])
        }
        XCTAssertEqual(rows.count, 1, "转场必须复用既有行——同一逻辑剂量不得双行")
        XCTAssertEqual((rows.first?["user_action"] as String?) ?? "", "taken")
        XCTAssertEqual((rows.first?["remaining_plan_units"] as Double?) ?? 0, 9,
                       "计划轨只扣一次（missed 已扣，转场补扣必须为 0）")
        XCTAssertEqual((rows.first?["remaining_confirmed_units"] as Double?) ?? 0, 9,
                       "确认轨随补录扣减")
        XCTAssertEqual((rows.first?["planned_units"] as Double?) ?? 0, 1)
        XCTAssertEqual((rows.first?["confirmed_units"] as Double?) ?? 0, 1,
                       "累加式 upsert：分配行双轨合计正确")
    }

    /// 宽关联转场：补录实际时刻晚排程 2.5 小时（±30min 容差之外）——
    /// 必须转场原 missed 行而非 INSERT 随机 id 新行（否则计划轨双扣）。
    /// 原名：test_晚两小时补录_宽关联转场不双行不双扣
    func test_twoHourLateMakeup_wideLinkTransitionNoDuplicateRowsNoDoubleDeduction() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: shanghaiCalendar.date(byAdding: .day, value: -2, to: Date())!,
                                  endDate: nil)
        let (due, _) = try await seedMissedDose(store: store, meds: meds, planId: planId,
                                                patient: patient, med: med, lot: lot)
        // 晚 2.5 小时补录：±30min 找不到行，宽窗口（±12h）必须转场
        try await meds.recordTakenAt(planId: planId, patientId: patient, medicationId: med,
                                     actualTime: due.addingTimeInterval(2.5 * 3600), doseUnits: 1)
        let count = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM medication_dose_log WHERE plan_id = ?",
                             arguments: [planId.uuidString]) ?? 0
        }
        XCTAssertEqual(count, 1, "宽关联转场后仍只一行——不得新建随机 id 行")
        let planUnits = try await store.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT remaining_plan_units FROM stock_lot WHERE id = ?",
                                arguments: [lot.lotId.uuidString]) ?? 0
        }
        XCTAssertEqual(planUnits, 9, "计划轨只扣一次（missed 一次 + 转场零补扣）")
    }

    /// D5 物化幂等 + 时区重锚：同窗口重复物化零新增；换时区后同一逻辑剂量
    /// 重锚墙钟而非重复建行。
    /// 原名：test_物化窗口幂等且时区重锚不重复建行
    func test_materializedWindowIdempotent_timezoneReanchorNoDuplicateRows() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let planId = UUID()
        // 时钟确定性（CI 34045372069 实证）：逻辑剂量身份 = 本地日历日+序号——
        // 真实时钟落在 +0800 午夜窗口（UTC 仍在前一日）时两日历时区日分叉，
        // 同日剂量被判为异日新行。固定 12:00 UTC（= 20:00 +0800，两日历时区
        // 同日）锚定，与预约四级触发点测试同款日历注入纪律。
        let anchor = Date(timeIntervalSince1970: 1_800_014_400)   // 2027-01-15 12:00 UTC
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: anchor, endDate: nil)
        let first = try await meds.materializeWindow(now: anchor, calendar: shanghaiCalendar)
        let again = try await meds.materializeWindow(now: anchor, calendar: shanghaiCalendar)
        XCTAssertEqual(again, 0, "同窗口重复物化必须零新增（幂等）")
        XCTAssertGreaterThan(first, 0)

        // 换 UTC 日历（模拟时区变化）：同一逻辑剂量 ON CONFLICT 重锚，行数不变
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        _ = try await meds.materializeWindow(now: anchor, calendar: utc)
        let count = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM medication_dose_log WHERE plan_id = ?",
                             arguments: [planId.uuidString]) ?? 0
        }
        XCTAssertEqual(count, first, "时区重锚后行数不变——不得重复建行（D5 契约）")
    }

    /// FR5.8 归档/收藏正交组合态：收藏已归档文档不得解除归档；
    /// 取消归档保留收藏；组合态可逆。
    /// 原名：test_归档收藏组合态可逆
    func test_archiveFavoriteComboStateReversible() async throws {
        let store = try GRDBStore.inMemory()
        let docs = DocumentStore(writer: store.writer)
        let patient = UUID()
        let docId = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '归档测试', '本人', 0, 0)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type, origin, created_at, updated_at)
                VALUES (?, ?, 'prescription', 'active', 'deadbeef', 'image/jpeg', 'import', 0, 0)
                """, arguments: [docId.uuidString, patient.uuidString])
        }
        try await docs.setArchived(id: docId, archived: true)
        try await docs.setFavorite(id: docId, favorite: true)
        var status = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM document_file WHERE id = ?",
                                arguments: [docId.uuidString]) ?? ""
        }
        XCTAssertEqual(status, "archived_favorite", "收藏已归档文档必须保持归档")
        try await docs.setFavorite(id: docId, favorite: false)
        status = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM document_file WHERE id = ?",
                                arguments: [docId.uuidString]) ?? ""
        }
        XCTAssertEqual(status, "archived", "取消收藏回落纯归档，不得复活到活跃列表")
        try await docs.setArchived(id: docId, archived: false)
        status = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM document_file WHERE id = ?",
                                arguments: [docId.uuidString]) ?? ""
        }
        XCTAssertEqual(status, "active", "组合态全取消回落活跃")
    }

    /// 商业化定价锚点（评审修正第二轮 ④）：默认语言（zh-Hans）下 Pro 年价
    /// 必须与 comercial-spec §4.3 的 ¥68/年 锚点一致——L10n 解析失败会裸显
    /// key（不含 ¥），断言可捕捉 bundle 断链与锚点漂移。
    /// 原名：test_定价锚点与spec一致
    func test_pricingAnchorMatchesSpec() {
        XCTAssertTrue(L10n.payProYearlyPrice.contains("¥68"),
                      "zh-Hans Pro 年价锚点必须为 ¥68/年（comercial-spec §4.3）")
        XCTAssertTrue(L10n.payProMonthlyPrice.contains("¥12"),
                      "zh-Hans Pro 月价锚点必须为 ¥12/月（comercial-spec §4.3）")
        XCTAssertFalse(L10n.payProYearlyPrice.isEmpty)
        XCTAssertFalse(L10n.payProMonthlyPrice.isEmpty)
        XCTAssertFalse(L10n.payAddonPrice.isEmpty)
    }

    // MARK: - v27 doc_type_key 读写出口（子项目 J 接线：DocumentTypeKeyBackfill 的真实仓契约）

    /// 两成员 + 文档仓夹具（`doc_type_key` 用例共用）。
    private func documentFixture() async throws -> (GRDBStore, DocumentStore, UUID, UUID) {
        let store = try GRDBStore.inMemory()
        let (a, b) = (UUID(), UUID())
        try await store.writer.write { db in
            for (id, name) in [(a, "甲"), (b, "乙")] {
                try db.execute(sql: """
                    INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                    VALUES (?, ?, '本人', 0, 0)
                    """, arguments: [id.uuidString, name])
            }
        }
        return (store, DocumentStore(writer: store.writer), a, b)
    }

    /// 入库携带稳定键即落 `doc_type_key` 并随行投影回读；未传键（旧调用形态）= NULL 且进回填清单
    ///（nil = 全成员 / 按成员过滤 / limit 生效）。
    /// 原名：test_入库写稳定键_缺键行进回填清单
    func test_ingestWritesStableKey_missingKeyRowsEnterBackfillList() async throws {
        let (_, docs, a, b) = try await documentFixture()
        let keyed = try await docs.save(patientId: a, docType: "处方单", sha256: "k1", mimeType: "image/jpeg",
                                        origin: "import", isSensitive: false, metaJSON: nil, title: nil,
                                        docTypeKey: DocumentTypeKey.prescription.rawValue)
        let legacyA = try await docs.save(patientId: a, docType: "处方单", sha256: "k2", mimeType: "image/jpeg",
                                          origin: "import", isSensitive: false, metaJSON: nil, title: nil)
        let legacyB = try await docs.save(patientId: b, docType: "检验报告", sha256: "k3", mimeType: "image/jpeg",
                                          origin: "import", isSensitive: false, metaJSON: nil, title: nil)
        let keyedRow = try await docs.fetch(id: keyed)
        XCTAssertEqual(keyedRow?.docTypeKey, "prescription")
        let legacyRow = try await docs.fetch(id: legacyA)
        XCTAssertNil(legacyRow?.docTypeKey, "旧调用形态不传键 = NULL（由首启回填补齐）")
        let listed = try await docs.list(patientId: a)
        XCTAssertEqual(listed.first { $0.id == keyed }?.docTypeKey, "prescription", "列表投影同样携带稳定键")

        let all = try await docs.documentsMissingTypeKey(patientId: nil, limit: 10)
        XCTAssertEqual(Set(all.map { $0.id }), [legacyA, legacyB], "nil = 全成员；带键行不进清单")
        XCTAssertEqual(all.first { $0.id == legacyB }?.docType, "检验报告")
        XCTAssertEqual(all.first { $0.id == legacyB }?.patientId, b)
        let onlyB = try await docs.documentsMissingTypeKey(patientId: b, limit: 10)
        XCTAssertEqual(onlyB.map { $0.id }, [legacyB], "按成员过滤")
        let capped = try await docs.documentsMissingTypeKey(patientId: nil, limit: 1)
        XCTAssertEqual(capped.count, 1, "limit 生效")

        // 未知键在入库处即拒绝（doc_type_key 无 DDL CHECK，仓层是唯一校验点）——零写入
        do {
            _ = try await docs.save(patientId: a, docType: "处方单", sha256: "k4", mimeType: "image/jpeg",
                                    origin: "import", isSensitive: false, metaJSON: nil, title: nil,
                                    docTypeKey: "not_a_key")
            XCTFail("未知稳定键必须拒绝")
        } catch DocumentStore.StoreError.invalidDocTypeKey {}
        let afterReject = try await docs.list(patientId: a)
        XCTAssertEqual(afterReject.count, 2, "被拒绝的入库不得留下行")
    }

    /// `setDocTypeKey`：未知键拒绝、他人成员拒绝（BR-001，零写入）；本人成功后该行离开回填清单。
    /// 原名：test_setDocTypeKey_成员隔离_未知键拒绝_成功后离开清单
    func test_setDocTypeKey_memberIsolation_unknownKeyRejected_successLeavesList() async throws {
        let (store, docs, a, b) = try await documentFixture()
        let doc = try await docs.save(patientId: a, docType: "处方单", sha256: "s1", mimeType: "image/jpeg",
                                      origin: "import", isSensitive: false, metaJSON: nil, title: nil)
        do {
            try await docs.setDocTypeKey("not_a_key", documentId: doc, patientId: a)
            XCTFail("未知稳定键必须拒绝")
        } catch DocumentStore.StoreError.invalidDocTypeKey {}
        do {
            try await docs.setDocTypeKey(DocumentTypeKey.prescription.rawValue, documentId: doc, patientId: b)
            XCTFail("他人成员不得改写本人文档（BR-001）")
        } catch DocumentStore.StoreError.invalidSource {}
        do {
            try await docs.setDocTypeKey(DocumentTypeKey.prescription.rawValue, documentId: UUID(), patientId: a)
            XCTFail("不存在的文档必须报 invalidSource")
        } catch DocumentStore.StoreError.invalidSource {}
        var row = try await docs.fetch(id: doc)
        XCTAssertNil(row?.docTypeKey, "被拒绝的写入零落库")

        try await docs.setDocTypeKey(DocumentTypeKey.prescription.rawValue, documentId: doc, patientId: a)
        row = try await docs.fetch(id: doc)
        XCTAssertEqual(row?.docTypeKey, "prescription")
        let pending = try await docs.documentsMissingTypeKey(patientId: nil, limit: 10)
        XCTAssertTrue(pending.isEmpty, "已回填行不再进清单（幂等谓词 doc_type_key IS NULL）")
        let updatedAt = try await store.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT updated_at FROM document_file WHERE id = ?", arguments: [doc.uuidString])
        }
        XCTAssertGreaterThan(updatedAt ?? 0, 0, "键写入同步刷新 updated_at")
    }

    /// 复核改类型：传键即同步 `doc_type_key`（标签与键不漂移）；不传键（旧调用形态）保持原键。
    /// 原名：test_复核改类型同步稳定键_未传键保持原键
    func test_confirmTypeChangeSyncsStableKey_absentKeyKeepsOriginal() async throws {
        let (_, docs, a, _) = try await documentFixture()
        let doc = try await docs.save(patientId: a, docType: "处方单", sha256: "r1", mimeType: "image/jpeg",
                                      origin: "import", isSensitive: false, metaJSON: nil, title: nil,
                                      docTypeKey: DocumentTypeKey.prescription.rawValue)
        try await docs.updateReview(id: doc, patientId: a, docType: "检查报告", isSensitive: false, metaJSON: nil,
                                    ocrText: nil, grade: "C", pages: [], docTypeKey: DocumentTypeKey.examReport.rawValue)
        var row = try await docs.fetch(id: doc)
        XCTAssertEqual(row?.docType, "检查报告")
        XCTAssertEqual(row?.docTypeKey, "exam_report")
        try await docs.updateReview(id: doc, patientId: a, docType: "检查报告", isSensitive: true, metaJSON: nil,
                                    ocrText: nil, grade: "C", pages: [])
        row = try await docs.fetch(id: doc)
        XCTAssertEqual(row?.docTypeKey, "exam_report", "未传键不动原键")
        XCTAssertEqual(row?.isSensitive, true)
        do {
            try await docs.updateReview(id: doc, patientId: a, docType: "检查报告", isSensitive: false, metaJSON: nil,
                                        ocrText: nil, grade: "C", pages: [], docTypeKey: "not_a_key")
            XCTFail("未知稳定键必须拒绝")
        } catch DocumentStore.StoreError.invalidDocTypeKey {}
    }

    /// BR-001 归属校验（2026-09-16 委员会评审修复）：`recordTakenAt` 此前三个标识
    /// 全部来自调用方参数、计划查询只看 `plan_id + status`——错传成员会**静默扣减
    /// 他人批次**并把分配行记到错成员名下（跨成员医疗数据污染）。修复后：错传即
    /// `doseNotFound`，且**两线余量与分配行分毫不动**。
    /// 原名：test_错传成员补录被拒且不触碰存量
    func test_wrongMemberMakeupRejectedAndStockUntouched() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: shanghaiCalendar.date(byAdding: .day, value: -2, to: Date())!,
                                  endDate: nil)
        let (due, _) = try await seedMissedDose(store: store, meds: meds, planId: planId,
                                                patient: patient, med: med, lot: lot)
        // 错传前存量快照（seedMissedDose 已按 missed 扣减计划轨）
        let before = try await store.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT remaining_plan_units, remaining_confirmed_units FROM stock_lot WHERE id = ?
                """, arguments: [lot.lotId.uuidString])
        }
        // 以**他人**成员身份补录同一计划
        do {
            try await meds.recordTakenAt(planId: planId, patientId: UUID(), medicationId: med,
                                         actualTime: due.addingTimeInterval(5 * 60), doseUnits: 1)
            XCTFail("错传成员的补录必须被拒（doseNotFound）——此前会静默扣减他人批次")
        } catch MedicationStore.StoreError.doseNotFound(_) {
            // 预期路径
        } catch {
            XCTFail("预期 doseNotFound，实际：\(error)")
        }
        // 两线余量分毫不动（错传不留任何痕迹）
        let after = try await store.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT remaining_plan_units, remaining_confirmed_units FROM stock_lot WHERE id = ?
                """, arguments: [lot.lotId.uuidString])
        }
        XCTAssertEqual(after?["remaining_plan_units"] as Double?,
                       before?["remaining_plan_units"] as Double?, "计划轨余量不得因错传变动")
        XCTAssertEqual(after?["remaining_confirmed_units"] as Double?,
                       before?["remaining_confirmed_units"] as Double?, "确认轨余量不得因错传变动")
    }
}
