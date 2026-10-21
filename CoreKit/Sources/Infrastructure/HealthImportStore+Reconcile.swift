#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：GRDB 仅 Apple 平台） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

/// 删除对账与窗口权威重算（业主 2026-10-20「数据缺失不只睡眠」）。
///
/// 为什么需要它：带日期谓词的 anchored query 会压掉 `HKDeletedObject`；Apple Watch
/// 的修订=删除+重插，旧 UUID 留在 `hk_sample_index` 后会让窗口永久 `complete=false`，
/// 单页 pending 卡死整个类型。这里用 nil 谓词删除 feed 收集显式删除，进入持久化
/// repair 队列；每个受影响窗口重新 snapshot、重算行、清掉陈旧索引。
extension HealthImportStore {

    public struct ReconcileReport: Sendable, Equatable {
        public var rowsWritten = 0
        public var rowsRemoved = 0
        public var staleReferences = 0
        public init(rowsWritten: Int = 0, rowsRemoved: Int = 0, staleReferences: Int = 0) {
            self.rowsWritten = rowsWritten
            self.rowsRemoved = rowsRemoved
            self.staleReferences = staleReferences
        }
    }

    // MARK: - 删除 feed 游标

    public func deletionAnchor(binding: Binding, kind: HealthDataKind) async throws -> Data? {
        try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            return try Self.deletionAnchor(db, binding: binding, kind: kind)
        }
    }

    /// 归档锚点失效（恢复/系统重置）时清游标；下一轮从 nil anchor 重扫。
    public func resetDeletionAnchor(binding: Binding, kind: HealthDataKind) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: "DELETE FROM hk_deletion_anchor WHERE binding_id = ? AND type_key = ?",
                           arguments: [binding.id.uuidString, kind.rawValue])
        }
    }

    /// 删除 UUID → 索引引用 → 覆盖窗口 → repair 队列；anchor 与入队同一事务。
    /// 未索引的删除（从未导入/已被旧批次回收）只推进 anchor，不制造空窗口。
    @discardableResult
    public func enqueueDeletionFeed(binding: Binding, kind: HealthDataKind,
                                    deleted: [UUID], anchor: Data?) async throws -> Int {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            var queued = 0
            for id in Set(deleted) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM hk_sample_index
                    WHERE sample_id = ? AND type_key = ? AND patient_id = ?
                    """, arguments: [id.uuidString, kind.rawValue, binding.patientId.uuidString])
                for row in rows {
                    let ref = try Self.decodeReference(row, kind: kind)
                    for window in HealthImportWindow.covering(ref, calendar: binding.calendar) {
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO hk_repair_window
                              (binding_id, type_key, start_at, end_at, attempts, last_error)
                            VALUES (?, ?, ?, ?, 0, NULL)
                            """, arguments: [binding.id.uuidString, kind.rawValue,
                                             window.start.timeIntervalSince1970,
                                             window.end.timeIntervalSince1970])
                        queued += db.changesCount
                    }
                }
            }
            if let anchor {
                try db.execute(sql: """
                    INSERT INTO hk_deletion_anchor (binding_id, type_key, anchor_value, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(binding_id, type_key) DO UPDATE SET
                      anchor_value = excluded.anchor_value, updated_at = excluded.updated_at
                    """, arguments: [binding.id.uuidString, kind.rawValue,
                                     anchor.base64EncodedString(), Date().timeIntervalSince1970])
            }
            return queued
        }
    }

    public func pendingRepairWindows(binding: Binding, kind: HealthDataKind,
                                     limit: Int) async throws -> [HealthImportWindow] {
        try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT start_at, end_at FROM hk_repair_window
                WHERE binding_id = ? AND type_key = ?
                ORDER BY start_at DESC LIMIT ?
                """, arguments: [binding.id.uuidString, kind.rawValue, max(1, limit)])
            return rows.map { row in
                HealthImportWindow(kind: kind,
                    start: Date(timeIntervalSince1970: row["start_at"]),
                    end: Date(timeIntervalSince1970: row["end_at"]))
            }
        }
    }

    public func pendingRepairCount(binding: Binding, kind: HealthDataKind) async throws -> Int {
        try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM hk_repair_window WHERE binding_id = ? AND type_key = ?
                """, arguments: [binding.id.uuidString, kind.rawValue]) ?? 0
        }
    }

    /// 自动同步会话的稳定判据：全库待重算窗口总数（不区分类型）。
    public func pendingRepairTotal() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hk_repair_window") ?? 0
        }
    }

    public func completeRepairWindow(binding: Binding, kind: HealthDataKind,
                                     window: HealthImportWindow) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: """
                DELETE FROM hk_repair_window
                WHERE binding_id = ? AND type_key = ? AND start_at = ? AND end_at = ?
                """, arguments: [binding.id.uuidString, kind.rawValue,
                                 window.start.timeIntervalSince1970, window.end.timeIntervalSince1970])
        }
    }

    /// 失败窗口保留并计次；首错文本截断，诊断走 report.failureReasons。
    public func failRepairWindow(binding: Binding, kind: HealthDataKind,
                                 window: HealthImportWindow, error: String) async throws -> Int {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: """
                UPDATE hk_repair_window SET attempts = attempts + 1, last_error = ?
                WHERE binding_id = ? AND type_key = ? AND start_at = ? AND end_at = ?
                """, arguments: [String(error.prefix(200)), binding.id.uuidString, kind.rawValue,
                                 window.start.timeIntervalSince1970, window.end.timeIntervalSince1970])
            return try Int.fetchOne(db, sql: """
                SELECT attempts FROM hk_repair_window
                WHERE binding_id = ? AND type_key = ? AND start_at = ? AND end_at = ?
                """, arguments: [binding.id.uuidString, kind.rawValue,
                                 window.start.timeIntervalSince1970, window.end.timeIntervalSince1970]) ?? 0
        }
    }

    public func dropRepairWindow(binding: Binding, kind: HealthDataKind,
                                 window: HealthImportWindow) async throws {
        try await completeRepairWindow(binding: binding, kind: kind, window: window)
    }

    // MARK: - 权威窗口重算

    /// snapshot 是唯一真相：重算本窗口行，删除不在 visible 的陈旧索引与自有行。
    /// 与 `commit` 不同——不依赖 pending/锚点/known 完整性；删除事件已由 feed 证明。
    public func reconcileWindow(binding: Binding, kind: HealthDataKind,
                                snapshot: HealthWindowSnapshot) async throws -> ReconcileReport {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            let window = snapshot.window
            guard window.kind == kind, window.isValid,
                  snapshot.samples.allSatisfy({ window.overlaps($0) }), snapshot.rejected >= 0 else {
                throw ImportError.invalidValue
            }
            let visible = try Self.validatedReferences(snapshot.samples, kind: kind,
                                                       calendar: binding.calendar)
            let kept = Set(snapshot.rows.compactMap(\.sourceRef))
            guard kept.count == snapshot.rows.count else { throw ImportError.invalidValue }
            let priorByIdentity = Dictionary(grouping: try self.priorProjectionRows(
                binding: binding, kind: kind, window: window, db: db)) { $0["source_ref"] as String }
            for row in snapshot.rows {
                try Self.validateRow(row, window: window, visible: visible)
            }

            let known = try self.knownReferences(binding: binding, kind: kind,
                                            snapshots: [snapshot], db: db)[window] ?? []
            let stale = known.filter { visible[$0.id] == nil }
            for ref in stale {
                try db.execute(sql: """
                    DELETE FROM hk_sample_index
                    WHERE sample_id = ? AND type_key = ? AND patient_id = ?
                    """, arguments: [ref.id.uuidString, kind.rawValue, binding.patientId.uuidString])
            }

            var report = ReconcileReport(staleReferences: stale.count)
            for row in priorByIdentity.values.flatMap({ $0 }) where (row["owned"] as Int) == 1 {
                let identity: String = row["source_ref"]
                guard !kept.contains(identity) else { continue }
                try db.execute(sql: "DELETE FROM metric_sample WHERE id = ?",
                               arguments: [row["id"] as String])
                report.rowsRemoved += db.changesCount
            }
            var commitReport = CommitReport()
            var preserved = Set<String>()
            try self.upsertSnapshotRows(snapshot.rows, priorByIdentity: priorByIdentity, kind: kind,
                                   binding: binding, report: &commitReport,
                                   preserved: &preserved, db: db)
            try self.upsertSampleIndex(Array(visible.values), kind: kind, binding: binding, db: db)
            report.rowsWritten = commitReport.persistedRows
            return report
        }
    }

    /// 手动/升级修复入口：清健康导入全部派生状态（锚点/在途/完成/索引/删除对账），
    /// 保留行与用户排除态；下一次同步按所选范围完整重扫。
    public func resetImportStateForRewalk() async throws {
        try await writer.write { db in
            try Self.requireEnabled(db)
            try db.execute(sql: "DELETE FROM hk_pending_batch")
            try db.execute(sql: "DELETE FROM hk_sync_anchor")
            try db.execute(sql: "DELETE FROM hk_import_completion")
            try db.execute(sql: "DELETE FROM hk_sample_index")
            try db.execute(sql: "DELETE FROM hk_deletion_anchor")
            try db.execute(sql: "DELETE FROM hk_repair_window")
            try db.execute(sql: "UPDATE hk_import_plan SET initial_completed_at = NULL")
        }
    }

    // MARK: - 静态读

    static func deletionAnchor(_ db: Database, binding: Binding,
                               kind: HealthDataKind) throws -> Data? {
        guard let encoded = try String.fetchOne(db, sql: """
            SELECT anchor_value FROM hk_deletion_anchor WHERE binding_id = ? AND type_key = ?
            """, arguments: [binding.id.uuidString, kind.rawValue]) else { return nil }
        return Data(base64Encoded: encoded)
    }
}
#endif
