#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：GRDB 仅 Apple 平台） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 同步周期持久化（2026-10-21 业主裁决）。
///
/// 周期语义：全部 `HealthDataKind.allCases` 的数据数量稳定且无 pending/repair/
/// 失败，才算「同步一次」；未完成时后台继续跑，已完成类别不再询问，只推进剩余类别。
/// `stable_kinds` 用逗号分隔 rawValue，避免为每类增加一行表；新增 HealthDataKind
/// 自动进入比较（allCases），无需改表结构。
extension HealthImportStore {

    public func cycleState(binding: Binding) async throws -> HealthSyncCycleState {
        try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            return try Self.cycleState(db, binding: binding)
        }
    }

    /// 开始新周期：清空上一周期稳定集合。手动同步/间隔到期/首次同步调用。
    public func beginCycle(binding: Binding, at date: Date = Date()) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: """
                INSERT INTO hk_sync_cycle (binding_id, started_at, completed_at, stable_kinds, updated_at)
                VALUES (?, ?, NULL, '', ?)
                ON CONFLICT(binding_id) DO UPDATE SET
                  started_at = excluded.started_at,
                  completed_at = NULL,
                  stable_kinds = '',
                  updated_at = excluded.updated_at
                """, arguments: [binding.id.uuidString, date.timeIntervalSince1970,
                                 date.timeIntervalSince1970])
        }
    }

    /// 某类连续无新增达到稳定门槛。幂等追加；新周期开始前保留。
    public func markKindStable(binding: Binding, kind: HealthDataKind,
                               at date: Date = Date()) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            let state = try Self.cycleState(db, binding: binding)
            var stable = state.stableKinds
            guard !stable.contains(kind) else { return }
            stable.insert(kind)
            try db.execute(sql: """
                UPDATE hk_sync_cycle SET stable_kinds = ?, updated_at = ? WHERE binding_id = ?
                """, arguments: [Self.encodeKinds(stable), date.timeIntervalSince1970,
                                 binding.id.uuidString])
        }
    }

    /// observer/授权恢复/新数据到达：该类别重新进入待同步集合。
    public func clearKindStable(binding: Binding, kind: HealthDataKind,
                                at date: Date = Date()) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            let state = try Self.cycleState(db, binding: binding)
            guard state.stableKinds.contains(kind) else { return }
            var stable = state.stableKinds
            stable.remove(kind)
            try db.execute(sql: """
                UPDATE hk_sync_cycle SET stable_kinds = ?, updated_at = ? WHERE binding_id = ?
                """, arguments: [Self.encodeKinds(stable), date.timeIntervalSince1970,
                                 binding.id.uuidString])
        }
    }

    /// 全部类别稳定 → 完成本次同步；记录完成时刻供间隔节流。
    public func completeCycle(binding: Binding, at date: Date = Date()) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: """
                UPDATE hk_sync_cycle SET completed_at = ?, updated_at = ? WHERE binding_id = ?
                """, arguments: [date.timeIntervalSince1970, date.timeIntervalSince1970,
                                 binding.id.uuidString])
        }
    }

    /// 手动重新校验/连接/范围变化：丢弃旧周期，下一次同步从全新周期开始。
    public func resetCycle(binding: Binding) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: "DELETE FROM hk_sync_cycle WHERE binding_id = ?",
                           arguments: [binding.id.uuidString])
        }
    }

    // MARK: - 静态读

    static func cycleState(_ db: Database, binding: Binding) throws -> HealthSyncCycleState {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT started_at, completed_at, stable_kinds FROM hk_sync_cycle WHERE binding_id = ?
            """, arguments: [binding.id.uuidString]) else {
            return HealthSyncCycleState()
        }
        let started: Double? = row["started_at"]
        let completed: Double? = row["completed_at"]
        let encoded: String = row["stable_kinds"]
        return HealthSyncCycleState(
            startedAt: started.map(Date.init(timeIntervalSince1970:)),
            completedAt: completed.map(Date.init(timeIntervalSince1970:)),
            stableKinds: Self.decodeKinds(encoded))
    }

    static func encodeKinds(_ kinds: Set<HealthDataKind>) -> String {
        kinds.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func decodeKinds(_ encoded: String) -> Set<HealthDataKind> {
        Set(encoded.split(separator: ",").compactMap { HealthDataKind(rawValue: String($0)) })
    }
}
#endif
