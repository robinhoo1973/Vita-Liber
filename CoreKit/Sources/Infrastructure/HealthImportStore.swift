#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain

public actor HealthImportStore {
    public struct Binding: Sendable, Equatable {
        public let id: UUID
        public let patientId: UUID
        public let timeZoneID: String
        /// round2 H-N1：绑定时刻（`hk_import_binding.connected_at`）——两道回填的 cutoff 派生源，
        /// 固定于绑定时刻不随 now 漂移。
        public let connectedAt: Date
        /// 业主 2026-10-20：用户选择的导入范围；只影响 history 道下界。
        public let historyDepth: HealthHistoryDepth
        public var calendar: Calendar {
            var result = Calendar(identifier: .gregorian)
            result.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
            return result
        }

        public init(id: UUID, patientId: UUID, timeZoneID: String, connectedAt: Date,
                    historyDepth: HealthHistoryDepth = .all) {
            self.id = id
            self.patientId = patientId
            self.timeZoneID = timeZoneID
            self.connectedAt = connectedAt
            self.historyDepth = historyDepth
        }
    }

    public enum ImportError: Error {
        case disabled, missingOwner, bindingChanged, staleAnchor, incompleteSnapshot, invalidValue
        /// C1-5（2026-10-04 后台任务专项评审）：共享轮次超过陈旧阈值仍无终态——
        /// join 者返回此错误而非无限排队（只记账不杀共享任务）。
        case staleFlight
        /// 2026-10-20：后台投递 join 超时（共享轮次仍在跑）。只让本次投递放弃等待，
        /// 不杀共享任务；投递本身已确认，下一次 refresh/backfill 继续。
        case busy
    }

    /// Fetch progress is durable but is not a materialization checkpoint.
    public struct PendingBatch: Sendable, Equatable, Codable {
        public let previousAnchor: Data?
        public let batch: HealthChangeBatch
        public let completedWindows: Set<HealthImportWindow>
        public let reconcileAfter: Date?
        public let revision: UUID
        /// round2 H-N1 所属道；旧载荷（v2 单道）缺键解码为 nil → `pending()` 作废该行
        /// （取数进度不是物化检查点，重取安全），而非让该类型永久卡死。
        public let lane: HealthFetchLane?
        /// v2 起 pending 只承载**一页**（≤500 refs）。旧整道累积载荷缺 version
        /// 或 added>500 → 作废并从 committed anchor/fetch cursor 重放（幂等）。
        public var version: Int? = 2
    }

    public struct CommitReport: Sendable, Equatable {
        public var persistedRows = 0
        public var preservedRows = 0
        public var deferredWindows = 0
        public var hasMore = false
        /// 该道已到最终空页、committed anchor 已推进（无 pending/延迟）。
        /// 只有此状态可标记类型完成（业主 2026-10-20 激活完成态）。
        public var laneComplete = false
        /// 有可见样本证据时被判定为已删除的陈旧索引引用数（删除+重插自愈）。
        public var staleReferences = 0
    }

    let writer: any DatabaseWriter
    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func connect(timeZoneID: String = TimeZone.current.identifier,
                        depth: HealthHistoryDepth = .all) async throws -> Binding {
        try await writer.write { db in
            guard TimeZone(identifier: timeZoneID) != nil else { throw ImportError.invalidValue }
            try Self.requireEnabled(db)
            guard let patient = try Self.ownerPatient(db) else { throw ImportError.missingOwner }
            if let existing = try Self.binding(db) {
                guard existing.patientId == patient else { throw ImportError.bindingChanged }
                // 已有绑定：保留用户已选深度（depth 参数只在首次连接生效）；
                // 旧库/中断留下的无 plan 行按 .all 补齐，保持既有行为。
                try Self.ensurePlan(db, bindingId: existing.id, connectedAt: existing.connectedAt,
                                    depth: existing.historyDepth)
                return try Self.binding(db) ?? existing
            }
            // 落库与返回值用同一 Double：Binding.connectedAt 经 Date(timeIntervalSince1970:) 构造，
            // 重连读回的值逐位相同（Equatable 不因 Double 往返漂移）。
            let connectedAt = Date().timeIntervalSince1970
            let binding = Binding(id: UUID(), patientId: patient, timeZoneID: timeZoneID,
                                  connectedAt: Date(timeIntervalSince1970: connectedAt),
                                  historyDepth: depth)
            try db.execute(sql: """
                INSERT INTO hk_import_binding (singleton, id, patient_id, time_zone, connected_at)
                VALUES (1, ?, ?, ?, ?)
                """, arguments: [binding.id.uuidString, patient.uuidString, timeZoneID, connectedAt])
            try Self.ensurePlan(db, bindingId: binding.id, connectedAt: binding.connectedAt, depth: depth)
            return binding
        }
    }

    public func connection() async throws -> Binding? {
        try await writer.read { db in
            guard let binding = try Self.binding(db), try Self.ownerPatient(db) == binding.patientId else { return nil }
            return binding
        }
    }

    public func isEnabled() async throws -> Bool {
        try await writer.read { db in
            let value = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?",
                                           arguments: [AppSettingKey.authHealthRead.rawValue])
            return SettingsRules.resolved(value, key: .authHealthRead) == "true"
        }
    }

    /// round2 H-N1：两道回填范围（[recent, history]，排空顺序即数组顺序），cutoff 派生自绑定时刻。
    public nonisolated func scopes(for binding: Binding) -> [HealthFetchScope] {
        HealthFetchScope.scopes(connectedAt: binding.connectedAt, calendar: binding.calendar,
                                depth: binding.historyDepth)
    }

    /// 每道独立游标（recent 道 `hk.v4` 降序首填游标；history 道 `.all` 用 `hk.v3`，
    /// 有限深度用 `hk.v6.<days>`）；v2 单道键弃用——谓词变了，旧锚点不跨谓词复用，
    /// 首次升级触发一次性幂等重回填（commit 按身份 upsert，不产重复行）。
    public func anchor(binding: Binding, kind: HealthDataKind, lane: HealthFetchLane) async throws -> Data? {
        try await writer.read { db in try Self.anchor(db, key: Self.anchorKey(binding, kind, lane)) }
    }

    /// 经 write：旧载荷（缺 lane）在读取时作废需要删除权限。
    public func pendingBatch(binding: Binding, kind: HealthDataKind) async throws -> PendingBatch? {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            return try Self.pending(binding: binding, kind: kind, db: db)
        }
    }

    /// C7（2026-10-03 评审修复）：空推进页直接落锚点——recent 道稀疏扫描的断点持久化。
    /// 只推进「已覆盖」扫描位置（无 added/deleted），不触碰批次物化语义；
    /// 锚点键与 commit 推进同一 upsert 形态。
    /// 取数游标（v2026-10-20 业主裁决）：与 committed anchor 分离。
    /// - committed anchor 仍只在一道最终空页后排空（证明该道全部已物化）；
    /// - fetch cursor 每完成一页就前进，崩溃从最近一页续取；pending 只装一页。
    /// 旧库无 fetch cursor 时回落 committed anchor（既有进度不丢）。
    public func nextFetchAnchor(binding: Binding, kind: HealthDataKind, lane: HealthFetchLane) async throws -> Data? {
        try await writer.read { db in
            try Self.fetchCursor(db, key: Self.fetchAnchorKey(binding, kind, lane))
                ?? Self.anchor(db, key: Self.anchorKey(binding, kind, lane))
        }
    }

    /// 稀疏扫描检查点（recent 降序空窗推进）：只写 fetch cursor，不推进 committed anchor。
    /// 空扫描页没有物化内容，committed anchor 仍等该道最终空页。
    public func saveScanCheckpoint(binding: Binding, kind: HealthDataKind,
                                   lane: HealthFetchLane, anchor: Data) async throws {
        try Task.checkCancellation()
        try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            try Self.saveFetchCursor(db, key: Self.fetchAnchorKey(binding, kind, lane), anchor: anchor)
        }
    }

    public func saveAnchor(binding: Binding, kind: HealthDataKind, lane: HealthFetchLane, anchor: Data) async throws {
        try Task.checkCancellation()
        try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            try db.execute(sql: """
                INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value, updated_at = excluded.updated_at
                """, arguments: [Self.anchorKey(binding, kind, lane), anchor.base64EncodedString(), Date().timeIntervalSince1970])
        }
    }

    /// Append one bounded page. Missing identities never prevent fetching its successor.
    public func stage(binding: Binding, kind: HealthDataKind, scope: HealthFetchScope, previousAnchor: Data?,
                      page: HealthChangeBatch) async throws -> PendingBatch {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireEnabled(db)
            try Self.requireBinding(binding, db: db)
            guard page.added.count <= 500, !page.anchor.isEmpty,
                  !page.hasMore || !page.added.isEmpty || !page.deleted.isEmpty else { throw ImportError.invalidValue }
            let committed = try Self.anchor(db, key: Self.anchorKey(binding, kind, scope.lane))
            let fetch = try Self.fetchCursor(db, key: Self.fetchAnchorKey(binding, kind, scope.lane))
                ?? committed
            let prior = try Self.pending(binding: binding, kind: kind, db: db)
            // round2 H-N1：另一道在途时本道不得开新批次——先排空在途道（pending 每类单行）
            guard prior == nil || prior?.lane == scope.lane else { throw ImportError.staleAnchor }
            guard (prior?.batch.anchor ?? fetch) == previousAnchor,
                  prior == nil || prior?.previousAnchor == fetch else { throw ImportError.staleAnchor }
            if page.hasMore || !page.added.isEmpty || !page.deleted.isEmpty {
                guard page.anchor != previousAnchor else { throw ImportError.staleAnchor }
            }
            var added = try Self.validatedReferences(prior?.batch.added ?? [], kind: kind, calendar: binding.calendar)
            let incoming = try Self.validatedReferences(page.added, kind: kind, calendar: binding.calendar)
            for (id, ref) in incoming {
                if let old = added[id], old != ref { throw ImportError.invalidValue }
                added[id] = ref
            }
            // 单页 pending：生产路径永远在无 pending 时取页；此守卫只拒绝
            // 旧式“多页合并”调用，避免 version 2 载荷超过一页。
            guard added.count <= 500 else { throw ImportError.invalidValue }
            let pageDeletions = Set(page.deleted)
            let deleted = Set(prior?.batch.deleted ?? []).union(pageDeletions)
            let oldReferences = try Self.deletedReferences(page.deleted, binding: binding, kind: kind, db: db)
            let touched = Set((page.added + oldReferences + added.values.filter { pageDeletions.contains($0.id) })
                .flatMap { HealthImportWindow.covering($0, calendar: binding.calendar) })
            let pending = PendingBatch(previousAnchor: fetch,
                batch: HealthChangeBatch(added: added.values.sorted { $0.id.uuidString < $1.id.uuidString },
                    deleted: deleted.sorted { $0.uuidString < $1.uuidString }, anchor: page.anchor, hasMore: page.hasMore),
                completedWindows: (prior?.completedWindows ?? []).subtracting(touched),
                reconcileAfter: prior?.reconcileAfter, revision: UUID(), lane: scope.lane)
            try Self.savePending(pending, binding: binding, kind: kind, db: db)
            return pending
        }
    }

    public func affectedWindows(binding: Binding, kind: HealthDataKind,
                                batch: HealthChangeBatch) async throws -> [HealthImportWindow] {
        let deleted = try await writer.read { db in
            try Self.requireBinding(binding, db: db)
            return try Self.deletedReferences(batch.deleted, binding: binding, kind: kind, db: db)
        }
        _ = try Self.validatedReferences(batch.added, kind: kind, calendar: binding.calendar)
        return Set((batch.added + deleted).flatMap {
            HealthImportWindow.covering($0, calendar: binding.calendar)
        }).sorted { $0.start < $1.start }
    }

    /// Complete windows can progress independently; the committed cursor waits for the entire drained batch.
    public func commit(binding: Binding, kind: HealthDataKind, pending: PendingBatch,
                       snapshots: [HealthWindowSnapshot],
                       attemptedWindows: [HealthImportWindow]? = nil) async throws -> CommitReport {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            let context = try self.commitPreflight(binding: binding, kind: kind, pending: pending,
                                              snapshots: snapshots, attemptedWindows: attemptedWindows, db: db)
            // Capture actual references before any window writes. One series can own several windows.
            let knownByWindow = try self.knownReferences(binding: binding, kind: kind, snapshots: snapshots, db: db)

            var report = CommitReport()
            report.deferredWindows = context.requested.subtracting(context.supplied).count
            var completed = pending.completedWindows
            var preserved = Set<String>()
            var readings: [MetricReading] = []
            for snapshot in snapshots {
                if try self.materializeSnapshot(snapshot, known: knownByWindow[snapshot.window] ?? [],
                                           context: context, binding: binding, kind: kind,
                                           report: &report, preserved: &preserved,
                                           readings: &readings, db: db) {
                    completed.insert(snapshot.window)
                }
            }
            _ = try GuidelineStore.recordQualifiedHealthReadings(readings, patientId: binding.patientId, db: db)
            report.preservedRows = preserved.count
            // 2026-10-20 业主裁决：pending 单页 + fetch cursor 逐页推进。
            // - 页未完成：保留 pending，不前进任何游标；
            // - 页完成：fetch cursor ← 本页锚，退役本页墓碑，删 pending；
            //   committed anchor 仍只在该道最终空页（batch.hasMore=false）后推进，
            //   保留“整道已物化”的证明语义（既有测试/删除证明契约不变）。
            let pageComplete = completed == context.requiredWindows
            report.hasMore = context.batch.hasMore || !pageComplete
            report.laneComplete = pageComplete && !context.batch.hasMore
            if !pageComplete {
                try Self.savePending(PendingBatch(previousAnchor: pending.previousAnchor, batch: context.batch,
                    completedWindows: completed, reconcileAfter: context.attempted.last?.start ?? pending.reconcileAfter,
                    revision: UUID(), lane: context.lane), binding: binding, kind: kind, db: db)
                return report
            }
            try Self.saveFetchCursor(db,
                key: Self.fetchAnchorKey(binding, kind, context.lane), anchor: context.batch.anchor)
            // Retire tombstoned references only when every dependent window has been reconciled.
            for id in context.batch.deleted {
                try db.execute(sql: "DELETE FROM hk_sample_index WHERE sample_id = ? AND type_key = ? AND patient_id = ?",
                               arguments: [id.uuidString, kind.rawValue, binding.patientId.uuidString])
            }
            try db.execute(sql: "DELETE FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                           arguments: [binding.id.uuidString, kind.rawValue])
            if report.laneComplete {
                try db.execute(sql: """
                    INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value,
                      updated_at = excluded.updated_at
                    """, arguments: [context.key, context.batch.anchor.base64EncodedString(),
                                     Date().timeIntervalSince1970])
                try db.execute(sql: "DELETE FROM hk_sync_anchor WHERE anchor_key = ?",
                               arguments: [Self.fetchAnchorKey(binding, kind, context.lane)])
            }
            return report
        }
    }

    /// 提交前置闸门：启用/绑定/道存在 + 锚点与载荷一致（staleAnchor）+ hasMore 内容性判别
    /// （incompleteSnapshot）+ 窗口子集不变量——全部通过才返回提交上下文。
    nonisolated private func commitPreflight(binding: Binding, kind: HealthDataKind, pending: PendingBatch,
                                 snapshots: [HealthWindowSnapshot],
                                 attemptedWindows: [HealthImportWindow]?,
                                 db: Database) throws -> CommitContext {
        try Self.requireEnabled(db)
        try Self.requireBinding(binding, db: db)
        // round2 H-N1：无道的批次不可提交（旧载荷已在 pending() 作废，此处只防御直接构造）
        guard let lane = pending.lane else { throw ImportError.invalidValue }
        let key = Self.anchorKey(binding, kind, lane)
        // 待提交页的基准 = fetch cursor（每页推进）；旧库无 fetch cursor 时回落
        // committed anchor。committed anchor 仍只在该道最终页后推进。
        let committed = try Self.anchor(db, key: key)
        let fetch = try Self.fetchCursor(db, key: Self.fetchAnchorKey(binding, kind, lane))
            ?? committed
        guard fetch == pending.previousAnchor,
              try Self.pending(binding: binding, kind: kind, db: db) == pending else { throw ImportError.staleAnchor }
        let batch = pending.batch
        // 分页与排空的共同不变量（CI 34658990146 + 34659948629 两个验收
        // 测试钉死，互为镜像）：
        // ① hasMore 批次允许物化「内容完整」的窗口——历史分页期间完整
        //    窗口先于最终检查点物化，光标不推进（服务测试：
        //    historyPagesPublishCompleteWindowsBeforeTheFinalCheckpoint）；
        // ② 全空快照按完整窗口解释必须拒绝——501 条删除分两页到达时，
        //    第一页空快照提交会把窗口误判完整、删除 500 行（存储测试：
        //    staged501DeletionsDrainWithoutAdvancingCommittedAnchor，
        //    抛 incompleteSnapshot，光标原地等待）。
        // 内容性判别：任一快照携带实际内容即有证据的完整窗口；全空即
        // 「缺证据被当成有证据」（ERR#27 纪律），拒绝。唯一豁免：纯删除页
        // 且无任何窗口受影响（被删除样本从未导入，affectedWindows 为空）
        // ——否则未导入样本的删除页会被误报 incompleteSnapshot，
        // 整轮浪费且该类型落进失败名单（owner round10 实测假警报）。
        _ = try Self.validatedReferences(batch.added, kind: kind, calendar: binding.calendar)
        let tombstones = Set(batch.deleted)
        let deleted = try Self.deletedReferences(batch.deleted, binding: binding, kind: kind, db: db)
        let requiredWindows = Set((batch.added + deleted).flatMap { HealthImportWindow.covering($0, calendar: binding.calendar) })
        // 2026-10-20：页已完整物化后的“只提交”路径（fetch cursor 逐页推进/崩溃恢复）
        // 不带快照；它不是“空证据当完整”，requiredWindows 已被 completedWindows 覆盖。
        let alreadyMaterialized = requiredWindows.isSubset(of: pending.completedWindows)
        let deletionsOnlyEmptyPage = batch.added.isEmpty && snapshots.isEmpty
            && (attemptedWindows?.isEmpty ?? true)
        if batch.hasMore, !deletionsOnlyEmptyPage, !alreadyMaterialized,
           !snapshots.contains(where: { !$0.samples.isEmpty || !$0.rows.isEmpty }) {
            throw ImportError.incompleteSnapshot
        }
        let remaining = requiredWindows.subtracting(pending.completedWindows)
        let supplied = Set(snapshots.map(\.window))
        let attempted = attemptedWindows ?? snapshots.map(\.window)
        let requested = Set(attempted)
        guard pending.completedWindows.isSubset(of: requiredWindows), supplied.count == snapshots.count,
              requested.count == attempted.count, requested.isSubset(of: remaining), supplied.isSubset(of: requested),
              !attempted.isEmpty || remaining.isEmpty else {
            throw ImportError.incompleteSnapshot
        }
        return CommitContext(lane: lane, key: key, batch: batch, tombstones: tombstones,
                             requiredWindows: requiredWindows, supplied: supplied,
                             requested: requested, attempted: attempted)
    }

    /// 写窗口前捕获各窗口既有样本引用（同一 series 可跨多窗口）。
    nonisolated func knownReferences(binding: Binding, kind: HealthDataKind,
                                 snapshots: [HealthWindowSnapshot],
                                 db: Database) throws -> [HealthImportWindow: [HealthSampleReference]] {
        var knownByWindow: [HealthImportWindow: [HealthSampleReference]] = [:]
        for snapshot in snapshots {
            guard snapshot.window.kind == kind, snapshot.window.isValid else { throw ImportError.invalidValue }
            knownByWindow[snapshot.window] = try Row.fetchAll(db, sql: """
                SELECT * FROM hk_sample_index WHERE patient_id = ? AND type_key = ?
                  AND end_at >= ? AND start_at < ?
                """, arguments: [binding.patientId.uuidString, kind.rawValue,
                                  snapshot.window.start.timeIntervalSince1970,
                                  snapshot.window.end.timeIntervalSince1970])
                .map { try Self.decodeReference($0, kind: kind) }
        }
        return knownByWindow
    }

    /// 单窗口物化：校验 → 既有投影查询 → 完整性判定 → 删/保 → 行投影 → 索引回写。
    /// 返回是否判为完整窗口（不完整仅计数 deferredWindows，不写库）。
    nonisolated private func materializeSnapshot(_ snapshot: HealthWindowSnapshot,
                                     known: [HealthSampleReference],
                                     context: CommitContext, binding: Binding, kind: HealthDataKind,
                                     report: inout CommitReport, preserved: inout Set<String>,
                                     readings: inout [MetricReading], db: Database) throws -> Bool {
        let window = snapshot.window
        let visible = try Self.validatedReferences(snapshot.samples, kind: kind, calendar: binding.calendar)
        guard snapshot.samples.allSatisfy({ window.overlaps($0) }), snapshot.rejected >= 0 else { throw ImportError.invalidValue }
        let kept = Set(snapshot.rows.compactMap(\.sourceRef))
        guard kept.count == snapshot.rows.count else { throw ImportError.invalidValue }
        let rowsByIdentity = Dictionary(uniqueKeysWithValues: snapshot.rows.compactMap { row in
            row.sourceRef.map { ($0, row) }
        })
        for row in snapshot.rows {
            try Self.validateRow(row, window: window, visible: visible)
        }
        for reading in snapshot.readings {
            guard reading.origin == .device, let identity = reading.sampleID,
                  let row = rowsByIdentity[identity], row.value == reading.value, row.unit == reading.unit,
                  row.metricKey == reading.metricKey, row.measuredAt == reading.measuredAt,
                  row.sourceIdentifier == reading.sourceIdentifier else { throw ImportError.invalidValue }
        }

        let prior = try priorProjectionRows(binding: binding, kind: kind, window: window, db: db)
        let priorByIdentity = Dictionary(grouping: prior) { $0["source_ref"] as String }
        var complete = Set(visible.keys).isDisjoint(with: context.tombstones)
        // 2026-10-20（删除+重插自愈）：snapshot 有可见样本 = 读取证据。此时索引里
        // 不再可见的旧 UUID 视为已删除（Apple Watch 修订是删除+重插）；无可见样本时
        // 仍按「未知读取可见性」处理，绝不因权限消失清数据（既有契约测试钉死）。
        let hasSnapshotEvidence = !visible.isEmpty
        var staleKnown: [HealthSampleReference] = []
        for ref in known where !context.tombstones.contains(ref.id) {
            if let seen = visible[ref.id] {
                // The index stores Unix-epoch Doubles; comparing reference-epoch Dates can add rounding noise.
                guard seen.sourceID == ref.sourceID,
                      seen.start.timeIntervalSince1970 == ref.start.timeIntervalSince1970,
                      seen.end.timeIntervalSince1970 == ref.end.timeIntervalSince1970 else { throw ImportError.invalidValue }
            } else if hasSnapshotEvidence {
                staleKnown.append(ref)
            } else {
                complete = false
            }
        }
        // 本批刚上报的新样本看不见 = 读取不完整，永远不能当删除。
        for ref in context.batch.added where window.overlaps(ref) && !context.tombstones.contains(ref.id)
            && visible[ref.id] == nil {
            complete = false
        }
        let deletedHere = known.filter {
            context.tombstones.contains($0.id) && HealthImportWindow.covering($0, calendar: binding.calendar).contains(window)
        } + staleKnown
        let removable = Self.removableProjectionRows(prior: prior, kept: kept,
                                                     deletedHere: deletedHere, window: window, kind: kind)
        // A missing row is not a deletion either, even if its parent UUID was visible.
        for row in prior where (row["owned"] as Int) == 1 {
            if !kept.contains(row["source_ref"] as String), !removable.contains(row["id"] as String) { complete = false }
        }
        guard complete else { report.deferredWindows += 1; return false }

        for ref in staleKnown {
            try db.execute(sql: """
                DELETE FROM hk_sample_index
                WHERE sample_id = ? AND type_key = ? AND patient_id = ?
                """, arguments: [ref.id.uuidString, kind.rawValue, binding.patientId.uuidString])
        }
        report.staleReferences += staleKnown.count
        try applyRemovalsAndPreserves(prior: prior, removable: removable, kept: kept, kind: kind,
                                      report: &report, preserved: &preserved, db: db)
        try upsertSnapshotRows(snapshot.rows, priorByIdentity: priorByIdentity, kind: kind,
                               binding: binding, report: &report, preserved: &preserved, db: db)
        try upsertSampleIndex(snapshot.samples, kind: kind, binding: binding, db: db)
        readings.append(contentsOf: snapshot.readings)
        return true
    }

    /// 窗口内既有 device 来源投影行（owned = 有无投影态标记，排序保证 owned 行先于非自有行）。
    nonisolated func priorProjectionRows(binding: Binding, kind: HealthDataKind,
                                     window: HealthImportWindow, db: Database) throws -> [Row] {
        var arguments: [DatabaseValueConvertible] = [binding.id.uuidString, binding.patientId.uuidString,
                                                    window.identityPrefix + "%"]
        if !kind.isAggregated {
            arguments.append(window.start.timeIntervalSince1970)
            arguments.append(window.end.timeIntervalSince1970)
        }
        return try Row.fetchAll(db, sql: """
            SELECT m.id, m.source_ref, EXISTS(
              SELECT 1 FROM hk_projection_state p WHERE p.binding_id = ? AND p.metric_id = m.id) AS owned
            FROM metric_sample m WHERE m.patient_id = ? AND m.origin = 'device' AND m.source_ref LIKE ?
            \(kind.isAggregated ? "" : "AND m.measured_at >= ? AND m.measured_at < ?")
            ORDER BY owned DESC, m.id
            """, arguments: StatementArguments(arguments))
    }

    /// 可删投影行判定：自有行 + 未被本页保留 + 按类型满足删除证据条件。
    static func removableProjectionRows(prior: [Row], kept: Set<String>, deletedHere: [HealthSampleReference],
                                                window: HealthImportWindow, kind: HealthDataKind) -> Set<String> {
        let deletedIDs = Set(deletedHere.map(\.id))
        let deletedSources = Set(deletedHere.map(\.sourceID))
        return Set(prior.compactMap { row -> String? in
            let identity: String = row["source_ref"]
            guard (row["owned"] as Int) == 1, !kept.contains(identity) else { return nil }
            switch kind {
            case .heartRate:
                guard deletedSources.contains(String(identity.dropFirst(window.prefix.count))) else { return nil }
            case .steps, .sleep:
                // 2026-09-20 业主真机复测修复（「睡眠最近数据仍缺失」）：窗口派生
                // 聚合行（identity = window.prefix + key）的**重算即权威**——watch
                // 迟到样本并入后（如 unspecified 段被归并进 staged 段），旧键行在
                // 新快照中归零消失：既无 HealthKit 墓碑（样本未删、只是合并语义），
                // 也不在 kept 中——旧判据「无删除证据不可删」→ complete=false 永久
                // 冻结 → 锚点不推进 → 该类型此后再无新数据（业主症状的直接机制）。
                // 样本覆盖完整性已由 refs 级检查单独保证（known ⊆ visible 逐项验证），
                // 归零行删除不构成事实丢失——合并后的总量行才是该窗口的真相。
                break
            case .restingHeartRate, .bloodOxygen, .respiratoryRate:
                guard let id = HealthImportWindow.sampleID(fromIdentity: identity, kind: kind),
                      deletedIDs.contains(id) else { return nil }
            }
            return row["id"] as String
        })
    }

    /// 删可删行、登记保留行（非自有行或窗口仍存活的自有行）。
    nonisolated func applyRemovalsAndPreserves(prior: [Row], removable: Set<String>, kept: Set<String>,
                                           kind: HealthDataKind, report: inout CommitReport,
                                           preserved: inout Set<String>, db: Database) throws {
        for row in prior {
            let id: String = row["id"]
            guard UUID(uuidString: id) != nil else { throw ImportError.invalidValue }
            if removable.contains(id) {
                try db.execute(sql: "DELETE FROM metric_sample WHERE id = ?", arguments: [id])
                report.persistedRows += db.changesCount
            } else if (row["owned"] as Int) == 0, kind.isAggregated || !kept.contains(row["source_ref"] as String) {
                preserved.insert(id)
            }
        }
    }

    /// 设备行投影写入（自有行复用/刷新；legacy NULL 身份不被同时间戳行收养；恢复行保留的同时刷新自有行）。
    nonisolated func upsertSnapshotRows(_ rows: [DeviceMetricRow], priorByIdentity: [String: [Row]],
                                    kind: HealthDataKind, binding: Binding, report: inout CommitReport,
                                    preserved: inout Set<String>, db: Database) throws {
        for row in rows {
            guard let identity = row.sourceRef else { throw ImportError.invalidValue }
            let matches = priorByIdentity[identity] ?? []
            if kind.isAggregated {
                // Legacy NULL identities must not be adopted by a matching timestamp/name either.
                let legacy = try String.fetchAll(db, sql: """
                    SELECT id FROM metric_sample WHERE patient_id = ? AND origin = 'device' AND source_ref IS NULL
                      AND metric_key = ? AND measured_at = ? AND unit = ? AND source_name IS ?
                    """, arguments: [binding.patientId.uuidString, MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey,
                                     row.measuredAt.timeIntervalSince1970, row.unit, row.sourceName])
                let unowned = matches.filter { ($0["owned"] as Int) == 0 }.map { $0["id"] as String } + legacy
                if !unowned.isEmpty {
                    preserved.formUnion(unowned)
                    // 审查修复：同身份同时存在「备份恢复的非自有行」与
                    // 「投影态自有行」时，旧实现 preserve 后 continue——
                    // 自有行永不再刷新（窗口已判完成、锚点推进，后续
                    // 轮次仍走同一跳过分支），恢复前的陈旧值永久留存。
                    // 恢复行保留（防回退）的同时刷新自有行。
                    guard matches.contains(where: { ($0["owned"] as Int) == 1 }) else { continue }
                }
            }
            let id = (matches.first { ($0["owned"] as Int) == 1 }.map { $0["id"] as String })
                ?? (matches.first.map { $0["id"] as String }) ?? UUID().uuidString
            guard UUID(uuidString: id) != nil else { throw ImportError.invalidValue }
            report.persistedRows += try Self.writeProjection(row, id: id, patientId: binding.patientId, db: db)
            try db.execute(sql: """
                INSERT INTO hk_projection_state (binding_id, metric_id) VALUES (?, ?)
                ON CONFLICT(binding_id, metric_id) DO NOTHING
                """, arguments: [binding.id.uuidString, id])
        }
    }

    /// 样本索引回写（同样本同类型按最新来源/区间 upsert）。
    nonisolated func upsertSampleIndex(_ samples: [HealthSampleReference], kind: HealthDataKind,
                                   binding: Binding, db: Database) throws {
        for ref in samples {
            try db.execute(sql: """
                INSERT INTO hk_sample_index (sample_id, type_key, patient_id, source_id, start_at, end_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(sample_id, type_key, patient_id) DO UPDATE SET
                  source_id = excluded.source_id, start_at = excluded.start_at, end_at = excluded.end_at
                """, arguments: [ref.id.uuidString, kind.rawValue, binding.patientId.uuidString,
                                  ref.sourceID, ref.start.timeIntervalSince1970, ref.end.timeIntervalSince1970])
        }
    }

    /// commit 前置闸门产物（门禁全过后提取的提交上下文，供物化循环与尾声共用）。
    private struct CommitContext {
        let lane: HealthFetchLane
        let key: String
        let batch: HealthChangeBatch
        let tombstones: Set<UUID>
        let requiredWindows: Set<HealthImportWindow>
        let supplied: Set<HealthImportWindow>
        let requested: Set<HealthImportWindow>
        let attempted: [HealthImportWindow]
    }

    private static func deletedReferences(_ ids: [UUID], binding: Binding, kind: HealthDataKind,
                                           db: Database) throws -> [HealthSampleReference] {
        var references: [HealthSampleReference] = []
        for offset in stride(from: 0, to: ids.count, by: 500) {
            let page = ids[offset..<min(offset + 500, ids.count)].map(\.uuidString)
            let placeholders = Array(repeating: "?", count: page.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM hk_sample_index WHERE type_key = ? AND patient_id = ? AND sample_id IN (\(placeholders))
                """, arguments: StatementArguments([kind.rawValue, binding.patientId.uuidString] + page))
            references.append(contentsOf: try rows.map { try decodeReference($0, kind: kind) })
        }
        return references
    }

    static func decodeReference(_ row: Row, kind: HealthDataKind) throws -> HealthSampleReference {
        guard let id = UUID(uuidString: row["sample_id"] as String),
              (row["type_key"] as String) == kind.rawValue else { throw ImportError.invalidValue }
        let ref = HealthSampleReference(id: id, kind: kind, sourceID: row["source_id"],
            start: Date(timeIntervalSince1970: row["start_at"]), end: Date(timeIntervalSince1970: row["end_at"]))
        guard ref.isValid else { throw ImportError.invalidValue }
        return ref
    }

    static func validatedReferences(_ references: [HealthSampleReference], kind: HealthDataKind,
                                             calendar: Calendar) throws -> [UUID: HealthSampleReference] {
        var result: [UUID: HealthSampleReference] = [:]
        for ref in references {
            guard ref.kind == kind, ref.isValid, !HealthImportWindow.covering(ref, calendar: calendar).isEmpty else {
                throw ImportError.invalidValue
            }
            if let prior = result[ref.id], prior != ref { throw ImportError.invalidValue }
            result[ref.id] = ref
        }
        return result
    }

    private static func pending(binding: Binding, kind: HealthDataKind, db: Database) throws -> PendingBatch? {
        guard let json = try String.fetchOne(db, sql: "SELECT payload_json FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                                            arguments: [binding.id.uuidString, kind.rawValue]) else { return nil }
        let pending = try JSONDecoder().decode(PendingBatch.self, from: Data(json.utf8))
        // round2 H-N1：v2 单道时代的载荷缺 lane——其锚点属于已弃用的无谓词查询，不能续接任何一道；
        // 作废该行（取数进度不是物化检查点，重取安全），否则该类型永久卡死。
        // 2026-10-20：单页 pending（version 2）。旧整道累积载荷（缺 version / >500 refs）
        // 一并作废，并清 fetch cursor——否则游标已越过未物化页会漏数据；从
        // committed anchor 重放（幂等）。
        guard pending.lane != nil, pending.version == 2,
              pending.batch.added.count <= 500 else {
            try db.execute(sql: "DELETE FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                           arguments: [binding.id.uuidString, kind.rawValue])
            try Self.deleteFetchCursors(db, bindingId: binding.id, kind: kind)
            return nil
        }
        guard !pending.batch.anchor.isEmpty, pending.reconcileAfter?.timeIntervalSince1970.isFinite != false,
              pending.completedWindows.allSatisfy({ $0.kind == kind && $0.isValid }) else { throw ImportError.invalidValue }
        _ = try validatedReferences(pending.batch.added, kind: kind, calendar: binding.calendar)
        return pending
    }

    private static func savePending(_ pending: PendingBatch, binding: Binding, kind: HealthDataKind, db: Database) throws {
        let json = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO hk_pending_batch (binding_id, type_key, payload_json) VALUES (?, ?, ?)
            ON CONFLICT(binding_id, type_key) DO UPDATE SET payload_json = excluded.payload_json
            """, arguments: [binding.id.uuidString, kind.rawValue, json])
    }

    static func validateRow(_ row: DeviceMetricRow, window: HealthImportWindow,
                                    visible: [UUID: HealthSampleReference]) throws {
        guard let identity = row.sourceRef, window.contains(sourceRef: identity, measuredAt: row.measuredAt),
              row.value.isFinite, row.valueMin?.isFinite != false, row.valueMax?.isFinite != false,
              row.windowEnd?.timeIntervalSince1970.isFinite != false, row.sampleCount.map({ $0 >= 0 }) != false,
              !row.unit.isEmpty else { throw ImportError.invalidValue }
        let key = MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey
        let allowed: Set<String>
        switch window.kind {
        case .heartRate: allowed = ["heartRate"]
        case .restingHeartRate: allowed = ["restingHeartRate"]
        case .bloodOxygen: allowed = ["bloodOxygen"]
        case .respiratoryRate: allowed = ["respiratory_rate"]
        case .steps: allowed = ["steps"]
        case .sleep: allowed = Set(MetricType.sleepGroupKeys.map(\.rawValue))   // 六键单一事实源（Domain），新增阶段只改一处
        }
        guard allowed.contains(key) else { throw ImportError.invalidValue }
        if !window.kind.isAggregated {
            guard let id = HealthImportWindow.sampleID(fromIdentity: identity, kind: window.kind),
                  let ref = visible[id], row.measuredAt >= ref.start, row.measuredAt <= ref.end,
                  row.sourceIdentifier == nil || row.sourceIdentifier == ref.sourceID else { throw ImportError.invalidValue }
        } else if window.kind == .heartRate {
            let source = String(identity.dropFirst(window.prefix.count))
            guard visible.values.contains(where: { $0.sourceID == source }),
                  row.sourceIdentifier == nil || row.sourceIdentifier == source else { throw ImportError.invalidValue }
        } else {
            guard identity == window.prefix + (window.kind == .steps ? "sum" : key), !visible.isEmpty else { throw ImportError.invalidValue }
        }
    }

    /// Identity-only writes: timestamp/source-name matching cannot prove a restored sample's provenance.
    private static func writeProjection(_ row: DeviceMetricRow, id: String, patientId: UUID, db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded,
              value_min, value_max, sample_count, source_name, source_version, source_product, source_ref,
              source_identifier, aggregation_kind, window_end, measured_at, created_at)
            VALUES (?, ?, ?, ?, ?, 'device', 1, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET metric_key = excluded.metric_key, value = excluded.value, unit = excluded.unit,
              value_min = excluded.value_min, value_max = excluded.value_max, sample_count = excluded.sample_count,
              source_name = excluded.source_name, source_version = excluded.source_version, source_product = excluded.source_product,
              source_identifier = excluded.source_identifier, aggregation_kind = excluded.aggregation_kind,
              window_end = excluded.window_end, measured_at = excluded.measured_at
            WHERE metric_sample.metric_key IS NOT excluded.metric_key OR metric_sample.value IS NOT excluded.value
              OR metric_sample.unit IS NOT excluded.unit OR metric_sample.value_min IS NOT excluded.value_min
              OR metric_sample.value_max IS NOT excluded.value_max OR metric_sample.sample_count IS NOT excluded.sample_count
              OR metric_sample.source_name IS NOT excluded.source_name OR metric_sample.source_version IS NOT excluded.source_version
              OR metric_sample.source_product IS NOT excluded.source_product OR metric_sample.source_identifier IS NOT excluded.source_identifier
              OR metric_sample.aggregation_kind IS NOT excluded.aggregation_kind OR metric_sample.window_end IS NOT excluded.window_end
              OR metric_sample.measured_at IS NOT excluded.measured_at
            """, arguments: [id, patientId.uuidString, MetricType(grammarKey: row.metricKey)?.rawValue ?? row.metricKey,
                              row.value, row.unit, row.valueMin, row.valueMax, row.sampleCount, row.sourceName, row.sourceVersion,
                              row.sourceProduct, row.sourceRef, row.sourceIdentifier, row.aggregation?.rawValue,
                              row.windowEnd?.timeIntervalSince1970, row.measuredAt.timeIntervalSince1970, Date().timeIntervalSince1970])
        return db.changesCount
    }

    static func requireBinding(_ binding: Binding, db: Database) throws {
        guard try Self.binding(db) == binding, try ownerPatient(db) == binding.patientId else { throw ImportError.bindingChanged }
    }

    /// round2 H-N1：v3 键空间按道分列；v2 键弃用——谓词变了，旧锚点不跨谓词复用（零 DDL：同表新键）。
    /// 2026-09-19：recent 道 v4——游标语义换成降序首填（JSON 游标），旧 v3 锚点
    /// （HKQueryAnchor）不跨游标方案复用；history 道维持 v3。
    private static func anchorKey(_ binding: Binding, _ kind: HealthDataKind, _ lane: HealthFetchLane) -> String {
        if lane == .recent {
            return "hk.v4.\(binding.id.uuidString).\(kind.rawValue).recent"
        }
        // history：.all 沿用旧键（已有用户进度不重扫）；有限深度必须携带深度，
        // 否则改深度后旧锚点会被错误复用（谓词已变）。
        guard let days = binding.historyDepth.days else {
            return "hk.v3.\(binding.id.uuidString).\(kind.rawValue).history"
        }
        return "hk.v6.\(binding.id.uuidString).\(kind.rawValue).history.\(days)"
    }

    /// 取数游标键（与 committed anchor 分表同表不同键；无 DDL）。
    /// history 深度已编码进 committed key；fetch key 同样携带，避免改深度后误续。
    private static func fetchAnchorKey(_ binding: Binding, _ kind: HealthDataKind,
                                       _ lane: HealthFetchLane) -> String {
        if lane == .recent {
            return "hk.f1.\(binding.id.uuidString).\(kind.rawValue).recent"
        }
        if let days = binding.historyDepth.days {
            return "hk.f1.\(binding.id.uuidString).\(kind.rawValue).history.\(days)"
        }
        return "hk.f1.\(binding.id.uuidString).\(kind.rawValue).history"
    }

    private static func fetchCursor(_ db: Database, key: String) throws -> Data? {
        try anchor(db, key: key)
    }

    private static func saveFetchCursor(_ db: Database, key: String, anchor: Data) throws {
        try db.execute(sql: """
            INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value,
              updated_at = excluded.updated_at
            """, arguments: [key, anchor.base64EncodedString(), Date().timeIntervalSince1970])
    }

    private static func deleteFetchCursors(_ db: Database, bindingId: UUID,
                                           kind: HealthDataKind) throws {
        try db.execute(sql: "DELETE FROM hk_sync_anchor WHERE anchor_key LIKE ?",
                       arguments: ["hk.f1.\(bindingId.uuidString).\(kind.rawValue).%"])
    }

    /// 深度缩小到已被完成态覆盖的范围时，把旧深度的 history committed anchor
    /// 复制到新深度键：增量只从流末端接后续变化，不重扫已覆盖历史。
    /// 只在新键为空时复制；旧 anchor 的谓词是更宽/相同的超集，作为起点安全。
    static func copyHistoryAnchor(_ db: Database, binding: Binding, kind: HealthDataKind,
                                  from oldDepth: HealthHistoryDepth,
                                  to newDepth: HealthHistoryDepth) throws {
        guard oldDepth != newDepth else { return }
        let oldBinding = Binding(id: binding.id, patientId: binding.patientId,
                                 timeZoneID: binding.timeZoneID, connectedAt: binding.connectedAt,
                                 historyDepth: oldDepth)
        let newBinding = Binding(id: binding.id, patientId: binding.patientId,
                                 timeZoneID: binding.timeZoneID, connectedAt: binding.connectedAt,
                                 historyDepth: newDepth)
        let oldKey = anchorKey(oldBinding, kind, .history)
        let newKey = anchorKey(newBinding, kind, .history)
        guard oldKey != newKey, try anchor(db, key: newKey) == nil,
              let value = try anchor(db, key: oldKey) else { return }
        try db.execute(sql: "DELETE FROM hk_sync_anchor WHERE anchor_key = ?",
                       arguments: [fetchAnchorKey(newBinding, kind, .history)])
        try db.execute(sql: """
            INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value,
              updated_at = excluded.updated_at
            """, arguments: [newKey, value.base64EncodedString(), Date().timeIntervalSince1970])
    }

    /// 旧方案的 recent 锚点键（一次性作废用，见 `prepareRecentLane`）。
    private static func legacyRecentAnchorKey(_ binding: Binding, _ kind: HealthDataKind) -> String {
        "hk.v3.\(binding.id.uuidString).\(kind.rawValue).recent"
    }

    /// 2026-09-19 审查修复（recent 道降序首填）：v4 游标不存在时一次性作废
    /// 旧 v3 recent 锚点与旧在途 recent 批次——降序首填按样本 id 幂等重排，
    /// HealthKit 是事实源（重排无数据丢失）。幂等：仅 v4 游标缺失时执行；
    /// 升版首轮后 v4 存在，本方法零开销。必须在 pendingBatch 读取**之前**调用
    /// （否则旧批次锚点与空 v4 游标互斥 → staleAnchor 永久卡死该类型）。
    public func prepareRecentLane(binding: Binding, kind: HealthDataKind) async throws {
        try await writer.write { db in
            try Self.requireBinding(binding, db: db)
            if try Self.anchor(db, key: Self.anchorKey(binding, kind, .recent)) != nil { return }
            // 2026-10-20：v4 committed anchor 只在 recent 道最终空页后推进；fetch cursor
            // 与 valid v2 pending 同样是“降序首填已开始”的证据。旧实现只查 committed
            // anchor，导致首填每轮误删在途 recent pending（v4 始终未到道末）。
            if try Self.fetchCursor(db, key: Self.fetchAnchorKey(binding, kind, .recent)) != nil { return }
            do {
                if let current = try Self.pending(binding: binding, kind: kind, db: db),
                   current.lane == .recent { return }
            } catch ImportError.invalidValue {
                // 旧方案损坏/缺 lane 载荷：一并作废（降序首填重新暂存）
                try db.execute(sql: "DELETE FROM hk_pending_batch WHERE binding_id = ? AND type_key = ?",
                               arguments: [binding.id.uuidString, kind.rawValue])
            }
            try db.execute(sql: "DELETE FROM hk_sync_anchor WHERE anchor_key = ?",
                           arguments: [Self.legacyRecentAnchorKey(binding, kind)])
        }
    }

    private static func anchor(_ db: Database, key: String) throws -> Data? {
        guard let encoded = try String.fetchOne(db, sql: "SELECT anchor_value FROM hk_sync_anchor WHERE anchor_key = ?",
                                               arguments: [key]) else { return nil }
        guard let data = Data(base64Encoded: encoded) else { throw ImportError.staleAnchor }
        return data
    }

    static func binding(_ db: Database) throws -> Binding? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM hk_import_binding WHERE singleton = 1") else { return nil }
        guard let id = UUID(uuidString: row["id"]), let patient = UUID(uuidString: row["patient_id"]),
              TimeZone(identifier: row["time_zone"] as String) != nil,
              let connectedAt = row["connected_at"] as Double?, connectedAt.isFinite else {
            throw ImportError.bindingChanged
        }
        let planRow = try Row.fetchOne(db,
            sql: "SELECT history_days FROM hk_import_plan WHERE binding_id = ?",
            arguments: [id.uuidString])
        let days = planRow?["history_days"] as Int?
        return Binding(id: id, patientId: patient, timeZoneID: row["time_zone"],
                       connectedAt: Date(timeIntervalSince1970: connectedAt),
                       historyDepth: Self.depth(fromDays: days))
    }

    /// v36 plan 行补齐（旧库/中断）：只 INSERT，不覆盖用户已选深度。
    static func ensurePlan(_ db: Database, bindingId: UUID, connectedAt: Date,
                                   depth: HealthHistoryDepth) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO hk_import_plan
              (binding_id, history_days, selected_at, updated_at, initial_completed_at)
            VALUES (?, ?, ?, ?, NULL)
            """, arguments: [bindingId.uuidString, depth.days,
                             connectedAt.timeIntervalSince1970, Date().timeIntervalSince1970])
    }

    static func depth(fromDays days: Int?) -> HealthHistoryDepth {
        guard let days else { return .all }
        if days <= 365 { return .oneYear }
        if days <= 1_825 { return .fiveYears }
        return .all
    }

    static func days(fromDepth depth: HealthHistoryDepth) -> Int? { depth.days }

    static func ownerPatient(_ db: Database) throws -> UUID? {
        let id = try String.fetchOne(db, sql: """
            SELECT p.id FROM local_owner o JOIN patient_profile p ON p.id = o.self_patient_id
            WHERE p.deleted_at IS NULL LIMIT 1
            """)
        guard let id else { return nil }
        guard let patient = UUID(uuidString: id) else { throw ImportError.invalidValue }
        return patient
    }

    static func requireEnabled(_ db: Database) throws {
        let value = try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?",
                                       arguments: [AppSettingKey.authHealthRead.rawValue])
        guard SettingsRules.resolved(value, key: .authHealthRead) == "true" else { throw ImportError.disabled }
    }
}
#endif
