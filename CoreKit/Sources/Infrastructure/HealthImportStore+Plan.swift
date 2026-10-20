#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：GRDB 仅 Apple 平台） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 导入范围 + 初始完成态（业主 2026-10-20 裁决）。
/// 纯持久化读写；模式判定在 Domain `HealthImportPlan.mode`。
extension HealthImportStore {

    /// 当前绑定计划；无绑定返回 nil。旧库无 plan 行按 .all 解释（不写库）。
    public func plan() async throws -> HealthImportPlan? {
        try await writer.read { db in
            guard let binding = try Self.binding(db) else { return nil }
            return try Self.plan(db, binding: binding)
        }
    }

    /// 激活/连接时判定：所选范围未完成 → 初始回填（断点优先）；已完成 → 增量
    /// （完成后的 pending 属增量，不回到初始回填）。
    public func importMode() async throws -> HealthImportMode {
        try await writer.read { db in
            guard let binding = try Self.binding(db) else { throw ImportError.missingOwner }
            let plan = try Self.plan(db, binding: binding)
            return plan.mode(depth: binding.historyDepth)
        }
    }

    public func hasPendingWork() async throws -> Bool {
        try await writer.read { db in
            guard let binding = try Self.binding(db) else { return false }
            return try Self.hasPendingWork(db, bindingId: binding.id)
        }
    }

    /// 用户改导入范围。只影响 history：清该道在途批次（锚点谓词已变，旧批次不可续）；
    /// 已导入行与旧深度锚点保留（扩大范围时新深度键从 nil 幂等重取）。
    @discardableResult
    public func setHistoryDepth(_ depth: HealthHistoryDepth) async throws -> Binding? {
        try await writer.write { db in
            guard let binding = try Self.binding(db) else { return nil }
            if depth == binding.historyDepth { return binding }
            try Self.ensurePlan(db, bindingId: binding.id, connectedAt: binding.connectedAt,
                                depth: binding.historyDepth)
            let plan = try Self.plan(db, binding: binding)
            // 新深度未覆盖 → 初始完成标记作废；缩小到已覆盖深度则保留。
            let keepsInitial = plan.remainingKinds(depth: depth).isEmpty
            try db.execute(sql: """
                UPDATE hk_import_plan SET history_days = ?, updated_at = ?
                WHERE binding_id = ?
                """, arguments: [depth.days, Date().timeIntervalSince1970,
                                 binding.id.uuidString])
            if !keepsInitial {
                try db.execute(sql: """
                    UPDATE hk_import_plan SET initial_completed_at = NULL
                    WHERE binding_id = ?
                    """, arguments: [binding.id.uuidString])
            } else if plan.initialCompletedAt == nil {
                // 缩小到已被覆盖的深度：完成态即刻成立（completion 已证明该范围排空）。
                try db.execute(sql: """
                    UPDATE hk_import_plan SET initial_completed_at = ?
                    WHERE binding_id = ?
                    """, arguments: [Date().timeIntervalSince1970, binding.id.uuidString])
            }
            try Self.discardHistoryPending(db, bindingId: binding.id)
            return try Self.binding(db)
        }
    }

    /// recent 首填完成（降序扫描到 cutoff，进入 anchored 模式）。
    public func markRecentComplete(kind: HealthDataKind, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard let binding = try Self.binding(db) else { throw ImportError.missingOwner }
            try db.execute(sql: """
                INSERT INTO hk_import_completion
                  (binding_id, type_key, recent_completed_at, history_completed_at,
                   history_days, blocked_reason)
                VALUES (?, ?, ?, NULL, NULL, NULL)
                ON CONFLICT(binding_id, type_key) DO UPDATE SET
                  recent_completed_at = COALESCE(hk_import_completion.recent_completed_at,
                                                 excluded.recent_completed_at)
                """, arguments: [binding.id.uuidString, kind.rawValue,
                                 date.timeIntervalSince1970])
        }
    }

    /// history 道排空所选深度（空页提交）；`depth` 记录已覆盖范围。
    public func markHistoryComplete(kind: HealthDataKind, depth: HealthHistoryDepth,
                                    at date: Date = Date()) async throws {
        try await writer.write { db in
            guard let binding = try Self.binding(db) else { throw ImportError.missingOwner }
            // 完成态只升不降：已覆盖 .all 或更深时，后续窄档完成不得把它降级。
            let existing = try Row.fetchOne(db, sql: """
                SELECT history_completed_at, history_days FROM hk_import_completion
                WHERE binding_id = ? AND type_key = ?
                """, arguments: [binding.id.uuidString, kind.rawValue])
            let existingCompleted = (existing?["history_completed_at"] as Double?) != nil
            let existingDays = existing?["history_days"] as Int?
            let newDays = depth.days
            let keepExisting = existingCompleted
                && (existingDays == nil || (newDays != nil && existingDays! >= newDays!))
            if keepExisting { return }
            try db.execute(sql: """
                INSERT INTO hk_import_completion
                  (binding_id, type_key, recent_completed_at, history_completed_at,
                   history_days, blocked_reason)
                VALUES (?, ?, NULL, ?, ?, NULL)
                ON CONFLICT(binding_id, type_key) DO UPDATE SET
                  history_completed_at = excluded.history_completed_at,
                  history_days = excluded.history_days
                """, arguments: [binding.id.uuidString, kind.rawValue,
                                 date.timeIntervalSince1970, depth.days])
        }
    }

    /// HealthKit 明确报告该类型投递/读取被阻断（权限未定/被拒）。
    /// 阻断不标完成；授权恢复时由调用方 `resetKind` 后重取。
    public func markBlocked(kind: HealthDataKind, reason: String) async throws {
        try await writer.write { db in
            guard let binding = try Self.binding(db) else { throw ImportError.missingOwner }
            try db.execute(sql: """
                INSERT INTO hk_import_completion
                  (binding_id, type_key, recent_completed_at, history_completed_at,
                   history_days, blocked_reason)
                VALUES (?, ?, NULL, NULL, NULL, ?)
                ON CONFLICT(binding_id, type_key) DO UPDATE SET blocked_reason = excluded.blocked_reason
                """, arguments: [binding.id.uuidString, kind.rawValue, String(reason.prefix(200))])
            // 阻断使“全部完成”不再成立；UI 不能继续显示初始导入已完成。
            try db.execute(sql: "UPDATE hk_import_plan SET initial_completed_at = NULL WHERE binding_id = ?",
                           arguments: [binding.id.uuidString])
        }
    }

    /// 授权恢复/深度回退/游标损坏：清该类型完成态 + 全部锚点 + 在途批次，强制重取。
    public func resetKind(_ kind: HealthDataKind) async throws {
        try await writer.write { db in
            guard let binding = try Self.binding(db) else { throw ImportError.missingOwner }
            try db.execute(sql: "DELETE FROM hk_import_completion WHERE binding_id = ? AND type_key = ?",
                           arguments: [binding.id.uuidString, kind.rawValue])
            try db.execute(sql: "DELETE FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                           arguments: [binding.id.uuidString, kind.rawValue])
            try db.execute(sql: "DELETE FROM hk_sync_anchor WHERE anchor_key LIKE ?",
                           arguments: ["%.\(kind.rawValue).%"])
            try db.execute(sql: "UPDATE hk_import_plan SET initial_completed_at = NULL WHERE binding_id = ?",
                           arguments: [binding.id.uuidString])
        }
    }

    /// 全部类型覆盖所选深度 → 落 initial_completed_at（覆盖本身已由道末空页证明；
    /// 此后的 pending 属增量）。返回是否完成（调用方据此切 incremental 并刷新 UI）。
    @discardableResult
    public func markInitialCompletedIfCovered(at date: Date = Date()) async throws -> Bool {
        try await writer.write { db in
            guard let binding = try Self.binding(db) else { return false }
            try Self.ensurePlan(db, bindingId: binding.id, connectedAt: binding.connectedAt,
                                depth: binding.historyDepth)
            let plan = try Self.plan(db, binding: binding)
            // 完成标记只在整道最终空页提交后写入（laneComplete），因此“覆盖”本身
            // 已证明初始范围排空；此后的 pending 属增量，不再阻止完成态。
            let complete = plan.remainingKinds(depth: binding.historyDepth).isEmpty
            if complete {
                try db.execute(sql: """
                    UPDATE hk_import_plan SET initial_completed_at = COALESCE(initial_completed_at, ?),
                      updated_at = ? WHERE binding_id = ?
                    """, arguments: [date.timeIntervalSince1970, date.timeIntervalSince1970,
                                     binding.id.uuidString])
            }
            return complete
        }
    }

    // MARK: - 静态读

    static func plan(_ db: Database, binding: Binding) throws -> HealthImportPlan {
        let row = try Row.fetchOne(db, sql: """
            SELECT history_days, selected_at, initial_completed_at
            FROM hk_import_plan WHERE binding_id = ?
            """, arguments: [binding.id.uuidString])
        let days = row?["history_days"] as Int?
        let selectedAt = (row?["selected_at"] as Double?)
            .map(Date.init(timeIntervalSince1970:)) ?? binding.connectedAt
        let initialCompletedAt = (row?["initial_completed_at"] as Double?)
            .map(Date.init(timeIntervalSince1970:))
        var completions: [String: HealthKindCompletion] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM hk_import_completion WHERE binding_id = ?
            """, arguments: [binding.id.uuidString])
        for row in rows {
            let key: String = row["type_key"]
            let recent = (row["recent_completed_at"] as Double?)
                .map(Date.init(timeIntervalSince1970:))
            let history = (row["history_completed_at"] as Double?)
                .map(Date.init(timeIntervalSince1970:))
            let historyDays = row["history_days"] as Int?
            let blockedReason: String? = row["blocked_reason"]
            let depth: HealthHistoryDepth? = history == nil
                ? nil
                : (historyDays.map { Self.depth(fromDays: $0) } ?? .all)
            completions[key] = HealthKindCompletion(
                recentCompletedAt: recent, historyCompletedAt: history,
                historyDepth: depth, blocked: blockedReason != nil)
        }
        return HealthImportPlan(
            depth: Self.depth(fromDays: days),
            selectedAt: selectedAt,
            completions: completions,
            initialCompletedAt: initialCompletedAt)
    }

    static func hasPendingWork(_ db: Database, bindingId: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM hk_pending_batch WHERE binding_id = ?)
            """, arguments: [bindingId.uuidString]) ?? false
    }

    /// 深度变化/授权恢复：只丢 history 在途批次；recent 不受谓词变化影响。
    static func discardHistoryPending(_ db: Database, bindingId: UUID) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT type_key, payload_json FROM hk_pending_batch WHERE binding_id = ?
            """, arguments: [bindingId.uuidString])
        for row in rows {
            let payload: String = row["payload_json"]
            guard let data = payload.data(using: .utf8),
                  let pending = try? JSONDecoder().decode(PendingBatch.self, from: data), // try?-ok: 旧/损坏载荷按非 history 跳过；取数进度可重取
                  pending.lane == .history else { continue }
            try db.execute(sql: """
                DELETE FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?
                """, arguments: [bindingId.uuidString, row["type_key"] as String])
        }
    }
}
#endif
