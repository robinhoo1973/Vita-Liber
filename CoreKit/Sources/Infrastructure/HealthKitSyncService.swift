#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain
import Protocols
#if os(iOS)
import BackgroundTasks
import HealthKit
#endif

/// One coordinator for foreground, manual and background import. Actor reentrancy is explicitly coalesced.
public actor HealthKitSyncService {

    private let provider: any HealthReadingProvider
    /// 写回通道（业主 2026-09-17 定）。可选：既有测试替身只实现读契约，
    /// 生产装配以同一 HealthKitReader 实例双协议注入。nil = 不可写（预览/测试）。
    private let writer: (any HealthWritingProvider)?
    private let imports: HealthImportStore
    private let guidelines: GuidelineStore
    private let scheduler: any ReminderScheduling
    private static let windowsPerRound = 32
    private var inFlight: Task<SyncReport, Error>?
    private var inFlightID: UUID?
    /// C1-5（2026-10-04 评审）：共享轮次启动时刻——join 者陈旧检测用；
    /// 仅在 inFlight 非 nil 时有意义，创建时随 inFlight 同置，读只发生在 join 支路
    /// （轮次结束后的旧时钟不会再被读——新轮次创建时必重写）。
    private var inFlightStartedAt: Date?
    /// join 陈旧阈值（默认 120s；测试注入小值）——超阈值抛 staleFlight，
    /// 只记账不杀共享任务（「只有创建者持取消权」契约不变）。
    /// public：App 级测试目标（VitaLiberTests，无 Infrastructure @testable 面）注入小值
    /// 所需（同 BackgroundAssertionBox 公开先例——Linux 平台守卫零编译信号，访问级别错
    /// 只 L1 可见）。
    public nonisolated(unsafe) static var joinStaleThresholdSeconds: TimeInterval = 120
    public private(set) var latestReport: SyncReport?
    /// 2026-10-20：回填请求去重。旧实现每轮 cancel+submit，earliestBeginDate
    /// 被反复推到 now+60min，活跃设备上 BGProcessing 可能永远排不上。
    private var lastBackfillRequestAt: Date?

    public init(provider: any HealthReadingProvider, writer: (any HealthWritingProvider)? = nil,
                imports: HealthImportStore, guidelines: GuidelineStore,
                scheduler: any ReminderScheduling) {
        self.provider = provider; self.writer = writer; self.imports = imports
        self.guidelines = guidelines; self.scheduler = scheduler
    }

    public func connect(depth: HealthHistoryDepth = .all) async throws -> HealthImportStore.Binding {
        guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
        try await provider.requestAuthorization()
        // A completed request says nothing about individual read permissions.
        let binding = try await imports.connect(depth: depth)
        #if os(iOS)
        await maintainBackgroundAutomation()
        #endif
        return binding
    }

    /// 激活/连接时判定：初始回填（断点续）或只更新缺失部分。
    public func importMode() async throws -> HealthImportMode { try await imports.importMode() }
    public func plan() async throws -> HealthImportPlan? { try await imports.plan() }

    @discardableResult
    public func setHistoryDepth(_ depth: HealthHistoryDepth) async throws -> HealthImportStore.Binding? {
        let binding = try await imports.setHistoryDepth(depth)
        #if os(iOS)
        await maintainBackgroundAutomation()
        #endif
        return binding
    }

    /// 特征型（血型/出生日期/生理性别）只读读取（业主 2026-09-17 定：导入走档案候选）。
    public func characteristics() async throws -> HealthCharacteristics { try await provider.characteristics() }

    /// 仅特征型的授权请求（首启注册预填的最小请求；授权单只出现健康档案资料）。
    public func requestCharacteristicAuthorization() async throws {
        try await provider.requestCharacteristicAuthorization()
    }

    /// 写回授权（分享权限可观察——与读取侧不同，见 HealthWritingProvider 注记）。
    public func requestWriteAuthorization() async throws {
        guard let writer else { throw HealthWriteError.unavailable }
        try await writer.requestWriteAuthorization()
    }

    public func writeAuthorizationStatus() async -> HealthWriteAuthStatus {
        await writer?.writeAuthorizationStatus() ?? .notDetermined
    }

    /// 写回样本（best-effort 单向通道）：调用方已在本库落库成功，此通道失败不溯及已保存记录。
    @discardableResult
    public func writeBack(_ samples: [HealthSampleDraft]) async throws -> Int {
        guard let writer else { return 0 }
        return try await writer.writeBack(samples)
    }

    public func connection() async throws -> HealthImportStore.Binding? { try await imports.connection() }
    public func dashboard() async throws -> HealthImportDashboard { try await imports.dashboard() }
    public func importedRows(kind: HealthDataKind, before: HealthImportRow? = nil) async throws -> [HealthImportRow] {
        try await imports.importedRows(kind: kind, before: before)
    }
    public func isAvailable() async -> Bool { await provider.isAvailable() }
    public func canAutomaticallySync() async throws -> Bool {
        guard try await imports.automaticImportEnabled() else { return false }
        return try await canSync()
    }

    public func canSync() async throws -> Bool {
        guard await provider.isAvailable(), try await imports.isEnabled() else { return false }
        return try await imports.connection() != nil
    }

    public func cancelSync() { inFlight?.cancel() }

    /// FR16.3 排空轮询（服务层聚合）：循环 `performSync` 直至排空（hasMore=false）
    /// 或时间预算耗尽，多轮报告聚合成单份终态。
    ///
    /// I2 审查修复：该循环与聚合此前内联在 App 层 F16DeviceState.sync
    /// （视图状态对象承载服务语义，违反分层纪律）——下移后状态对象只消费
    /// 一次报告。取消经 Task.checkCancellation 逐轮复核（performSync 内部
    /// 亦逐窗口复核）；performSync 的 inFlight 合并语义不变。
    public func performSyncAll(quietStart: String, quietEnd: String,
                               maxRounds: Int = 20,
                               timeBudget: Duration = .seconds(30),
                               /// 后台投递专用：已有共享轮次时最多等这么久（不杀共享任务）。
                               joinTimeout: Duration? = nil,
                               /// 每轮完成的进度回调（C6 评审修复：iOS 26 continued processing
                               /// 要求全程上报 NSProgress，否则系统优先终止无进度任务）
                               onRound: (@Sendable (Int) -> Void)? = nil) async throws -> SyncReport {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: timeBudget)
        var total: SyncReport?
        for roundIndex in 0..<max(1, maxRounds) {
            try Task.checkCancellation()
            let result = try await performSync(quietStart: quietStart, quietEnd: quietEnd,
                                               joinTimeout: joinTimeout, deadline: deadline)
            onRound?(roundIndex + 1)
            if var aggregate = total, aggregate.bindingId == result.bindingId, aggregate.patientId == result.patientId {
                aggregate.persistedRows += result.persistedRows
                aggregate.receivedChanges += result.receivedChanges
                aggregate.elevated += result.elevated
                aggregate.preservedRows += result.preservedRows
                aggregate.rejectedSamples += result.rejectedSamples
                aggregate.notificationFailures += result.notificationFailures
                // 终态失败以末轮为准：早期轮次的瞬时失败（查询抖动/待排空页）
                // 后续轮次已恢复者不得永久挂在「部分类型导入失败」上
                // （owner round10 实测：瞬态失败被并集语义钉死为永久假警报）。
                aggregate.failedTypes = result.failedTypes
                aggregate.hasMore = result.hasMore
                aggregate.deferredWindows = result.deferredWindows
                aggregate.lastSyncAt = result.lastSyncAt
                // round2 H-N1/H-N2：稀疏窗累计；剩余窗口/当前道以末轮为准（与 failedTypes 同律）
                if aggregate.sparseWindows != nil || result.sparseWindows != nil {
                    aggregate.sparseWindows = (aggregate.sparseWindows ?? 0) + (result.sparseWindows ?? 0)
                }
                aggregate.remainingWindows = result.remainingWindows
                aggregate.backfillLane = result.backfillLane
                // 2026-09-19 审查修复：perKindRemaining 随其余「末轮为准」字段一并合并——
                // 漏合并时终态报告永远携带首轮的按类剩余数（多轮排空已收敛到 0 后
                // 类别卡进度仍按首轮基数倒退，且入库 report_json 误导下一会话基线）。
                if result.perKindRemaining != nil || aggregate.perKindRemaining != nil {
                    var merged = aggregate.perKindRemaining ?? [:]
                    for (key, remaining) in result.perKindRemaining ?? [:] { merged[key] = remaining }
                    aggregate.perKindRemaining = merged
                }
                // C1 埋点合并：轮数/样本/查询按累计，失败摘要并集（同律于 failedTypes 末轮为准，
                // 但诊断需保留全程失败记录）
                aggregate.rounds = (aggregate.rounds ?? 0) + (result.rounds ?? 1)
                if result.perKindSamples != nil || aggregate.perKindSamples != nil {
                    var merged = aggregate.perKindSamples ?? [:]
                    for (key, count) in result.perKindSamples ?? [:] { merged[key] = count }
                    aggregate.perKindSamples = merged
                }
                if result.perKindQueries != nil || aggregate.perKindQueries != nil {
                    var merged = aggregate.perKindQueries ?? [:]
                    for (key, count) in result.perKindQueries ?? [:] { merged[key] = count }
                    aggregate.perKindQueries = merged
                }
                if let failures = result.lastFailures {
                    var merged = aggregate.lastFailures ?? []
                    for f in failures where !merged.contains(f) { merged.append(f) }
                    aggregate.lastFailures = merged
                }
                // C1-8d（2026-10-04 评审）：三遥测字段随「末轮为准」律合并——
                // 失败原因并集去重、合并加入计数累计（与 lastFailures 同律）。
                if let reasons = result.failureReasons {
                    var merged = aggregate.failureReasons ?? []
                    for r in reasons where !merged.contains(r) { merged.append(r) }
                    aggregate.failureReasons = merged
                }
                if result.coalescedJoiners != nil || aggregate.coalescedJoiners != nil {
                    aggregate.coalescedJoiners = (aggregate.coalescedJoiners ?? 0) + (result.coalescedJoiners ?? 0)
                }
                total = aggregate
            } else {
                total = result
            }
            if !result.hasMore || start.duration(to: .now) >= timeBudget { break }
        }
        // maxRounds ≥ 1 时首轮必产出；守卫兜底无绑定（missingOwner 与
        // performSync 内部缺失绑定的失败语义一致）。
        guard var total else { throw HealthImportStore.ImportError.missingOwner }
        // C1-8d：总墙钟时长（诊断「慢」的每唤醒归因；ContinuousClock 起止差）
        let elapsed = start.duration(to: .now)
        total.wallTime = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return total
    }

    public func performSync(quietStart: String, quietEnd: String,
                            joinTimeout: Duration? = nil,
                            deadline: ContinuousClock.Instant? = nil) async throws -> SyncReport {
        try Task.checkCancellation()
        if let inFlight {
            // C1-5 join 陈旧检测：共享轮次超过阈值仍无终态（疑似 HK 查询悬挂）时，
            // 本 join 者返回 staleFlight 而非无限排队——此前四路（observer/refresh/
            // backfill/回前台）全部合并排队到同一个死任务、每唤醒预算打水漂。
            if let startedAt = inFlightStartedAt,
               Date().timeIntervalSince(startedAt) >= Self.joinStaleThresholdSeconds {
                throw HealthImportStore.ImportError.staleFlight
            }
            var report: SyncReport
            if let joinTimeout {
                report = try await Self.awaitJoin(inFlight, timeout: joinTimeout)
            } else {
                report = try await inFlight.value
            }
            try Task.checkCancellation()
            // C1-8c（2026-10-04 评审）：合并加入计数——「四路撞车」频率的量化事实
            // （observer/refresh/backfill/回前台并发时共享同一轮次是预期行为，
            // 计数使合并频率可观测，为唤醒源分型的收益评估供数）。
            report.coalescedJoiners = (report.coalescedJoiners ?? 0) + 1
            return report
        }
        let id = UUID()
        inFlightID = id
        inFlightStartedAt = Date()   // C1-5：随新轮次同置（join 支路陈旧检测的时间基准）
        let task = Task { try await self.runAndRecord(id: id, quietStart: quietStart, quietEnd: quietEnd,
                                                      deadline: deadline) }
        inFlight = task
        // Only the creator owns cancellation of shared work. Registration also closes the startup race.
        let report = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let report = try await task.value
            try Task.checkCancellation()
            return report
        } onCancel: {
            task.cancel()
        }
        return report
    }

    /// 有界 join：只放弃“等待”，不取消共享轮次（只有创建者持取消权）。
    ///
    /// 不用 `withThrowingTaskGroup`：`task.value` 不响应子任务取消，group 退出时
    /// 仍会等待 waiter 子任务——超时无法真正返回。改用 continuation + 一次性
    /// resume 的竞速；等待共享任务的 Task 留在后台，不阻塞调用方。
    private static func awaitJoin(_ task: Task<SyncReport, Error>,
                                  timeout: Duration) async throws -> SyncReport {
        let race = JoinRace()
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do { race.finish(continuation, .success(try await task.value)) }
                catch { race.finish(continuation, .failure(error)) }
            }
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                race.finish(continuation, .failure(HealthImportStore.ImportError.busy))
            }
        }
    }

    private final class JoinRace: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func finish(_ continuation: CheckedContinuation<SyncReport, Error>,
                    _ result: Result<SyncReport, Error>) {
            lock.lock()
            let shouldResume = !finished
            finished = true
            lock.unlock()
            if shouldResume { continuation.resume(with: result) }
        }
    }

    /// 合并调用者共享整个轮次，含状态落盘；完成后才释放flight，避免反复加入已完成任务。
    private func runAndRecord(id: UUID, quietStart: String, quietEnd: String,
                              deadline: ContinuousClock.Instant? = nil) async throws -> SyncReport {
        defer { if inFlightID == id { inFlight = nil; inFlightID = nil } }
        var report = try await run(quietStart: quietStart, quietEnd: quietEnd, deadline: deadline)
        // C1 埋点：每轮累计轮数（必须先 run 再计数——此前写在 let report 声明前，
        // macOS CI 编译报 use of local variable before declaration；Linux 因
        // HealthKit 平台守卫编译桩单元而全盲，属 macOS 可见面型检盲区）
        report.rounds = (report.rounds ?? 0) + 1
        try Task.checkCancellation()
        try await imports.saveReport(report)
        latestReport = report
        #if os(iOS)
        // round5 Q2：每轮终态有积压即申请一次分钟级回填（系统在设备空闲时唤起排空，不再只靠 30 秒刷新与回前台）
        requestBackfillIfNeeded(report)
        #endif
        return report
    }

    private struct DrainOutcome {
        var hadWork: Bool
        var hasMore: Bool
        /// 该道最终页已提交且无查询失败/延迟窗口（可标记类型完成）。
        var laneComplete: Bool = false
    }

    private func run(quietStart: String, quietEnd: String,
                     deadline: ContinuousClock.Instant? = nil) async throws -> SyncReport {
        try Task.checkCancellation()
        // round2 H3/H-N4：开关关闭是独立失败态，不再与缺本人档案混为 missingOwner（视图三态文案依赖分型）
        guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
        guard let binding = try await imports.connection() else { throw HealthImportStore.ImportError.missingOwner }
        var report = SyncReport(lastSyncAt: Date(), bindingId: binding.id, patientId: binding.patientId)
        let scopes = imports.scopes(for: binding)
        // Fetch one page per type/round. Drained work resumes by window without losing the old checkpoint.
        for kind in HealthDataKind.allCases {
            // 轮内 deadline：不再只在轮间检查预算。一次投递/一次 BGProcessing
            // 到期前必须能停下来提交已做窗口，否则 completion/上报都来不及。
            if let deadline, ContinuousClock.now >= deadline {
                report.hasMore = true
                break
            }
            var hasPending = false
            do {
                try Task.checkCancellation()
                guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                // 2026-09-19 审查修复（recent 道降序首填）：v4 游标方案的一次性迁移——
                // 必须在 pendingBatch 读取前执行（旧 v3 recent 批次锚点与新空游标
                // 互斥会 staleAnchor 永久卡死）。v4 已存在时零开销。
                try await imports.prepareRecentLane(binding: binding, kind: kind)
                var existing = try await imports.pendingBatch(binding: binding, kind: kind)
                // 深度变小后旧道 pending 已不在 scopes 内：丢弃它，避免该类型永久
                // staleAnchor（例如 5 年→1 年残留 history pending）。
                if let lane = existing?.lane, !scopes.contains(where: { $0.lane == lane }) {
                    try await imports.discardPending(kind: kind)
                    existing = nil
                }
                // 2026-10-20 业主裁决：不再“recent 有工作即 break”。
                // - pending 道先做（断点续导）；
                // - 该页提交后若已无 pending，同轮继续另一道（历史道不再被 recent 饿死）；
                // - 只有仍有 pending 时才停（单类单 pending 的既有约束）。
                let order: [HealthFetchScope]
                if let inFlight = existing?.lane, let first = scopes.first(where: { $0.lane == inFlight }) {
                    order = [first] + scopes.filter { $0.lane != inFlight }
                } else {
                    order = scopes
                }
                var recentComplete = false
                for scope in order {
                    let outcome = try await drain(kind: kind, scope: scope, binding: binding,
                                                  existing: existing?.lane == scope.lane ? existing : nil,
                                                  report: &report, deadline: deadline)
                    hasPending = hasPending || outcome.hasMore
                    // 业主 2026-10-20：完成态只在“该道最终空页提交”时落盘。
                    // 失败/延迟窗口由 drain 的 laneComplete 过滤，绝不把半成品标完成。
                    if outcome.laneComplete {
                        switch scope.lane {
                        case .recent:
                            recentComplete = true
                            try await imports.markRecentComplete(kind: kind)
                        case .history:
                            try await imports.markHistoryComplete(kind: kind, depth: binding.historyDepth)
                        }
                    }
                    let stillPending = try await imports.pendingBatch(binding: binding, kind: kind)
                    if stillPending != nil { break }
                }
                // 1 年档没有 history 查询（区间为空）；recent 完成即视为 history 覆盖完成。
                if recentComplete, !scopes.contains(where: { $0.lane == .history }) {
                    try await imports.markHistoryComplete(kind: kind, depth: binding.historyDepth)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch HealthImportStore.ImportError.disabled {
                throw HealthImportStore.ImportError.disabled
            } catch HealthImportStore.ImportError.bindingChanged {
                throw HealthImportStore.ImportError.bindingChanged
            } catch {
                // 失败类型可能仍有在途批次；保守置 hasMore，触发一次回填重试。
                hasPending = true
                report.failedTypes.append(kind) // Its staged work and old checkpoint survive; other types can progress.
                // C1 埋点：失败摘要去重入报告（诊断「不稳定」的归因通道）
                var failures = report.lastFailures ?? []
                if !failures.contains(kind.rawValue) { failures.append(kind.rawValue) }
                report.lastFailures = failures
                // C1-8b（2026-10-04 评审）：lastFailures 只记 kind 名「哪种类型失败」，
                // 补「为什么失败」——错误描述去重截断入 failureReasons（与 kind 名并集互补）。
                var reasons = report.failureReasons ?? []
                let reason = String(String(describing: error).prefix(200))
                if !reason.isEmpty && !reasons.contains(reason) { reasons.append(reason) }
                report.failureReasons = reasons
            }
            report.hasMore = report.hasMore || hasPending
            // 审查修复（共享轮次取消不丢进度）：每类页处理完即落盘报告——
            // 创建方被取消（视图拆除 / permissionRevoked → cancelSync）时共享
            // 轮次随之中止，旧实现只在全部完成后经 runAndRecord 落盘，取消
            // 路径跳过 saveReport，已提交行数/最后同步时间永不更新（仪表盘
            // 滞后、失败提示却照常——两处状态分裂）。逐类落盘为有界小写
            // （hk_import_status 单行 upsert），最终保存保持幂等。
            do { try await imports.saveReport(report); latestReport = report }
            catch { /* 落盘失败不阻断本轮其余类型；runAndRecord 终态仍会重试 */ }
        }

        // 全部类型覆盖所选范围 → 落初始完成时刻；模式随即切 incremental（完成后的
        // pending 属增量，不再阻止完成态）。
        do { _ = try await imports.markInitialCompletedIfCovered() }
        catch { /* 完成态落盘失败不阻断本轮；下一轮重试（幂等） */ }

        // Retry pending qualified events even when there are no new HealthKit samples.
        // The medical review gate also prevents dispatch of old unreviewed engineering examples.
        // 收口批E②：派发逻辑提取为 dispatchPendingElevated（手录轨复用同一出口）。
        if !GuidelineSource.thresholdsAwaitMedicalReview {
            do {
                let dispatched = try await dispatchPendingElevated(
                    patientId: binding.patientId, quietStart: quietStart, quietEnd: quietEnd)
                report.elevated += dispatched.scheduled
                report.notificationFailures += dispatched.failures
            } catch is CancellationError { throw CancellationError() }
            catch { report.notificationFailures += 1 }
        }
        report.lastSyncAt = Date()
        return report
    }

    /// 合格事件派发单一出口（收口批E②，自 performSyncAll 内联循环提取）：
    /// 待派发（qualified 且 pending）事件 → L1 静默时段门 → 5s 后时间敏感通知
    /// → markScheduled。设备同步轨与**手录轨**（TrendEntryState.gradeManualReading
    /// 注入的闭包）共用——此前该逻辑埋在同步循环内，手录读数即使经
    /// GuidelineStore.evaluateRecentManualReadings 建了合格事件也无派发路径。
    /// 返回 (已排程, 通知失败)；健康导入被用户关闭时抛 disabled（调用方按
    /// 各自语义消化——同步轨记 notificationFailures，手录轨静默容忍）。
    public func dispatchPendingElevated(patientId: UUID, quietStart: String, quietEnd: String) async throws
        -> (scheduled: Int, failures: Int) {
        var scheduled = 0
        var failures = 0
        let pending = try await guidelines.history(patientId: patientId,
            qualifiedOnly: true, pendingOnly: true, activeOnly: true)
        for event in pending {
            try Task.checkCancellation()
            guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
            if event.severity == .L1 && QuietHoursRules.isActive(start: quietStart, end: quietEnd) { continue }
            do {
                let when = Date().addingTimeInterval(5)
                try await scheduler.schedule(dose: "alert-\(event.id.uuidString)", at: when,
                    route: .alertEvidence(patientId: patientId, eventId: event.id, severity: event.severity),
                    patientId: patientId)
                try await guidelines.markScheduled(id: event.id, patientId: patientId, at: when)
                scheduled += 1
            } catch { failures += 1 }
        }
        return (scheduled, failures)
    }

    /// 单道排空（2026-10-20 业主裁决：pending 优先 + 单页 pending）。
    ///
    /// 关键顺序：**已有 pending 未排空时绝不取下一页**。
    /// 旧实现每轮先取下一页再物化当前 pending；心率 500 样本页约 48–96 个小时窗，
    /// 而每轮只做 32 个 —— 每轮新增窗口 > 完成窗口，remaining 在预算内永远不降，
    /// pending 长到全道。现在一页的窗口分多轮做完才取下一页，总轮数 ≈ 总窗数/32。
    ///
    /// committed anchor 仍只在该道最终空页后推进（删除证明语义不变）；
    /// fetch cursor 每完成一页前进，崩溃从最近一页续取。
    private func drain(kind: HealthDataKind, scope: HealthFetchScope, binding: HealthImportStore.Binding,
                       existing: HealthImportStore.PendingBatch?, report: inout SyncReport,
                       deadline: ContinuousClock.Instant? = nil) async throws -> DrainOutcome {
        if let existing {
            if let deadline, ContinuousClock.now >= deadline {
                return DrainOutcome(hadWork: true, hasMore: true)
            }
            let remaining = try await pendingWindows(binding: binding, kind: kind, pending: existing)
            if remaining.isEmpty {
                // 页已完整物化但尚未提交（例如崩溃后恢复）：只提交，不取下一页。
                let committed = try await imports.commit(
                    binding: binding, kind: kind, pending: existing,
                    snapshots: [], attemptedWindows: [])
                applyCommitReport(committed, kind: kind, report: &report,
                                  remainingCount: 0, attemptedCount: 0, snapshots: [])
                report.backfillLane = scope.lane
                return DrainOutcome(hadWork: true, hasMore: committed.hasMore,
                                    laneComplete: committed.laneComplete
                                        && committed.deferredWindows == 0)
            }
            return try await materializePending(
                existing, remaining: remaining, kind: kind, scope: scope, binding: binding,
                report: &report, hadWorkSeed: true, deadline: deadline)
        }

        if let deadline, ContinuousClock.now >= deadline {
            return DrainOutcome(hadWork: false, hasMore: false)
        }
        // 无 pending：取一页。previous 用 fetch cursor（每页推进），旧库回落 committed。
        let previous = try await imports.nextFetchAnchor(binding: binding, kind: kind, lane: scope.lane)
        let page = try await provider.changes(for: kind, scope: scope, anchor: previous, limit: 500)
        report.receivedChanges += page.added.count + page.deleted.count
        var samples = report.perKindSamples ?? [:]
        samples[kind.rawValue] = (samples[kind.rawValue] ?? 0) + page.added.count + page.deleted.count
        report.perKindSamples = samples
        var queries = report.perKindQueries ?? [:]
        queries[kind.rawValue] = (queries[kind.rawValue] ?? 0) + 1
        report.perKindQueries = queries
        // 稀疏扫描检查点（空页 + hasMore）：只前进 fetch cursor，不 stage/commit。
        // 这是扫描位置，不是“缺失证当完整”；没有 added/deleted 可物化。
        if page.added.isEmpty && page.deleted.isEmpty && page.hasMore {
            try await imports.saveScanCheckpoint(binding: binding, kind: kind,
                                                 lane: scope.lane, anchor: page.anchor)
            report.backfillLane = scope.lane
            return DrainOutcome(hadWork: true, hasMore: true)
        }
        let staged = try await imports.stage(binding: binding, kind: kind, scope: scope,
                                             previousAnchor: previous, page: page)
        let hadWork = !page.added.isEmpty || !page.deleted.isEmpty || page.hasMore
        return try await materializePending(
            staged, remaining: nil, kind: kind, scope: scope, binding: binding,
            report: &report, hadWorkSeed: hadWork, deadline: deadline)
    }

    /// pending 未完成的窗口（保持 reconcileAfter 的“新窗优先”次序）。
    private func pendingWindows(binding: HealthImportStore.Binding, kind: HealthDataKind,
                                pending: HealthImportStore.PendingBatch) async throws -> [HealthImportWindow] {
        var remaining = try await imports.affectedWindows(binding: binding, kind: kind, batch: pending.batch)
            .filter { !pending.completedWindows.contains($0) }
        if let after = pending.reconcileAfter {
            remaining = remaining.filter { $0.start > after } + remaining.filter { $0.start <= after }
        }
        return remaining
    }

    /// 物化一页的窗口（最多 windowsPerRound），一次提交。
    private func materializePending(_ pending: HealthImportStore.PendingBatch,
                                    remaining provided: [HealthImportWindow]?,
                                    kind: HealthDataKind, scope: HealthFetchScope,
                                    binding: HealthImportStore.Binding,
                                    report: inout SyncReport,
                                    hadWorkSeed: Bool,
                                    deadline: ContinuousClock.Instant? = nil) async throws -> DrainOutcome {
        let remaining: [HealthImportWindow]
        if let provided { remaining = provided }
        else { remaining = try await pendingWindows(binding: binding, kind: kind, pending: pending) }
        // 2026-09-19 审查修复（业主实测「睡眠最新差一年」）：recent 道窗序**最新优先**；
        // history 道维持最旧优先（锚点推进语义不变）。
        let ordered = scope.lane == .recent ? remaining.sorted { $0.start > $1.start } : remaining
        let attempted = Array(ordered.prefix(Self.windowsPerRound))
        var queried: [HealthImportWindow] = []
        var snapshots: [HealthWindowSnapshot] = []
        var queryFailed = false
        var firstSnapshotError: Error?
        // 串行窗口快照：取消/错误传播与失败继续语义由既有契约测试钉死
        // （C2 并发化在 CI #652 回归，见 2026-10-04 评审）。
        for window in attempted {
            // 轮内 deadline：到点只提交已查询窗口；未查询窗口留在 pending，
            // 下一轮继续（不是失败，不记 failedTypes）。
            if let deadline, ContinuousClock.now >= deadline { break }
            try Task.checkCancellation()
            guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
            queried.append(window)
            do { snapshots.append(try await provider.snapshot(for: window, calendar: binding.calendar)) }
            catch is CancellationError { throw CancellationError() }
            catch {
                queryFailed = true
                if firstSnapshotError == nil { firstSnapshotError = error }
            }
        }
        var queries = report.perKindQueries ?? [:]
        queries[kind.rawValue] = (queries[kind.rawValue] ?? 0) + queried.count
        report.perKindQueries = queries
        guard !queried.isEmpty || remaining.isEmpty else {
            // 到期且一个窗口都没做成：不提交（commit 要求 remaining≠∅ 时至少尝试一个）。
            return DrainOutcome(hadWork: hadWorkSeed, hasMore: true)
        }
        let committed = try await imports.commit(binding: binding, kind: kind, pending: pending,
                                                 snapshots: snapshots, attemptedWindows: queried)
        applyCommitReport(committed, kind: kind, report: &report,
                          remainingCount: remaining.count, attemptedCount: queried.count,
                          snapshots: snapshots)
        if queryFailed && !report.failedTypes.contains(kind) { report.failedTypes.append(kind) }
        if queryFailed {
            var reasons = report.failureReasons ?? []
            let reason = "window snapshot query failed: \(String(String(describing: firstSnapshotError).prefix(160)))"
            if !reasons.contains(reason) { reasons.append(reason) }
            report.failureReasons = reasons
        }
        if hadWorkSeed { report.backfillLane = scope.lane }
        return DrainOutcome(hadWork: hadWorkSeed || !remaining.isEmpty,
                            hasMore: committed.hasMore,
                            laneComplete: committed.laneComplete && !queryFailed
                                && committed.deferredWindows == 0)
    }

    /// 报告合并（两处提交路径共用）：行数/延迟/剩余窗/稀疏/失败分型。
    private func applyCommitReport(_ committed: HealthImportStore.CommitReport,
                                   kind: HealthDataKind, report: inout SyncReport,
                                   remainingCount: Int, attemptedCount: Int,
                                   snapshots: [HealthWindowSnapshot]) {
        report.persistedRows += committed.persistedRows
        report.preservedRows += committed.preservedRows
        report.deferredWindows += committed.deferredWindows
        report.rejectedSamples += snapshots.reduce(0) { $0 + $1.rejected }
        report.sparseWindows = (report.sparseWindows ?? 0)
            + snapshots.reduce(0) { $0 + $1.sparseWindows }
        report.remainingWindows = (report.remainingWindows ?? 0)
            + max(0, remainingCount - attemptedCount) + committed.deferredWindows
        report.perKindRemaining = report.perKindRemaining ?? [:]
        report.perKindRemaining?[kind.rawValue] =
            max(0, remainingCount - attemptedCount) + committed.deferredWindows
        if committed.deferredWindows > 0 { report.failedTypes.append(kind) }
    }

    #if os(iOS)
    /// 刷新作业（30 秒级）：增量对账一轮。
    public static let bgTaskIdentifier = "com.vitaliber.healthkit-sync"
    /// 回填作业（round5 Q2 新增，分钟级 `BGProcessingTask`）：设备空闲时排空积压——此前后台只有刷新作业，每次唤醒每类只排 1 页，
    /// 一年心率需数百次唤醒；`processing` 模式在 Info.plist 声明了却从未使用。
    public static let backfillTaskIdentifier = "com.vitaliber.healthkit-backfill"
    /// 用户发起的手动同步在 iOS 26 经 continued processing 续跑（切后台不中断）。
    public static let continuedSyncIdentifier = "com.vitaliber.continued.healthkit-sync"
    public private(set) var backgroundRegistrationFailed = false
    /// 提交（排期）失败标记（2026-09-23 拆分）：`BGTaskScheduler.submit` 的系统级暂态
    /// （后台刷新被关、排队过多）此前被误记成「注册失败」——横幅文案错误、且「重新连接」
    /// 并不能修复系统级限制。暂态只记账，由前台入口 `maintainBackgroundAutomation` 重试自愈。
    public private(set) var backgroundScheduleFailed = false
    /// 最近一次后台投递注册的分类结果（诊断用；`armedTypes` 为空 = 真正不可用）。
    public private(set) var lastDeliveryOutcome: HealthKitReader.BackgroundDeliveryOutcome?
    /// 最近一次 observer 投递到达时刻（诊断/自愈判据；进程级，重启清零）。
    nonisolated(unsafe) public static var lastObserverDeliveryAt: Date?
    /// 上次注册明确阻断的类型（权限未定/被拒）。授权恢复 → 清该类型锚点/完成态重取。
    private var blockedKinds: Set<HealthDataKind> = []
    nonisolated(unsafe) public static var backgroundSyncHandler: (@Sendable () async -> Bool)?
    /// 投递唤醒专用执行体（2026-10-04 评审 C1-6：HealthKit 后台投递每次唤醒仅约 15s，
    /// 与 refresh 共用 8 轮/18s 处理器系统性跑不完——分槽后投递走轻量预算
    /// 「先排期 refresh 再受限排空」；缺省回落 backgroundSyncHandler 保测试/装配兼容）。
    nonisolated(unsafe) public static var backgroundObserverHandler: (@Sendable () async -> Bool)?
    /// 回填执行体（App 装配：读静默时段设置 → `performSyncAll(maxRounds: 按预算, timeBudget: 预算)`）。
    nonisolated(unsafe) public static var backgroundBackfillHandler: (@Sendable (Duration) async -> BackgroundJobOutcome)?
    nonisolated(unsafe) public static var backgroundCancelHandler: (@Sendable () async -> Void)?

    /// 两个后台作业（描述为 Domain 纯值；执行体经静态闭包由 App 装配）。
    struct RefreshJob: BackgroundJob {
        let descriptor = BackgroundJobDescriptor(identifier: HealthKitSyncService.bgTaskIdentifier, kind: .refresh, minimumInterval: 15 * 60)
        func run(budget: Duration) async -> BackgroundJobOutcome {
            BackgroundJobOutcome(success: (await HealthKitSyncService.backgroundSyncHandler?()) ?? false, reschedule: true)
        }
    }
    struct BackfillJob: BackgroundJob {
        // 不要求外接电源/网络：HealthKit 本机读、CPU 轻；要求电源会让多数夜间不充电的用户永远排不到
        let descriptor = BackgroundJobDescriptor(identifier: HealthKitSyncService.backfillTaskIdentifier,
                                                 kind: .processing(requiresNetwork: false, requiresExternalPower: false),
                                                 minimumInterval: 60 * 60)
        func run(budget: Duration) async -> BackgroundJobOutcome {
            (await HealthKitSyncService.backgroundBackfillHandler?(budget)) ?? BackgroundJobOutcome(success: false, reschedule: false)
        }
    }

    /// 积压判定后申请一次回填（服务内每轮落盘报告后调用；纯策略在 Domain `HealthSyncBacklogPolicy`）。
    private func requestBackfillIfNeeded(_ report: SyncReport) {
        guard HealthSyncBacklogPolicy.shouldRequestProcessing(remainingWindows: report.remainingWindows, hasMore: report.hasMore) else { return }
        let now = Date()
        if let last = lastBackfillRequestAt, now.timeIntervalSince(last) < 300 { return }
        lastBackfillRequestAt = now
        // 有真实积压时请求最早可运行（不做 now+60min 的反复后推）；
        // 是否真正排到仍由系统决定，去重只防每轮 cancel+submit 抖动。
        if !BackgroundWorkScheduler.shared.submit(Self.backfillTaskIdentifier,
                                                  now: now, earliestBeginDate: now) {
            lastBackfillRequestAt = nil   // 提交失败下一轮重试，不被 TTL 饿死
        }
    }

    public func startBackgroundObservation() async {
        // 审查修正：非 HealthKitReader 注入（测试替身/未来第二实现）此前静默
        // return——backgroundRegistrationFailed 保持 false，canAutomaticallySync
        // 仍报启用，仪表盘显示「自动后台同步开启」而观察者从未注册。能力缺失
        // 必须响亮：置失败标志，让依赖此标志的界面如实呈现。
        guard let reader = provider as? HealthKitReader else {
            backgroundRegistrationFailed = true
            return
        }
        do {
            let enabled = try await canAutomaticallySync()
            let handler: @Sendable () async -> Bool = {
                Self.lastObserverDeliveryAt = Date()
                // C1-6：投递唤醒优先走专用轻量处理器；未装配时回落共享处理器（测试/兼容）
                if let observer = Self.backgroundObserverHandler { return await observer() }
                return (await Self.backgroundSyncHandler?()) ?? false
            }
            // 自愈：上次注册不可用，或超过 7 天没有任何投递 → 重建 query。
            let stale = Self.lastObserverDeliveryAt.map {
                Date().timeIntervalSince($0) > 7 * 86_400
            } ?? false
            let shouldRebuild = backgroundRegistrationFailed
                || (lastDeliveryOutcome.map { !$0.isUsable } ?? false) || stale
            let outcome = shouldRebuild
                ? await reader.rebuildObservers(handler: handler, enableDelivery: enabled)
                : await reader.observeChanges(handler: handler, enableDelivery: enabled)
            lastDeliveryOutcome = outcome
            if enabled {
                let nowBlocked = Set(outcome.blockedTypes.compactMap {
                    HealthKitReader.kind(forSampleTypeIdentifier: $0)
                })
                // 进程重启后 in-memory blockedKinds 为空；持久化 completion 的
                // blocked 标记才是“上次被阻断”的事实源。
                var persistedBlocked: Set<HealthDataKind> = []
                do {
                    if let plan = try await imports.plan() {
                        for (key, completion) in plan.completions where completion.blocked {
                            if let kind = HealthDataKind(rawValue: key) {
                                persistedBlocked.insert(kind)
                            }
                        }
                    }
                } catch { /* 读计划失败不阻断注册；本轮按 in-memory 集合 */ }
                let previouslyBlocked = blockedKinds.union(persistedBlocked)
                for kind in nowBlocked.subtracting(previouslyBlocked) {
                    do { try await imports.markBlocked(kind: kind, reason: "background delivery blocked") }
                    catch { /* 阻断记账失败不阻断注册；下一轮重试 */ }
                }
                let failedKinds = Set(outcome.failedTypes.compactMap {
                    HealthKitReader.kind(forSampleTypeIdentifier: $0)
                })
                // 授权恢复：清该类型完成态 + 全部锚点/在途批次，强制从当前范围重取。
                // 系统级暂态失败（failedTypes）不算恢复，保留既有进度等下次重试。
                for kind in previouslyBlocked.subtracting(nowBlocked).subtracting(failedKinds) {
                    do { try await imports.resetKind(kind) }
                    catch { /* 同上 */ }
                }
                blockedKinds = nowBlocked
            }
            // 2026-09-23 修复（横幅假警报根治）：判死条件从「全部类型逐一成功」改为
            // 「至少一个类型武装」——部分授权（用户只勾了部分类型）是常态，不是注册失败；
            // 自动化关闭（enabled=false，未连接/开关关闭）时「注册失败」不适用，一律清除。
            backgroundRegistrationFailed = enabled && !outcome.isUsable
        } catch { backgroundRegistrationFailed = true }
    }

    /// 排期刷新作业；有积压时同时排期回填作业（round5 Q2：统一门面 `BackgroundWorkScheduler`——此前本处直接构造
    /// `BGAppRefreshTaskRequest`，与 ASR 的 `beginBackgroundTask`、HK 观察者三处各自为政）。
    /// **2026-09-23 修复**：提交失败不再一律
    /// 记成注册失败——`.notPermitted`/注册回执为 false 是注册级缺陷（如实置
    /// `backgroundRegistrationFailed`）；系统暂态（后台刷新被关、排队过多）只记
    /// `backgroundScheduleFailed`，提交成功即清除（前台入口重试自愈）。
    @discardableResult
    public func scheduleBackgroundRefresh() -> Bool {
        let ok = BackgroundWorkScheduler.shared.submit(Self.bgTaskIdentifier)
        if ok {
            backgroundScheduleFailed = false
        } else {
            backgroundScheduleFailed = true
            let kind = BackgroundWorkScheduler.shared.submitFailureKind(for: Self.bgTaskIdentifier)
            if kind == .notPermitted || BackgroundWorkScheduler.shared.registrationFailed(for: Self.bgTaskIdentifier) {
                backgroundRegistrationFailed = true
            }
        }
        if let report = latestReport { requestBackfillIfNeeded(report) }
        return ok
    }

    /// 前台统一维护单一入口（启动 / 回前台 / 连接 / 开关切换，2026-09-23 新增）：
    /// 1. 复核观察注册真相（`startBackgroundObservation`）；
    /// 2. 允许自动同步时重排刷新/回填请求（提交成功清暂态失败账 = 自愈）；
    /// 3. 不允许时撤销挂起请求（不占用系统预算、不空转）。
    public func maintainBackgroundAutomation() async {
        await startBackgroundObservation()
        let canAuto: Bool
        do { canAuto = try await canAutomaticallySync() } catch { canAuto = false }
        guard canAuto else {
            BackgroundWorkScheduler.shared.cancel(Self.bgTaskIdentifier)
            BackgroundWorkScheduler.shared.cancel(Self.backfillTaskIdentifier)
            backgroundScheduleFailed = false
            return
        }
        _ = scheduleBackgroundRefresh()
    }

    /// App init 唯一注册点：两作业登记到门面并向系统注册（含 iOS 26 continued processing 标识符）。
    public nonisolated static func registerBackgroundTask() {
        let scheduler = BackgroundWorkScheduler.shared
        scheduler.add(RefreshJob())
        scheduler.add(BackfillJob())
        scheduler.addContinued(identifier: continuedSyncIdentifier)   // 手动同步（用户动作）在 iOS 26 切后台续跑
        scheduler.registerAll()
        scheduler.registerContinuedAll()
    }
    #endif
}
#endif
