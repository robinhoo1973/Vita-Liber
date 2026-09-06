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
final class M2Round2RegressionTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, MedicationStore, UUID, UUID) {
        let store = try GRDBStore.inMemory()
        let meds = MedicationStore(writer: store.writer)
        let patient = UUID()
        let med = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '转场测试患者', '本人', 0, 0)
                """, arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, '阿司匹林', '0.1g', 'tablet', 0, 0)
                """, arguments: [med.uuidString, patient.uuidString])
        }
        return (store, meds, patient, med)
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// 种子一条「昨日 08:00」未决议行并补账为 missed（安全线已按计划扣减）。
    private func seedMissedDose(store: GRDBStore, meds: MedicationStore,
                                planId: UUID, patient: UUID, med: UUID,
                                lot: DualTrackInventory) async throws -> (due: Date, units: Double) {
        let units = 1.0
        let due = cal.date(byAdding: .day, value: -1, to: Date())!
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

    /// D3 转场 PK 冲突修复：missed→taken 补录不得因 dose_lot_allocation 主键冲突
    /// 整事务回滚（此前任何持有库存的补录必然失败）；计划轨不重复扣减。
    func test_补录missed转taken_不PK冲突且计划轨不双扣() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: cal.date(byAdding: .day, value: -2, to: Date())!,
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
    func test_晚两小时补录_宽关联转场不双行不双扣() async throws {
        let (store, meds, patient, med) = try await makeStore()
        let lot = DualTrackInventory(lotId: UUID(), totalUnits: 10, unitKind: "tablet")
        try await meds.createLot(lot: lot, patientId: patient, medicationId: med)
        let planId = UUID()
        try await meds.createPlan(planId: planId, patientId: patient, medicationId: med,
                                  schedule: .fixed(times: ["08:00"]), status: .active,
                                  startDate: cal.date(byAdding: .day, value: -2, to: Date())!,
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
    func test_物化窗口幂等且时区重锚不重复建行() async throws {
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
        let first = try await meds.materializeWindow(now: anchor, calendar: cal)
        let again = try await meds.materializeWindow(now: anchor, calendar: cal)
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
    func test_归档收藏组合态可逆() async throws {
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
    func test_定价锚点与spec一致() {
        XCTAssertTrue(L10n.payProYearlyPrice.contains("¥68"),
                      "zh-Hans Pro 年价锚点必须为 ¥68/年（comercial-spec §4.3）")
        XCTAssertTrue(L10n.payProMonthlyPrice.contains("¥12"),
                      "zh-Hans Pro 月价锚点必须为 ¥12/月（comercial-spec §4.3）")
        XCTAssertFalse(L10n.payProYearlyPrice.isEmpty)
        XCTAssertFalse(L10n.payProMonthlyPrice.isEmpty)
        XCTAssertFalse(L10n.payAddonPrice.isEmpty)
    }
}
