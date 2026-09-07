#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import GRDB
import Domain
import Protocols

/// M1b 用药数据仓（actor，GRDB）：
/// - medication / medication_plan / stock_lot / medication_dose_log / dose_lot_allocation 写入
/// - DoseSource 实现：对账输入（active 计划的 pending 剂量 → DoseDeliveryFact）
/// - 双轨扣减与服药确认落库
public actor MedicationStore: DoseSource {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    // MARK: - 计划与批次

    public func createPlan(planId: UUID, patientId: UUID, medicationId: UUID,
                           schedule: MedicationSchedule, status: PlanStatus,
                           startDate: Date, endDate: Date?,
                           doseUnits: Double? = nil) async throws {
        try await writer.write { db in
            let scheduleJSON = String(data: try JSONEncoder().encode(schedule), encoding: .utf8) ?? "{}"
            try db.execute(
                sql: """
                INSERT INTO medication_plan
                  (id, patient_id, medication_id, status, schedule_json, start_date, end_date,
                   dose_plan_units, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [planId.uuidString, patientId.uuidString, medicationId.uuidString,
                            status.rawValue, scheduleJSON, startDate.timeIntervalSince1970,
                            endDate?.timeIntervalSince1970, doseUnits, Date().timeIntervalSince1970,
                            Date().timeIntervalSince1970])
        }
    }

    public func createMedication(id: UUID = UUID(), patientId: UUID, name: String,
                                 spec: String?, unitKind: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO medication (id, patient_id, generic_name, spec, unit_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id.uuidString, patientId.uuidString, name, spec, unitKind,
                            Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    public func createLot(lot: DualTrackInventory, patientId: UUID, medicationId: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO stock_lot
                  (id, patient_id, medication_id, total_units, unit_kind,
                   remaining_plan_units, remaining_confirmed_units, expire_at,
                   status, last_reconciled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [lot.lotId.uuidString, patientId.uuidString, medicationId.uuidString,
                            lot.totalUnits, lot.unitKind, lot.remainingPlanUnits,
                            lot.remainingConfirmedUnits, lot.expireAt?.timeIntervalSince1970,
                            lot.status, Date().timeIntervalSince1970])
        }
    }

    // MARK: - 服药确认（BR-004：确认动作与扣减同事务）

    /// 服药确认「服了」（评审修正 P0：UPDATE 物化行而非插孤儿行——否则动作
    /// 对 deliveryFacts 不可见，已服仍重发、可重复扣减，BR-004 生产链失效）。
    /// 同事务：写 user_action + 按 FR9.8.2 矩阵扣两线 + 写 dose_lot_allocation。
    public func confirmTaken(notifyId: String, patientId: UUID) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT d.id, d.dose_units, d.user_action, p.medication_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE d.id = ?
                """, arguments: [notifyId]) else {
                throw StoreError.doseNotFound(notifyId)
            }
            // 幂等（评审 S0-2）：已决议的行不得重复扣减
            if (row["user_action"] as String?) != nil {
                throw StoreError.alreadyResolved(notifyId)
            }
            let units = (row["dose_units"] as Double?) ?? 1
            let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
            try db.execute(sql: """
                UPDATE medication_dose_log
                SET user_action = 'taken', acted_at = ?
                WHERE id = ?
                """, arguments: [Date().timeIntervalSince1970, notifyId])
            try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                notifyId: notifyId, units: units, action: .taken, db: db)
        }
    }

    /// 跳过/忘记/不适/稍后：UPDATE 物化行 + FR9.8.2 矩阵（skipped 两线均免扣、
    /// missed 仅计划轨扣、discomfort 两线各扣；snoozed 两线不动，稍后由对账重排）。
    /// reason：FR9.5 跳过必选原因/不适备注，落 dose_log.note（如实记录，不美化）。
    public func recordAction(notifyId: String, action: DoseUserAction, reason: String? = nil) async throws {
        guard action != .taken else {
            throw StoreError.takenMustUseConfirm(notifyId)   // §7：不得静默 return
        }
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT d.id, d.dose_units, p.patient_id, p.medication_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE d.id = ?
                """, arguments: [notifyId]) else {
                throw StoreError.doseNotFound(notifyId)
            }
            let units = (row["dose_units"] as Double?) ?? 1
            let patientId = UUID(uuidString: row["patient_id"] as String) ?? UUID()
            let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
            try db.execute(sql: """
                UPDATE medication_dose_log
                SET user_action = ?, acted_at = ?, note = ?
                WHERE id = ?
                """, arguments: [action.rawValue, Date().timeIntervalSince1970, reason, notifyId])
            try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                notifyId: notifyId, units: units, action: action, db: db)
        }
    }

    public enum StoreError: Error, LocalizedError {
        case doseNotFound(String)
        case alreadyResolved(String)
        case takenMustUseConfirm(String)
        case notFound                 // SP-17 updateLot：目标批次不存在（软删竞态/过期删除）
        public var errorDescription: String? { "剂量行操作失败: \(self)" }
    }

    // MARK: - 零确认存活（FR9.8.8 / dev-pm §3.4 M2 一票否决）

    /// **计划驱动补账**：把「已过宽限期、仍无任何用户动作」的剂量行物化为
    /// `.missed`，并只扣**安全线**（FR9.8.2：忘记/无操作 → 安全线−1、确认线 0）。
    ///
    /// 为什么必须单独存在：安全线的推进此前只挂在用户动作上
    /// （`confirmTaken` / `recordAction` → `applyResolutionOnLots`），而「零确认」
    /// 恰恰意味着**永远不会有动作传进来**——安全线于是永不减少、续药提醒永不
    /// 触发。用户建完计划后什么都不做，反而收不到「该买药了」，这正是
    /// FR9.8.8「零确认存活动作条款」要防的失效形态。
    ///
    /// - 幂等：`user_action IS NULL` 守卫，已物化行不重复处理；
    /// - 每行一个事务还是整批一个事务？**整批一个事务**——补账是排程驱动的
    ///   一致性动作，半批提交会让「安全线已扣但行未物化」的中间态可见；
    /// - 宽限语义与对账一致（`isExpiredGrace`：15 分钟），未过宽限的行留给用户。
    @discardableResult
    public func materializeMissed(now: Date, graceInterval: TimeInterval = 15 * 60) async throws -> Int {
        let cutoff = now.addingTimeInterval(-graceInterval)
        return try await writer.write { db -> Int in
            // 目标行：计划 active、已过宽限、无用户动作
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id, d.dose_units, p.patient_id, p.medication_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE p.status = 'active'
                  AND d.user_action IS NULL
                  AND d.scheduled_for < ?
                """, arguments: [cutoff.timeIntervalSince1970])
            var processed = 0
            for row in rows {
                let notifyId = row["id"] as String
                let units = (row["dose_units"] as Double?) ?? 1
                let patientId = UUID(uuidString: row["patient_id"] as String) ?? UUID()
                let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
                try db.execute(sql: """
                    UPDATE medication_dose_log
                    SET user_action = 'missed', acted_at = ?
                    WHERE id = ? AND user_action IS NULL
                    """, arguments: [now.timeIntervalSince1970, notifyId])
                guard db.changesCount > 0 else { continue }   // 并发下已被决议，跳过
                try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                          notifyId: notifyId, units: units,
                                          action: .missed, db: db)
                processed += 1
            }
            return processed
        }
    }

    /// 某计划下已物化的剂量行数（测试/月报用）
    public func doseCount(planId: UUID, from: Date, to: Date) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM medication_dose_log
                WHERE plan_id = ? AND scheduled_for >= ? AND scheduled_for <= ?
                """, arguments: [planId.uuidString,
                                 from.timeIntervalSince1970, to.timeIntervalSince1970]) ?? 0
        }
    }

    // MARK: - 消耗差异月报（FR9.8.5）

    /// 月报输入 = 两线差值，逐日可溯。**纯事实聚合**（V3.68：句式由 App 层
    /// 经 L10n.inventoryMonthlyReportFmt 渲染，Domain 只出数值；禁止任何
    /// 评价/评分句式，负清单由 `InventoryReportRules.violation` 一票否决）。
    public func monthlyReport(patientId: UUID, from: Date, to: Date) async throws -> InventoryMonthlyReport {
        try await writer.read { db in
            let counts = try Row.fetchOne(db, sql: """
                SELECT
                  COUNT(*) AS planned,
                  -- discomfort 与 taken 同属「服用事实成立」（FR9.8.2 扣减矩阵：两线各扣），
                  -- 因此必须计入确认桶。此前归入 missed 会让 FR9.8.5 两线差异报告
                  -- 与库存台账对同一剂量给出相反口径。
                  SUM(CASE WHEN user_action IN ('taken','discomfort') THEN 1 ELSE 0 END) AS confirmed,
                  SUM(CASE WHEN user_action = 'skipped' THEN 1 ELSE 0 END) AS skipped,
                  SUM(CASE WHEN user_action IS NULL OR user_action = 'missed'
                      THEN 1 ELSE 0 END) AS missed
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                WHERE p.patient_id = ? AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                  AND p.status = 'active'
                """, arguments: [patientId.uuidString,
                                 from.timeIntervalSince1970, to.timeIntervalSince1970])
            return InventoryReportRules.report(
                periodStart: from, periodEnd: to,
                planned: Int(counts?["planned"] as Int64? ?? 0),
                confirmed: Int(counts?["confirmed"] as Int64? ?? 0),
                skipped: Int(counts?["skipped"] as Int64? ?? 0),
                missed: Int(counts?["missed"] as Int64? ?? 0))
        }
    }

    // MARK: - 家庭药箱摘要（FR9.8.3 续药卡 / FR9.8.7「约剩 N 天」）

    /// 批次级摘要：安全线剩余 + 确认线剩余 + 当前续药档位 + 诚实性天数估算。
    /// `约剩 N 天·按计划估算` 的 N 来自**安全线 ÷ 计划日当量**（向上取整不实——
    /// 诚实性文案要求「约」，故保留一位小数取整向上，绝不精确到小时装精确）。
    public func inventorySummary(patientId: UUID, now: Date) async throws -> [InventorySummaryItem] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.medication_id, m.generic_name, m.spec, l.total_units,
                       l.unit_kind, l.remaining_plan_units, l.remaining_confirmed_units,
                       l.expire_at, l.status, l.storage_note
                FROM stock_lot l
                JOIN medication m ON m.id = l.medication_id
                WHERE l.patient_id = ? AND l.status = 'active'
                ORDER BY m.generic_name, l.expire_at
                """, arguments: [patientId.uuidString])
            var items: [InventorySummaryItem] = []
            // 第四轮全仓审查效率修复（5WHY）：原实现每个批次行内嵌套查该药的
            // schedule_json（N+1）且每次解码新建 JSONDecoder——首页续药卡热路径
            // 随批次×计划数线性劣化。解码器提到循环外复用；同药的 schedule 按
            // medicationId 缓存（同药多批次常见）。语义不变。
            let decoder = JSONDecoder()
            var dailyCache: [String: Double] = [:]
            for row in rows {
                // 日当量：active 计划的 schedule_json 在 Swift 侧解码估算——
                // 枚举 JSON 形态多样（fixed/interval/meal/…），SQL JSON1 路径
                // 会静默失配，宁可多写几行解码也不把「约剩 N 天」建在静默失效上。
                let medicationId = row["medication_id"] as String
                let daily: Double
                if let cached = dailyCache[medicationId] {
                    daily = cached
                } else {
                    let schedules = try String.fetchAll(db, sql: """
                        SELECT schedule_json FROM medication_plan
                        WHERE medication_id = ? AND status = 'active'
                        """, arguments: [medicationId])
                    var total = 0.0
                    for json in schedules {
                        guard let data = json.data(using: .utf8) else { continue }
                        // 损坏的 schedule_json 跳过该计划（与 materializeWindow 同语义；
                        // 不用 try? —— tech-spec §7 红线）
                        let schedule: MedicationSchedule
                        do { schedule = try decoder.decode(MedicationSchedule.self, from: data) }
                        catch { continue }
                        total += Self.estimatedDailyUnits(schedule)
                    }
                    dailyCache[medicationId] = total
                    daily = total
                }
                let planUnits = row["remaining_plan_units"] as Double
                let confirmedUnits = row["remaining_confirmed_units"] as Double
                var inv = DualTrackInventory(lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                                             totalUnits: row["total_units"] as Double,
                                             unitKind: row["unit_kind"] as String,
                                             expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
                inv.remainingPlanUnits = planUnits
                inv.remainingConfirmedUnits = confirmedUnits
                let tier = InventoryRules.refillTier(inv, dailyPlanUnits: daily, at: now)
                items.append(InventorySummaryItem(
                    lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    unitKind: row["unit_kind"] as String,
                    remainingPlanUnits: planUnits,
                    remainingConfirmedUnits: confirmedUnits,
                    expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    storageNote: row["storage_note"] as String?,
                    approxDaysLeft: daily > 0 ? Int(ceil(planUnits / daily)) : nil,
                    refillTier: tier))
            }
            return items
        }
    }

    /// SP-17 批次详情行（FR9.10 档案完整字段 + FR9.8 双轨库存口径）
    public struct LotRow: Sendable, Equatable, Identifiable {
        public var lotId: UUID
        public var medicationName: String
        public var spec: String?
        public var unitKind: String
        public var totalUnits: Double
        public var remainingPlanUnits: Double
        public var remainingConfirmedUnits: Double
        public var openedAt: Date?
        public var expireAt: Date?
        public var storageNote: String?
        public var status: String
        public var lastReconciledAt: Date
        public var id: UUID { lotId }
        public init(lotId: UUID, medicationName: String, spec: String?, unitKind: String,
                    totalUnits: Double, remainingPlanUnits: Double, remainingConfirmedUnits: Double,
                    openedAt: Date?, expireAt: Date?, storageNote: String?, status: String,
                    lastReconciledAt: Date) {
            self.lotId = lotId; self.medicationName = medicationName; self.spec = spec
            self.unitKind = unitKind; self.totalUnits = totalUnits
            self.remainingPlanUnits = remainingPlanUnits
            self.remainingConfirmedUnits = remainingConfirmedUnits
            self.openedAt = openedAt; self.expireAt = expireAt
            self.storageNote = storageNote; self.status = status
            self.lastReconciledAt = lastReconciledAt
        }
    }

    /// SP-17 批次详情单行投影（药箱行 → 详情页；含已过期/废弃批次——详情页
    /// 按状态分组展示，列表只出 active）
    public func fetchLot(id: UUID) async throws -> LotRow? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT l.*, m.generic_name, m.spec
                FROM stock_lot l JOIN medication m ON m.id = l.medication_id
                WHERE l.id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return LotRow(lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                          medicationName: row["generic_name"] as String,
                          spec: row["spec"] as String?,
                          unitKind: row["unit_kind"] as String,
                          totalUnits: row["total_units"] as Double,
                          remainingPlanUnits: row["remaining_plan_units"] as Double,
                          remainingConfirmedUnits: row["remaining_confirmed_units"] as Double,
                          openedAt: (row["opened_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                          expireAt: (row["expire_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                          storageNote: row["storage_note"] as String?,
                          status: row["status"] as String,
                          lastReconciledAt: Date(timeIntervalSince1970: row["last_reconciled_at"] as Double))
        }
    }

    /// SP-17 批次编辑写回：表单预填当前值后全字段 SET（效期/位置可清空=未知，
    /// 清空项进批次补录待办 FR9.10）。
    public func updateLot(id: UUID, totalUnits: Double, unitKind: String,
                          openedAt: Date?, expireAt: Date?, storageNote: String?,
                          status: String, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE stock_lot SET total_units = ?, unit_kind = ?, opened_at = ?,
                  expire_at = ?, storage_note = ?, status = ?
                WHERE id = ?
                """, arguments: [totalUnits, unitKind, openedAt?.timeIntervalSince1970,
                                 expireAt?.timeIntervalSince1970, storageNote, status,
                                 id.uuidString])
            guard db.changesCount > 0 else {
                throw StoreError.notFound
            }
        }
    }

    /// 盘点归真（FR9.8.5 往返）：写入**用户确认后的**实物清点，两线同时重置为
    /// 物理真值 + 记审计。归真必须显式调用且经确认（Domain 侧 `needsConfirmation`
    /// 已判差异非零），本方法不自行裁决差异——裁决发生在调用方确认之后。
    public func reconcileLot(lotId: UUID, physicalCount: Double, at: Date,
                             note: String? = nil, auditSink: ((String, String) async throws -> Void)? = nil) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE stock_lot
                SET remaining_plan_units = ?, remaining_confirmed_units = ?,
                    last_reconciled_at = ?
                WHERE id = ?
                """, arguments: [physicalCount, physicalCount, at.timeIntervalSince1970,
                                 lotId.uuidString])
            guard db.changesCount > 0 else {
                throw StoreError.doseNotFound(lotId.uuidString)
            }
            // 审查修复：审计与业务同事务（对齐「审计不落半条」纪律）——
            // 原实现提交后才经 async auditSink 写审计，审计失败即留下
            // 无审计的库存归真记录。事务内直落 audit_event（与
            // AuditLogWriter 同表同列），entity_id_hash 脱敏与 writer 一致。
            // ADR-025：哈希走 CryptoKit；§5.6 日志最小化：meta 只记事实计数，
            // 不记用户自由文本备注（医疗内容不入审计表）
            if auditSink != nil {
                let hex = CryptoKitContentHasher().sha256Hex(Data(lotId.uuidString.utf8))
                try db.execute(sql: """
                    INSERT INTO audit_event (id, actor_local, action, entity_type, entity_id_hash, at, meta_json)
                    VALUES (?, 'local', 'inventory.reconcile', 'stock_lot', ?, ?, ?)
                    """, arguments: [UUID().uuidString, hex, at.timeIntervalSince1970,
                                     "count=\(physicalCount)"])
            }
        }
    }

    /// 日均当量估算（FR9.8.7「约剩 N 天·按计划估算」）。诚实性纪律：
    /// 只作「约」字号的估算，且对多计划取**最大值**（保守——宁可估算天数更少，
    /// 也不让用户以为药比实际多）。asNeeded 无排程，不计入日当量。
    static func estimatedDailyUnits(_ schedule: MedicationSchedule) -> Double {
        switch schedule {
        case .fixed(let times): return Double(max(1, times.count))
        case .interval(let everyMinutes, _):
            // 评审修正 D4：原 min(perDay, 24) 上限把亚小时间隔（如每 30 分钟）
            // 的日消耗砍半 → daysLeft 虚高、续药分级晚发（ADR-009 反方向）。
            // 上限无规格依据（FR9.4 对间隔无下限），删除之。
            return 1440.0 / Double(max(1, everyMinutes))
        case .meal(let relations): return Double(max(1, relations.count))
        case .asNeeded: return 0
        case .cycle(let everyDays, let daysOn): return Double(daysOn) / Double(max(1, everyDays))
        case .taper(let stages):
            // 未来段不确定，取各阶段日当量最大值（保守）
            return stages.map { Double($0.times.count) * $0.doseUnits }.max() ?? 1
        }
    }

    public struct InventorySummaryItem: Sendable, Equatable, Identifiable {
        public var lotId: UUID
        public var medicationName: String
        public var spec: String?
        public var unitKind: String
        public var id: UUID { lotId }
        public var remainingPlanUnits: Double
        public var remainingConfirmedUnits: Double
        public var expireAt: Date?
        /// 存放位置（FR9.10：未知/空 → 进入批次补录待办队列）
        public var storageNote: String?
        /// 约剩 N 天·按计划估算（FR9.8.7）；无 active 计划时为 nil（不装精确）
        public var approxDaysLeft: Int?
        public var refillTier: InventoryRules.RefillTier?
        public init(lotId: UUID, medicationName: String, spec: String?, unitKind: String,
                    remainingPlanUnits: Double, remainingConfirmedUnits: Double,
                    expireAt: Date?, storageNote: String? = nil,
                    approxDaysLeft: Int?, refillTier: InventoryRules.RefillTier?) {
            self.lotId = lotId; self.medicationName = medicationName; self.spec = spec
            self.unitKind = unitKind; self.remainingPlanUnits = remainingPlanUnits
            self.remainingConfirmedUnits = remainingConfirmedUnits; self.expireAt = expireAt
            self.storageNote = storageNote
            self.approxDaysLeft = approxDaysLeft; self.refillTier = refillTier
        }
    }

    // MARK: - 滚动预排窗口（§5.4：只物化未来 7 天，每日对账滚动补排）

    /// 为全部 active 计划物化窗口内剂量行（幂等）。dose_log.plan_id 必须指向真实
    /// 计划——否则 DoseSource.deliveryFacts 的 JOIN 恒空，提醒链断裂。
    /// 评审修正 P0：窗口日界必须以 now 为锚——fromDay 硬编码 1 会让开立超过
    /// 7 天的老计划全部生成在过去被过滤，inserted=0 永不再物化。
    /// 评审修正 D2（零确认离线缺口）：窗口回溯 30 个计划日——应用关闭超过
    /// 预排窗口时，缺口剂量从未物化过，materializeMissed 只改已有行、对缺口
    /// 无能为力 → 安全线冻结、续药告警晚发（ADR-009 反方向）。回溯行由紧随其
    /// 后的 materializeMissed 决议为 missed（计划轨按计划推进），幂等。
    /// 评审修正 D5（时区重锚）：notifyId 为逻辑身份（day+ordinal），时区变化后
    /// 同一逻辑剂量以新墙钟重排——未决议行 ON CONFLICT 更新 scheduled_for/
    /// dose_units 重锚到新时区；已决议行不动（用户动作是事实，绝不改写）。
    /// 返回本窗口新物化的行数。
    public func materializeWindow(now: Date, calendar: Calendar) async throws -> Int {
        let windowEnd = DayArithmetic.offset(days: ReconcileEngine.preScheduleWindowDays, from: now)
        let lookbackStart = DayArithmetic.offset(days: -30, from: now)
        // 返回式写闭包：不在闭包内突变捕获变量（Swift 6 并发纪律——
        // 「mutation of captured var in concurrently-executing code」是 6 模式下的错误）
        return try await writer.write { db -> Int in
            var inserted = 0
            let plans = try Row.fetchAll(db, sql: """
                SELECT id, patient_id, schedule_json, start_date, end_date, dose_plan_units, created_at
                FROM medication_plan WHERE status = 'active'
                """)
            for plan in plans {
                let planId = UUID(uuidString: plan["id"] as String) ?? UUID()
                let startDate = Date(timeIntervalSince1970: plan["start_date"] as Double)
                let endDate = (plan["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) }
                guard let json = (plan["schedule_json"] as String?)?.data(using: .utf8) else { continue }
                let schedule: MedicationSchedule
                do { schedule = try JSONDecoder().decode(MedicationSchedule.self, from: json) }
                catch { continue }   // 损坏的 schedule_json 跳过该计划（§7 禁 try?）
                // 评审修正 D1：每剂剂量读 dose_plan_units（安全线单剂基线）——
                // 此前引擎硬编码 1.0，每次 2 片的计划扣减恒按 1 片 → 告警晚发。
                // 上限钳制（评审修正第二轮）：旧 MedicationPlanComposer 曾把整盒
                // 数量误写本列（v16 已归一 NULL），读取侧再钳一次防越界输入。
                let unitsPerDose = min((plan["dose_plan_units"] as Double?) ?? 1, 100)
                // 以 now 锚定日界：计划期第 N 天 = startDate 后第 N-1 天
                let dayOfPlan = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                                        to: calendar.startOfDay(for: now)).day ?? 0
                // D2：回溯 30 计划日补齐缺口（封顶计划起始日）
                let fromDay = max(1, dayOfPlan - 30)
                let toDay = max(1, dayOfPlan) + ReconcileEngine.preScheduleWindowDays
                let (doses, _) = DoseScheduleEngine.doses(
                    schedule: schedule, planId: planId, startDate: startDate,
                    fromDay: fromDay, toDay: toDay, calendar: calendar,
                    unitsPerDose: unitsPerDose)
                // 评审修正第二轮（回溯物化回归）：30 日回溯只服务「App 关闭超窗」
                // 缺口——**新建计划**若把 startDate 回填到创建日之前，回溯会把
                // 历史日期全量物化并立即决议 missed（安全线瞬间崩塌 + 假续药告警 +
                // 月报幻影漏服）。计划创建前的剂量一律不物化。
                let createdDate = Date(timeIntervalSince1970: plan["created_at"] as Double)
                for d in doses {
                    guard d.dueAt >= lookbackStart && d.dueAt <= windowEnd else { continue }
                    guard d.dueAt >= createdDate.addingTimeInterval(-60) else { continue }
                    if let end = endDate, d.dueAt > DayArithmetic.offset(days: 1, from: end) { continue }   // 到期次日不物化
                    // D5 守卫（评审修正第二轮加固）：同一计划、±30min 容差内已有
                    // **决议行**（旧 epoch id 的历史行/补录行）则不重复建行——
                    // 否则迁移后回溯物化会把已服剂量再建一行并决议 missed，
                    // 计划轨双扣、月报双计。窗口与 DoseSlotGrouping.tolerance
                    // 单一事实源对齐（原 ±60s 在时区/DST 偏移下漏守卫）。
                    // BETWEEN 化（原 ABS() 非 sargable）：idx_dose_log_plan_time 生效。
                    // 同时段未决议行走 ON CONFLICT 重锚；等值行不再重写（写放大防护）。
                    let guardFrom = d.dueAt.timeIntervalSince1970 - DoseSlotGrouping.tolerance
                    let guardTo = d.dueAt.timeIntervalSince1970 + DoseSlotGrouping.tolerance
                    try db.execute(
                        sql: """
                        INSERT INTO medication_dose_log (id, plan_id, scheduled_for, dose_units, delivery_state, user_action)
                        SELECT ?, ?, ?, ?, 'planned', NULL
                        WHERE NOT EXISTS (
                          SELECT 1 FROM medication_dose_log e
                          WHERE e.plan_id = ? AND e.user_action IS NOT NULL
                            AND e.scheduled_for BETWEEN ? AND ?
                        )
                        ON CONFLICT(id) DO UPDATE SET
                          scheduled_for = excluded.scheduled_for,
                          dose_units = excluded.dose_units
                        WHERE user_action IS NULL
                          AND (scheduled_for != excluded.scheduled_for
                               OR dose_units != excluded.dose_units)
                        """,
                        arguments: [d.notifyId, planId.uuidString, d.dueAt.timeIntervalSince1970,
                                    d.doseUnits, planId.uuidString, guardFrom, guardTo])
                    inserted += db.changesCount
                }
            }
            return inserted
        }
    }

    // MARK: - DoseSource（对账输入）

    public func deliveryFacts(from: Date, to: Date) async throws -> [DoseDeliveryFact] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id AS dose_id, d.scheduled_for, d.dose_units, d.user_action, d.delivery_state,
                       m.generic_name, m.spec, m.unit_kind, p.patient_id
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                JOIN medication m ON m.id = p.medication_id
                WHERE p.status = 'active' AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
            return rows.map { row in
                let scheduledFor = Date(timeIntervalSince1970: row["scheduled_for"] as Double)
                let action = (row["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:))
                return DoseDeliveryFact(
                    dose: ScheduledDose(dueAt: scheduledFor,
                                        doseUnits: (row["dose_units"] as Double?) ?? 1,
                                        notifyId: row["dose_id"] as String),
                    delivered: (row["delivery_state"] as String) == "delivered",
                    action: action,
                    isDueSoon: scheduledFor <= from.addingTimeInterval(DoseSlotGrouping.tolerance),   // ±30min 单一事实源（DoseSlot 聚合容差）
                    isExpiredGrace: scheduledFor < from.addingTimeInterval(-15 * 60),
                    medicationName: row["generic_name"] as String?,
                    spec: row["spec"] as String?,
                    unitKind: row["unit_kind"] as String?,
                    patientId: (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)))
            }
        }
    }

    public func markAwaitingUser(_ notifyId: String) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE medication_dose_log SET delivery_state = 'delivered'
                WHERE id = ?
                """, arguments: [notifyId])
        }
    }

    // MARK: - FR9.16 补录/追溯服药（落到实际发生时间，如实记录，不引入「补服」特殊态）

    /// 补记「已服用」：错过的时段可在过后补录，落在**实际发生时间**并如实记录。
    /// 双轨按 FR9.8.2 矩阵各 −1（taken）；计划历史如实呈现补录时间点，不美化。
    /// 评审修正 D3：先按计划+时间容差解析既有物化行——materializeMissed 可能已
    /// 把同一逻辑剂量决议为 missed（计划轨已 −units）；直接 INSERT 新行再按
    /// taken 扣减 = 计划轨双扣（安全线虚低、月报双计）。转场修正：
    /// missed→taken 仅补扣确认轨（Domain InventoryRules.transitionDeduction）。
    /// 若该时段已有物化行 → UPDATE 该行；否则 INSERT 新行（补录本身即证据）。
    public func recordTakenAt(planId: UUID, patientId: UUID, medicationId: UUID,
                              actualTime: Date, doseUnits: Double = 1,
                              notifyId: String = UUID().uuidString) async throws {
        try await writer.write { db in
            guard let plan = try Row.fetchOne(db, sql: """
                SELECT id, schedule_json, start_date, dose_plan_units
                FROM medication_plan WHERE id = ? AND status = 'active'
                """, arguments: [planId.uuidString]) else {
                throw StoreError.doseNotFound(planId.uuidString)
            }
            // 时段解析：同一计划、±30min 容差内的既有物化行（DoseSlotGrouping.tolerance 单一事实源）
            let tolerance = DoseSlotGrouping.tolerance
            let existing = try Row.fetchOne(db, sql: """
                SELECT id, user_action, dose_units FROM medication_dose_log
                WHERE plan_id = ? AND scheduled_for BETWEEN ? AND ?
                ORDER BY ABS(scheduled_for - ?) LIMIT 1
                """, arguments: [planId.uuidString,
                                 actualTime.timeIntervalSince1970 - tolerance,
                                 actualTime.timeIntervalSince1970 + tolerance,
                                 actualTime.timeIntervalSince1970])
            if let existing {
                let existingAction = (existing["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:))
                let existingUnits = (existing["dose_units"] as Double?) ?? doseUnits
                switch existingAction {
                case .taken, .discomfort:
                    throw StoreError.alreadyResolved(existing["id"] as String)
                default:
                    break
                }
                let existingId = existing["id"] as String
                // 转场扣减：missed → taken 仅确认轨补扣；未决议 → 全额 taken
                let matrix = InventoryRules.transitionDeduction(
                    from: existingAction, to: .taken, units: existingUnits)
                try db.execute(sql: """
                    UPDATE medication_dose_log
                    SET user_action = 'taken', acted_at = ?, note = 'backfill', dose_units = ?
                    WHERE id = ?
                    """, arguments: [actualTime.timeIntervalSince1970, existingUnits, existingId])
                try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                          notifyId: existingId, units: existingUnits,
                                          action: .taken, transitionMatrix: matrix, db: db)
                return
            }
            // 评审修正第二轮（宽关联转场）：±30min 内无既有行时，补录实际时刻
            // 常落在排程容差之外（如晚 2 小时补记）——若直接 INSERT 随机 id 新行，
            // 已被 materializeMissed 决议 missed 的原行留在原地（计划轨已扣），
            // 新行再按 taken 全额扣减 = 计划轨双扣（ADR-009 反方向）。
            // 宽窗口（±12h）内优先找 missed/snoozed/skipped/未决议行 → 转场该行；
            // 找不到才 INSERT 新行（补录本身即证据）。
            // 第八轮全仓审查修复（宽窗口幂等）：原查询把 taken/discomfort 排除
            // 在外——同一逻辑剂量二次补录（首次已决 taken）在宽窗口内找不到
            // 任何行 → INSERT 重复行并再按 taken 全额扣减双轨。改为「非 taken/
            // discomfort 优先」，仅当窗口内全部行均已决为 taken/discomfort 时
            // 才命中该行并抛 alreadyResolved（与窄路径同款响亮拒绝）。
            let wideWindow: TimeInterval = 12 * 3600
            if let wide = try Row.fetchOne(db, sql: """
                SELECT id, user_action, dose_units FROM medication_dose_log
                WHERE plan_id = ? AND scheduled_for BETWEEN ? AND ?
                ORDER BY CASE WHEN user_action IN ('taken','discomfort') THEN 1 ELSE 0 END,
                         ABS(scheduled_for - ?) LIMIT 1
                """, arguments: [planId.uuidString,
                                 actualTime.timeIntervalSince1970 - wideWindow,
                                 actualTime.timeIntervalSince1970 + wideWindow,
                                 actualTime.timeIntervalSince1970]) {
                let wideAction = (wide["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:))
                // 第八轮全仓审查修复（宽窗口幂等）：窄窗口（±30min）对 taken/
                // discomfort 抛 alreadyResolved（响亮拒绝），宽窗口（±12h）却
                // 把这些决议态排除在查询外——同一逻辑剂量二次补录时 INSERT
                // 重复行并再按 taken 全额扣减双轨（月报 confirmed 计二）。宽
                // 窗口命中的 taken/discomfort 行按窄路径同款语义拒绝（幂等）。
                if wideAction == .taken || wideAction == .discomfort {
                    throw StoreError.alreadyResolved(wide["id"] as String)
                }
                let wideUnits = (wide["dose_units"] as Double?) ?? doseUnits
                let wideId = wide["id"] as String
                let matrix = InventoryRules.transitionDeduction(
                    from: wideAction, to: .taken, units: wideUnits)
                try db.execute(sql: """
                    UPDATE medication_dose_log
                    SET user_action = 'taken', acted_at = ?, note = 'backfill', dose_units = ?
                    WHERE id = ?
                    """, arguments: [actualTime.timeIntervalSince1970, wideUnits, wideId])
                try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                          notifyId: wideId, units: wideUnits,
                                          action: .taken, transitionMatrix: matrix, db: db)
                return
            }
            // 无既有行：补录落在可排程时段内时复用**逻辑剂量 id**（D5 同源）——
            // 后续物化窗口 ON CONFLICT 命中已决议行，绝不重复建行/双扣；
            // 排程外（asNeeded 等）回落调用方 id（补录本身即证据）。
            var backfillId = notifyId
            if let json = (plan["schedule_json"] as String?)?.data(using: .utf8) {
                let decoded: MedicationSchedule?
                do { decoded = try JSONDecoder().decode(MedicationSchedule.self, from: json) }
                catch { decoded = nil }   // 损坏的 schedule_json：回落调用方 id（§7 禁 try?）
                if let schedule = decoded {
                    let startDate = Date(timeIntervalSince1970: plan["start_date"] as Double)
                    let unitsPerDose = min((plan["dose_plan_units"] as Double?) ?? doseUnits, 100)
                    if let logical = Self.logicalDose(
                        forPlan: planId, schedule: schedule, startDate: startDate,
                        at: actualTime, unitsPerDose: unitsPerDose, tolerance: tolerance) {
                        backfillId = logical.notifyId
                    }
                }
            }
            try db.execute(sql: """
                INSERT INTO medication_dose_log (id, plan_id, scheduled_for, dose_units, delivery_state, user_action, acted_at, note)
                VALUES (?, ?, ?, ?, 'delivered', 'taken', ?, 'backfill')
                ON CONFLICT(id) DO UPDATE SET user_action = 'taken', acted_at = excluded.acted_at
                """, arguments: [backfillId, planId.uuidString, actualTime.timeIntervalSince1970,
                                 doseUnits, actualTime.timeIntervalSince1970])
            try applyResolutionOnLots(patientId: patientId, medicationId: medicationId,
                                      notifyId: backfillId, units: doseUnits, action: .taken, db: db)
        }
    }

    /// 补录时段 → 逻辑剂量身份（D5）：在 actualTime 前后 1 个计划日窗口内
    /// 枚举排程，取 ±30min 容差内最近的 ScheduledDose；无匹配（asNeeded/窗口外）返回 nil。
    private static func logicalDose(forPlan planId: UUID, schedule: MedicationSchedule,
                                    startDate: Date, at time: Date, unitsPerDose: Double,
                                    tolerance: TimeInterval) -> ScheduledDose? {
        let calendar = Calendar.current
        let dayOf = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate),
                                            to: calendar.startOfDay(for: time)).day ?? 0
        let fromDay = max(1, dayOf - 1)
        let (doses, _) = DoseScheduleEngine.doses(
            schedule: schedule, planId: planId, startDate: startDate,
            fromDay: fromDay, toDay: fromDay + 2, calendar: calendar,
            unitsPerDose: unitsPerDose)
        guard let nearest = doses.min(by: {
            abs($0.dueAt.timeIntervalSince(time)) < abs($1.dueAt.timeIntervalSince(time))
        }), abs(nearest.dueAt.timeIntervalSince(time)) <= tolerance else { return nil }
        return nearest
    }

    // MARK: - FR9.11 批次有效期分级提醒（30/7/当日三级；阈值可自定义更短窗口）

    /// 窗口内到期的活跃批次（默认 30 天，FR9.11 三级通知的数据源）。
    /// 过期批次不在此列——它们已被排除出可用库存（applyResolutionOnLots 过滤）。
    public func expiringLots(patientId: UUID, within days: Int = 30, now: Date = Date())
        async throws -> [InventorySummaryItem] {
        let window = DayArithmetic.offset(days: days, from: now)
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.medication_id, m.generic_name, m.spec, l.total_units,
                       l.unit_kind, l.remaining_plan_units, l.remaining_confirmed_units,
                       l.expire_at, l.status
                FROM stock_lot l
                JOIN medication m ON m.id = l.medication_id
                WHERE l.patient_id = ? AND l.status = 'active'
                  AND l.expire_at IS NOT NULL AND l.expire_at <= ?
                ORDER BY l.expire_at
                """, arguments: [patientId.uuidString, window.timeIntervalSince1970])
            return rows.map { row in
                InventorySummaryItem(
                    lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    unitKind: row["unit_kind"] as String,
                    remainingPlanUnits: row["remaining_plan_units"] as Double,
                    remainingConfirmedUnits: row["remaining_confirmed_units"] as Double,
                    expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    approxDaysLeft: nil, refillTier: nil)
            }
        }
    }

    // MARK: - FR9.15/FR9.16 计划查询投影（详情页/日程条/补记）

    public struct PlanRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var medicationId: UUID
        public var medicationName: String
        public var spec: String?
        public var status: String
        public var schedule: MedicationSchedule
        public var startDate: Date
        public var endDate: Date?
        /// 审查修复：schedule_json 损坏时的可见降级标记——原实现静默 nil，
        /// 计划从 UI 消失不可管理，但物化 dose_log 仍被对账引擎继续提醒
        /// （不可见、不可停的提醒源）。UI 据此渲染「计划数据损坏」降级态。
        public var isUnreadable: Bool
        /// 每剂剂量（dose_plan_units，评审修正 D1）——补录/详情按计划单剂基线扣减
        public var dosePlanUnits: Double?
        public init(id: UUID, patientId: UUID, medicationId: UUID, medicationName: String,
                    spec: String?, status: String, schedule: MedicationSchedule,
                    startDate: Date, endDate: Date?, isUnreadable: Bool = false,
                    dosePlanUnits: Double? = nil) {
            self.id = id; self.patientId = patientId; self.medicationId = medicationId
            self.medicationName = medicationName; self.spec = spec; self.status = status
            self.schedule = schedule; self.startDate = startDate; self.endDate = endDate
            self.isUnreadable = isUnreadable
            self.dosePlanUnits = dosePlanUnits
        }
    }

    public struct DoseLogRow: Sendable, Equatable, Identifiable {
        public var notifyId: String
        public var scheduledFor: Date
        public var doseUnits: Double
        public var action: DoseUserAction?
        public var actedAt: Date?
        public var note: String?
        public var id: String { notifyId }
        public init(notifyId: String, scheduledFor: Date, doseUnits: Double,
                    action: DoseUserAction?, actedAt: Date?, note: String?) {
            self.notifyId = notifyId; self.scheduledFor = scheduledFor
            self.doseUnits = doseUnits; self.action = action
            self.actedAt = actedAt; self.note = note
        }
    }

    /// 成员的全部计划（SP-15 列表/详情数据源）
    public func plans(patientId: UUID) async throws -> [PlanRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.patient_id, p.medication_id, p.status, p.schedule_json,
                       p.start_date, p.end_date, p.dose_plan_units, m.generic_name, m.spec
                FROM medication_plan p
                JOIN medication m ON m.id = p.medication_id
                WHERE p.patient_id = ?
                ORDER BY p.status = 'active' DESC, p.start_date DESC
                """, arguments: [patientId.uuidString])
            return rows.map { row in
                let id = UUID(uuidString: row["id"] as String) ?? UUID()
                let patientId = UUID(uuidString: row["patient_id"] as String) ?? UUID()
                let medicationId = UUID(uuidString: row["medication_id"] as String) ?? UUID()
                let medicationName = row["generic_name"] as String
                let spec = row["spec"] as String?
                let status = row["status"] as String
                let startDate = Date(timeIntervalSince1970: row["start_date"] as Double)
                let endDate = (row["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) }
                let schedule: MedicationSchedule
                var unreadable = false
                if let json = (row["schedule_json"] as String?)?.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(MedicationSchedule.self, from: json) { // try?-ok: 解码失败走可见降级行（不静默消失）
                    schedule = decoded
                } else {
                    schedule = .fixed(times: [])
                    unreadable = true
                }
                return PlanRow(id: id, patientId: patientId, medicationId: medicationId,
                               medicationName: medicationName, spec: spec, status: status,
                               schedule: schedule, startDate: startDate, endDate: endDate,
                               isUnreadable: unreadable,
                               dosePlanUnits: row["dose_plan_units"] as Double?)
            }
        }
    }

    public func plan(id: UUID) async throws -> PlanRow? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.id, p.patient_id, p.medication_id, p.status, p.schedule_json,
                       p.start_date, p.end_date, p.dose_plan_units, m.generic_name, m.spec
                FROM medication_plan p
                JOIN medication m ON m.id = p.medication_id
                WHERE p.id = ?
                """, arguments: [id.uuidString]) else { return nil }
            let schedule: MedicationSchedule
            var unreadable = false
            if let json = (row["schedule_json"] as String?)?.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(MedicationSchedule.self, from: json) { // try?-ok: 解码失败走可见降级行（不静默消失）
                schedule = decoded
            } else {
                schedule = .fixed(times: [])
                unreadable = true
            }
            return PlanRow(
                id: UUID(uuidString: row["id"] as String) ?? UUID(),
                patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                medicationId: UUID(uuidString: row["medication_id"] as String) ?? UUID(),
                medicationName: row["generic_name"] as String,
                spec: row["spec"] as String?,
                status: row["status"] as String,
                schedule: schedule,
                startDate: Date(timeIntervalSince1970: row["start_date"] as Double),
                endDate: (row["end_date"] as Double?).map { Date(timeIntervalSince1970: $0) },
                isUnreadable: unreadable,
                dosePlanUnits: row["dose_plan_units"] as Double?)
        }
    }

    /// 计划剂量日志（FR9.16 日程条：本周七日格，已服实心✓/漏服空心!/未来灰）
    public func doseLog(planId: UUID, from: Date, to: Date) async throws -> [DoseLogRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, scheduled_for, dose_units, user_action, acted_at, note
                FROM medication_dose_log
                WHERE plan_id = ? AND scheduled_for >= ? AND scheduled_for <= ?
                ORDER BY scheduled_for
                """, arguments: [planId.uuidString, from.timeIntervalSince1970, to.timeIntervalSince1970])
            .map { row in
                DoseLogRow(
                    notifyId: row["id"] as String,
                    scheduledFor: Date(timeIntervalSince1970: row["scheduled_for"] as Double),
                    doseUnits: (row["dose_units"] as Double?) ?? 1,
                    action: (row["user_action"] as String?).flatMap(DoseUserAction.init(rawValue:)),
                    actedAt: (row["acted_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    note: row["note"] as String?)
            }
        }
    }

    // MARK: - FR9.9 药品知识卡数据源（医嘱原文经 stock_lot→prescription 关联）

    /// 药品的医嘱原文（知识卡「医生医嘱」来源徽章 A/C）。
    /// 处方与药品无直接外键，经 stock_lot.prescription_id 关联取最近一条。
    public func adviceForMedication(medicationId: UUID) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT rx.advice_text FROM prescription rx
                JOIN stock_lot l ON l.prescription_id = rx.id
                WHERE l.medication_id = ? AND rx.advice_text IS NOT NULL AND rx.advice_text != ''
                ORDER BY rx.prescribed_at DESC LIMIT 1
                """, arguments: [medicationId.uuidString])
        }
    }

    // MARK: - FR9.18 送达记录（channel 字段供诊断/审计/差异分析）

    /// 记一条送达事实（FR9.7 扩展：channel 字段）。
    /// 记录的是「经哪个通道触达」，与用户确认状态完全分离（BR-004）。
    public func recordDelivery(notifyId: String, doseLogId: String?, channel: ReminderChannelKind,
                               outcome: String? = nil, at: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO notification_delivery (id, dose_log_id, scheduled_at, delivered_at, channel, outcome, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [notifyId, doseLogId, at.timeIntervalSince1970,
                                 outcome == "delivered" ? at.timeIntervalSince1970 : nil,
                                 channel.rawValue, outcome, at.timeIntervalSince1970])
        }
    }

    // MARK: - FR24.5 同机照护者（跨成员待确认聚合，BR-001 显式携带成员）

    /// 全部家庭成员待确认剂量（FR24.5「帮家人处理」数据源）。
    /// 与 deliveryFacts 不同：**跨成员聚合**且每行携带 patient_id/成员名——
    /// 代确认必须落回剂量所属成员，禁止用 currentPatientId 张冠李戴（BR-001）。
    public func familyPendingDoses(from: Date, to: Date) async throws -> [FamilyPendingDose] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id AS dose_id, d.scheduled_for, d.dose_units,
                       p.patient_id, m.generic_name, m.spec, m.unit_kind,
                       COALESCE(pp.display_name, '') AS patient_name
                FROM medication_dose_log d
                JOIN medication_plan p ON p.id = d.plan_id
                JOIN medication m ON m.id = p.medication_id
                LEFT JOIN patient_profile pp ON pp.id = p.patient_id
                WHERE p.status = 'active' AND d.user_action IS NULL
                  AND d.scheduled_for >= ? AND d.scheduled_for <= ?
                ORDER BY d.scheduled_for
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
            return rows.map { row in
                FamilyPendingDose(
                    patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
                    patientName: row["patient_name"] as String,
                    medicationName: row["generic_name"] as String,
                    spec: row["spec"] as String?,
                    dose: ScheduledDose(dueAt: Date(timeIntervalSince1970: row["scheduled_for"] as Double),
                                        doseUnits: (row["dose_units"] as Double?) ?? 1,
                                        notifyId: row["dose_id"] as String))
            }
        }
    }
}

/// FR24.5 家庭待确认剂量投影（携带成员，代确认落回该成员）
public struct FamilyPendingDose: Sendable, Equatable, Identifiable {
    public var patientId: UUID
    public var patientName: String
    public var medicationName: String
    public var spec: String?
    public var dose: ScheduledDose
    public var id: String { dose.notifyId }
    public init(patientId: UUID, patientName: String, medicationName: String,
                spec: String?, dose: ScheduledDose) {
        self.patientId = patientId; self.patientName = patientName
        self.medicationName = medicationName; self.spec = spec; self.dose = dose
    }
}

/// FR9.8.2 扣减矩阵落库（同事务）：按 FEFO 在**本药品**活跃且未过期批次上分配
/// （评审 S1-1：不按 medication 过滤会把 A 药确认扣到 B 药批；过期批不得作来源）。
/// 自由函数：在 writer.write 的同步闭包内调用，无 actor 隔离问题（Swift 6 显式 self 纪律）。
func applyResolutionOnLots(patientId: UUID, medicationId: UUID, notifyId: String, units: Double,
                                   action: DoseUserAction,
                                   transitionMatrix: (plan: Double, confirmed: Double)? = nil,
                                   db: Database) throws {
        var inventories: [DualTrackInventory] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT * FROM stock_lot
            WHERE patient_id = ? AND medication_id = ? AND status = 'active'
              AND (expire_at IS NULL OR expire_at > ?)
            """, arguments: [patientId.uuidString, medicationId.uuidString,
                             Date().timeIntervalSince1970]) {
            var inv = DualTrackInventory(lotId: UUID(uuidString: row["id"] as String) ?? UUID(),
                                         totalUnits: row["total_units"] as Double,
                                         unitKind: row["unit_kind"] as String,
                                         expireAt: (row["expire_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
            inv.remainingPlanUnits = row["remaining_plan_units"] as Double
            inv.remainingConfirmedUnits = row["remaining_confirmed_units"] as Double
            inventories.append(inv)
        }
        // FR9.8.2 扣减矩阵由 Domain 单一编码派生（InventoryRules.deduction），
        // 不在此重新编码——矩阵是 BR 规则，只能有一处定义。
        // transitionMatrix：补录转场修正（missed→taken 计划轨已扣）由 Domain 判定传入。
        let matrix = transitionMatrix ?? InventoryRules.deduction(for: action, units: units)
        var planRemaining = matrix.plan
        var confirmedRemaining = matrix.confirmed
        // 双轨账本：planned_units 记录计划线扣减，confirmed_units 记录确认线扣减，
        // 二者独立——原实现把 confirmedTake 同时写入两列，导致计划线账本失真、
        // 安全线（续药提醒）计算错误（FR9.8 双轨语义）。
        var allocations: [(lotId: UUID, planUnits: Double, confirmedUnits: Double)] = []
        for sortedLot in InventoryRules.fefoOrder(inventories) {
            guard planRemaining > 0 || confirmedRemaining > 0 else { break }
            guard sortedLot.status == "active",
                  let i = inventories.firstIndex(where: { $0.lotId == sortedLot.lotId }) else { continue }
            var lot = inventories[i]
            let planTake = min(lot.remainingPlanUnits, planRemaining)
            let confirmedTake = min(lot.remainingConfirmedUnits, confirmedRemaining)
            if planTake > 0 { lot = InventoryRules.deductPlan(lot, units: planTake); planRemaining -= planTake }
            if confirmedTake > 0 { lot = InventoryRules.deductConfirmed(lot, units: confirmedTake); confirmedRemaining -= confirmedTake }
            if planTake > 0 || confirmedTake > 0 {
                inventories[i] = lot
                allocations.append((lot.lotId, planTake, confirmedTake))
            }
        }
        for lot in inventories {
            try db.execute(sql: """
                UPDATE stock_lot SET remaining_plan_units = ?, remaining_confirmed_units = ?
                WHERE id = ?
                """, arguments: [lot.remainingPlanUnits, lot.remainingConfirmedUnits, lot.lotId.uuidString])
        }
        for a in allocations {   // 追加时已过滤零扣减行（planTake/confirmedTake 双零不入账）
            // 评审修正第二轮（转场 PK 冲突）：materializeMissed 已为同一剂量行写入
            // (planned=units, confirmed=0) 分配后，补录转场（missed→taken）再次以
            // (0, units) 落账会撞 dose_lot_allocation 主键 (dose_log_id, stock_lot_id)
            // → 整个事务回滚、补录失败。改为累加式 upsert：双轨账本语义 =
            // 该剂量对该批次的累计计划/确认扣减，转场是追加而非覆盖。
            try db.execute(sql: """
                INSERT INTO dose_lot_allocation (dose_log_id, stock_lot_id, planned_units, confirmed_units)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(dose_log_id, stock_lot_id) DO UPDATE SET
                  planned_units = planned_units + excluded.planned_units,
                  confirmed_units = confirmed_units + excluded.confirmed_units
                """, arguments: [notifyId, a.lotId.uuidString, a.planUnits, a.confirmedUnits])
        }
    }
#endif
