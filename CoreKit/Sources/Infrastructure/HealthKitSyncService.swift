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
    public private(set) var latestReport: SyncReport?

    public init(provider: any HealthReadingProvider, writer: (any HealthWritingProvider)? = nil,
                imports: HealthImportStore, guidelines: GuidelineStore,
                scheduler: any ReminderScheduling) {
        self.provider = provider; self.writer = writer; self.imports = imports
        self.guidelines = guidelines; self.scheduler = scheduler
    }

    public func connect() async throws -> HealthImportStore.Binding {
        guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
        try await provider.requestAuthorization()
        // A completed request says nothing about individual read permissions.
        let binding = try await imports.connect()
        #if os(iOS)
        await startBackgroundObservation()
        _ = scheduleBackgroundRefresh()
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
                               timeBudget: Duration = .seconds(30)) async throws -> SyncReport {
        let start = ContinuousClock.now
        var total: SyncReport?
        for _ in 0..<max(1, maxRounds) {
            try Task.checkCancellation()
            let result = try await performSync(quietStart: quietStart, quietEnd: quietEnd)
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
                total = aggregate
            } else {
                total = result
            }
            if !result.hasMore || start.duration(to: .now) >= timeBudget { break }
        }
        // maxRounds ≥ 1 时首轮必产出；守卫兜底无绑定（missingOwner 与
        // performSync 内部缺失绑定的失败语义一致）。
        guard let total else { throw HealthImportStore.ImportError.missingOwner }
        return total
    }

    public func performSync(quietStart: String, quietEnd: String) async throws -> SyncReport {
        try Task.checkCancellation()
        if let inFlight {
            let report = try await inFlight.value
            try Task.checkCancellation()
            return report
        }
        let id = UUID()
        inFlightID = id
        let task = Task { try await self.runAndRecord(id: id, quietStart: quietStart, quietEnd: quietEnd) }
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

    /// 合并调用者共享整个轮次，含状态落盘；完成后才释放flight，避免反复加入已完成任务。
    private func runAndRecord(id: UUID, quietStart: String, quietEnd: String) async throws -> SyncReport {
        defer { if inFlightID == id { inFlight = nil; inFlightID = nil } }
        let report = try await run(quietStart: quietStart, quietEnd: quietEnd)
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
    }

    private func run(quietStart: String, quietEnd: String) async throws -> SyncReport {
        try Task.checkCancellation()
        // round2 H3/H-N4：开关关闭是独立失败态，不再与缺本人档案混为 missingOwner（视图三态文案依赖分型）
        guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
        guard let binding = try await imports.connection() else { throw HealthImportStore.ImportError.missingOwner }
        var report = SyncReport(lastSyncAt: Date(), bindingId: binding.id, patientId: binding.patientId)
        let scopes = imports.scopes(for: binding)
        // Fetch one page per type/round. Drained work resumes by window without losing the old checkpoint.
        for kind in HealthDataKind.allCases {
            var hasPending = false
            do {
                try Task.checkCancellation()
                guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                // 2026-09-19 审查修复（recent 道降序首填）：v4 游标方案的一次性迁移——
                // 必须在 pendingBatch 读取前执行（旧 v3 recent 批次锚点与新空游标
                // 互斥会 staleAnchor 永久卡死）。v4 已存在时零开销。
                try await imports.prepareRecentLane(binding: binding, kind: kind)
                let existing = try await imports.pendingBatch(binding: binding, kind: kind)
                hasPending = existing != nil
                // round2 H-N1：在途批次只续其所在道；否则先探 recent（近一年最新优先），空页再探 history。
                // 每类每轮最多两次探测；任一道有工作即停止。
                let order: [HealthFetchScope]
                if let inFlight = existing?.lane, let scope = scopes.first(where: { $0.lane == inFlight }) {
                    order = [scope]
                } else {
                    order = scopes
                }
                for scope in order {
                    let outcome = try await drain(kind: kind, scope: scope, binding: binding,
                                                  existing: existing?.lane == scope.lane ? existing : nil,
                                                  report: &report)
                    hasPending = outcome.hasMore
                    if outcome.hadWork { break }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch HealthImportStore.ImportError.disabled {
                throw HealthImportStore.ImportError.disabled
            } catch HealthImportStore.ImportError.bindingChanged {
                throw HealthImportStore.ImportError.bindingChanged
            } catch {
                report.failedTypes.append(kind) // Its staged work and old checkpoint survive; other types can progress.
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

        // Retry pending qualified events even when there are no new HealthKit samples.
        // The medical review gate also prevents dispatch of old unreviewed engineering examples.
        if !GuidelineSource.thresholdsAwaitMedicalReview {
            do {
                let pending = try await guidelines.history(patientId: binding.patientId,
                    qualifiedOnly: true, pendingOnly: true, activeOnly: true)
                for event in pending {
                    try Task.checkCancellation()
                    guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
                    if event.severity == .L1 && QuietHoursRules.isActive(start: quietStart, end: quietEnd) { continue }
                    do {
                        let when = Date().addingTimeInterval(5)
                        try await scheduler.schedule(dose: "alert-\(event.id.uuidString)", at: when,
                            route: .alertEvidence(patientId: binding.patientId, eventId: event.id, severity: event.severity))
                        try await guidelines.markScheduled(id: event.id, patientId: binding.patientId, at: when)
                        report.elevated += 1
                    } catch { report.notificationFailures += 1 }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.notificationFailures += 1 }
        }
        report.lastSyncAt = Date()
        return report
    }

    /// 单道单页排空（round2 H-N1）：取页 → 暂存 → 受影响窗口重算（每轮 ≤ windowsPerRound）→ 提交。
    /// 检查点/删除证明/完整窗口重算语义与单道时代完全一致，只是游标与 pending 按道分列。
    /// 在途信号由提交结果承担：提交成功 hasMore 即续排；提交抛错由外层 catch 保留
    /// existing != nil 的 hasPending=true（暂存工作存活，下一轮续排）——入口处无需预置。
    private func drain(kind: HealthDataKind, scope: HealthFetchScope, binding: HealthImportStore.Binding,
                       existing: HealthImportStore.PendingBatch?, report: inout SyncReport) async throws -> DrainOutcome {
        let previous: Data?
        if let existing { previous = existing.batch.anchor }
        else { previous = try await imports.anchor(binding: binding, kind: kind, lane: scope.lane) }
        // Even a previously drained but incomplete batch can discover later tombstones on this page.
        let page = try await provider.changes(for: kind, scope: scope, anchor: previous, limit: 500)
        report.receivedChanges += page.added.count + page.deleted.count
        let pending = try await imports.stage(binding: binding, kind: kind, scope: scope, previousAnchor: previous, page: page)
        var remaining = try await imports.affectedWindows(binding: binding, kind: kind, batch: pending.batch)
            .filter { !pending.completedWindows.contains($0) }
        if let after = pending.reconcileAfter {
            remaining = remaining.filter { $0.start > after } + remaining.filter { $0.start <= after }
        }
        // 2026-09-19 审查修复（业主实测「睡眠最新差一年」）：recent 道窗序改为**最新优先**——
        // HKAnchoredObjectQuery 行序最旧优先 + 升序排窗 + 每轮 32 窗预算的组合曾让最新一晚
        // 最后到达：半排空状态下仪表盘 MAX(measured_at) 呈现近一年前的旧夜。
        // history 道维持最旧优先（锚点推进语义不变）。
        let ordered = scope.lane == .recent ? remaining.sorted { $0.start > $1.start } : remaining
        let attempted = Array(ordered.prefix(Self.windowsPerRound))
        var snapshots: [HealthWindowSnapshot] = []
        var queryFailed = false
        for window in attempted {
            try Task.checkCancellation()
            guard try await imports.isEnabled() else { throw HealthImportStore.ImportError.disabled }
            do { snapshots.append(try await provider.snapshot(for: window, calendar: binding.calendar)) }
            catch is CancellationError { throw CancellationError() }
            catch { queryFailed = true }
        }
        let committed = try await imports.commit(binding: binding, kind: kind, pending: pending,
                                                 snapshots: snapshots, attemptedWindows: attempted)
        report.persistedRows += committed.persistedRows
        report.preservedRows += committed.preservedRows
        report.deferredWindows += committed.deferredWindows
        report.rejectedSamples += snapshots.reduce(0) { $0 + $1.rejected }
        // round2 H-N2：稀疏窗计数上送（统计事实）；H-N1：排空进度 = 未尝试窗口 + 本轮推迟窗口
        report.sparseWindows = (report.sparseWindows ?? 0) + snapshots.reduce(0) { $0 + $1.sparseWindows }
        report.remainingWindows = (report.remainingWindows ?? 0) + (remaining.count - attempted.count) + committed.deferredWindows
        // 2026-09-19 审查修复：按类型细分剩余窗口（健康 Tab 类别卡进度条数据源）。
        report.perKindRemaining = report.perKindRemaining ?? [:]
        report.perKindRemaining?[kind.rawValue] = remaining.count - attempted.count + committed.deferredWindows
        if queryFailed || committed.deferredWindows > 0 { report.failedTypes.append(kind) }
        let hadWork = existing != nil || !page.added.isEmpty || !page.deleted.isEmpty || page.hasMore
        if hadWork { report.backfillLane = scope.lane }
        return DrainOutcome(hadWork: hadWork, hasMore: committed.hasMore)
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
    nonisolated(unsafe) public static var backgroundSyncHandler: (@Sendable () async -> Bool)?
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
        _ = BackgroundWorkScheduler.shared.submit(Self.backfillTaskIdentifier)
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
            backgroundRegistrationFailed = !(await reader.observeChanges(handler: {
                (await Self.backgroundSyncHandler?()) ?? false
            }, enableDelivery: enabled))
        } catch { backgroundRegistrationFailed = true }
    }

    /// 排期刷新作业；有积压时同时排期回填作业（round5 Q2：统一门面 `BackgroundWorkScheduler`——此前本处直接构造
    /// `BGAppRefreshTaskRequest`，与 ASR 的 `beginBackgroundTask`、HK 观察者三处各自为政）。
    @discardableResult
    public func scheduleBackgroundRefresh() -> Bool {
        let ok = BackgroundWorkScheduler.shared.submit(Self.bgTaskIdentifier)
        if !ok { backgroundRegistrationFailed = true }
        if let report = latestReport { requestBackfillIfNeeded(report) }
        return ok
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
