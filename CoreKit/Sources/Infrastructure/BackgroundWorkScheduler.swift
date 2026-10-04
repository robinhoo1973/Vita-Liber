#if os(iOS)
// linux-blind: （平台守卫：BackgroundTasks 仅 iOS） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import BackgroundTasks
import UIKit
import Domain

/// 后台作业（round5 Q2）：作业只实现 `run(budget:)`，注册/提交/重排/过期取消由 `BackgroundWorkScheduler` 统一承担。
/// `run` 必须协作式响应 `Task` 取消（到期即取消），并在预算内自行落盘进度——系统不保证准时、不保证完整时长。
public protocol BackgroundJob: Sendable {
    var descriptor: BackgroundJobDescriptor { get }
    func run(budget: Duration) async -> BackgroundJobOutcome
}

public struct BackgroundJobOutcome: Equatable, Sendable {
    public var success: Bool
    /// 运行后是否重排下一次（处理类作业在积压排空后可停）。
    public var reschedule: Bool
    public init(success: Bool, reschedule: Bool = true) { self.success = success; self.reschedule = reschedule }
}

/// `BGTaskScheduler.submit` 失败的分类（2026-09-23 修复「提交失败被误记注册失败」）：
/// 注册级缺陷与系统级暂态必须分开——只有 `.notPermitted`（标识符未登记/未注册）或注册回执
/// 为 false 才构成「注册失败」；`.unavailable`（系统关闭后台刷新/资源受限）与
/// `.tooManyPendingTaskRequests`（同名请求未撤销即重提）是暂态，应静默重试自愈。
public enum SubmitFailureKind: Sendable, Equatable {
    /// 标识符未登记/未注册（`BGTaskScheduler.Error.Code.notPermitted`）——注册级缺陷。
    case notPermitted
    /// 系统层面暂不可用（后台刷新被关闭、低电量等）。
    case unavailable
    /// 排队过多（同名请求未撤销即重提的经典成因）。
    case tooManyPending
    /// 其他错误。
    case other
}

/// 统一后台调度门面（round5 Q2，业主「可靠稳定的后台模块，可用作所有需要后台处理的工作」在 iOS 上的正确形态）。
///
/// iOS 无守护进程；后台执行权只来自 OS 原语，本门面把三件事收口：
/// 1. **注册**（`BGTaskScheduler.register` 必须在应用启动完成前、每个标识符恰一次）——`registerAll()` 在 App init 调一次；
/// 2. **提交/重排**（`BGTaskRequest` 一次性：运行后须再提交；`earliestBeginDate = now + minimumInterval`）；
/// 3. **过期**（`expirationHandler` → 协作取消作业 Task，作业返回后回报 `setTaskCompleted`）。
/// iOS 26 追加 **continued processing**：由用户动作在前台发起、切后台续跑分钟级（系统以 Live Activity 呈现进度、可取消），
/// 供「手动同步 / 模型下载解压」这类用户等待中的长任务使用。
///
/// 此前三处各自为政：HealthKit 只用 `BGAppRefreshTask`（30 秒级）、ASR 下载用 `beginBackgroundTask`（实为 30 秒，注释误记
/// 30 分钟）、HK 观察者另行注册——`processing` 模式声明了却从未使用。
public final class BackgroundWorkScheduler: @unchecked Sendable {
    public static let shared = BackgroundWorkScheduler()
    /// ASR 模型下载解压（用户动作）的 continued processing 标识符（Info.plist 已登记）。
    public static let asrInstallContinuedIdentifier = "com.vitaliber.continued.asr-install"

    private let lock = NSLock()
    private var jobs: [String: any BackgroundJob] = [:]
    private var registered = false
    /// 最近一次提交失败（标识符 → 错误描述）；仪表盘可据此如实呈现「后台任务未能排期」。
    public private(set) var lastSubmitFailure: [String: String] = [:]
    /// 提交失败分类（标识符 → 分类；2026-09-23）：调用方据此把「注册级缺陷」与
    /// 「系统级暂态」分开记账（前者报警、后者重试自愈）。
    public private(set) var lastSubmitFailureKind: [String: SubmitFailureKind] = [:]
    /// `register(forTaskWithIdentifier:)` 的 Bool 回执（此前被丢弃）：false = 系统拒绝注册
    /// （标识符未登记/重复注册），此后一切提交必然失败——注册级缺陷的唯一在架证据。
    public private(set) var registrationResults: [String: Bool] = [:]

    private init() {}

    /// 登记作业（启动前调用；`registerAll()` 之后再登记的作业不会被系统唤起——响亮失败：返回 false）。
    @discardableResult
    public func add(_ job: any BackgroundJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !registered else { return false }
        jobs[job.descriptor.identifier] = job
        return true
    }

    /// 向 `BGTaskScheduler` 注册全部作业（App init 唯一调用点；重复调用无效）。
    public func registerAll() {
        lock.lock()
        guard !registered else { lock.unlock(); return }
        registered = true
        let snapshot = jobs
        lock.unlock()
        for (identifier, job) in snapshot {
            // 2026-09-23：回执不再丢弃——false 即系统拒绝注册，是「注册失败」判定的第一手证据。
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                self?.handle(task, job: job)
            }
            lock.lock(); registrationResults[identifier] = ok; lock.unlock()
        }
    }

    /// 提交一次运行请求（重排）。系统只保证不早于 `earliestBeginDate`；处理类作业按描述附网络/电源要求。
    @discardableResult
    public func submit(_ identifier: String, now: Date = Date()) -> Bool {
        lock.lock()
        let job = jobs[identifier]
        lock.unlock()
        guard let job else { return false }
        let request: BGTaskRequest
        switch job.descriptor.kind {
        case .refresh:
            request = BGAppRefreshTaskRequest(identifier: identifier)
        case .processing(let network, let power):
            let processing = BGProcessingTaskRequest(identifier: identifier)
            processing.requiresNetworkConnectivity = network
            processing.requiresExternalPower = power
            request = processing
        }
        request.earliestBeginDate = job.descriptor.earliestBeginDate(from: now)
        // 同名重排 = 先撤旧请求再提交（2026-09-23）：不撤旧就重提是排队族错误
        // （`tooManyPendingTaskRequests`）的经典成因。撤销只影响**挂起**请求，
        // 对正在运行的作业无影响（运行中的请求已被系统消费）。
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            lock.lock(); lastSubmitFailure[identifier] = nil; lastSubmitFailureKind[identifier] = nil; lock.unlock()
            return true
        } catch {
            let kind = Self.classify(error)
            lock.lock()
            lastSubmitFailure[identifier] = String(describing: error)
            lastSubmitFailureKind[identifier] = kind
            lock.unlock()
            return false
        }
    }

    public func cancel(_ identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    /// 某标识符最近一次提交失败的分类（nil = 无失败记录）。
    public func submitFailureKind(for identifier: String) -> SubmitFailureKind? {
        lock.lock(); defer { lock.unlock() }
        return lastSubmitFailureKind[identifier]
    }

    /// 某标识符是否被系统拒绝注册（false 回执；nil = 无记录）。
    public func registrationFailed(for identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registrationResults[identifier] == false
    }

    private static func classify(_ error: Error) -> SubmitFailureKind {
        guard let bgError = error as? BGTaskScheduler.Error else { return .other }
        let code = bgError.code
        if code == .notPermitted { return .notPermitted }
        if code == .unavailable { return .unavailable }
        if code == .tooManyPendingTaskRequests { return .tooManyPending }
        return .other
    }

    /// 系统唤起：预算按作业种类给（刷新 ≈20s / 处理默认 4 分钟），到期 → 协作取消；作业返回后回报并按 outcome 重排。
    private func handle(_ task: BGTask, job: any BackgroundJob) {
        let budget: Duration = job.descriptor.kind.isProcessing
            ? BackgroundJobPolicy.runBudget(now: Date(), expiresAt: nil)
            : BackgroundJobPolicy.refreshBudget
        let work = Task { [weak self] in
            let outcome = await job.run(budget: budget)
            task.setTaskCompleted(success: outcome.success && !Task.isCancelled)
            if outcome.reschedule { self?.submit(job.descriptor.identifier) }
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - iOS 26 continued processing（用户发起、切后台续跑）

    /// 单次用户长任务的执行体：收 `Progress?`（iOS 26 有系统进度条须持续上报；回落路径为 nil）与到期/取消查询。
    public typealias ContinuedOperation = @Sendable (_ progress: Progress?, _ isCancelled: @escaping @Sendable () -> Bool) async -> Bool

    private var continuedIdentifiers: Set<String> = []
    private var pendingContinued: [String: PendingContinued] = [:]

    private final class PendingContinued: @unchecked Sendable {
        let operation: ContinuedOperation
        let completion: CheckedContinuation<ContinuedResolution, Never>
        var taken = false
        init(operation: @escaping ContinuedOperation, completion: CheckedContinuation<ContinuedResolution, Never>) {
            self.operation = operation; self.completion = completion
        }
    }

    /// pending 的收尾裁决（2026-10-04 评审 C1-1/C1-3）：`runForeground` = 系统路径
    /// 不可用（已有在途/提交失败/启动超时/调用方取消），调用方回落前台断言直跑；
    /// `done` = 系统路径执行完毕（或取消穿透的确定性收尾）。
    private enum ContinuedResolution: Sendable {
        case done(Bool)
        case runForeground
    }

    /// 登记一个 continued processing 标识符（启动前；须同时在 `BGTaskSchedulerPermittedIdentifiers`）。更早系统空操作。
    public func addContinued(identifier: String) {
        lock.lock(); defer { lock.unlock() }
        guard !registered else { return }
        continuedIdentifiers.insert(identifier)
    }

    /// 与 `registerAll` 同时机：向系统注册全部 continued 标识符（iOS 26）。系统回调时取出该标识符待执行的 operation 运行。
    public func registerContinuedAll() {
        guard #available(iOS 26, *) else { return }
        lock.lock()
        let identifiers = continuedIdentifiers
        lock.unlock()
        for identifier in identifiers {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                guard let self, let continuedTask = task as? BGContinuedProcessingTask,
                      let pending = self.takePending(identifier) else { task.setTaskCompleted(success: false); return }
                let expired = ExpiryFlag()
                let work = Task {
                    let ok = await pending.operation(continuedTask.progress) { expired.value }
                    continuedTask.setTaskCompleted(success: ok && !expired.value)
                    pending.completion.resume(returning: .done(ok))
                }
                continuedTask.expirationHandler = { expired.value = true; work.cancel() }
            }
            lock.lock(); registrationResults[identifier] = ok; lock.unlock()
        }
    }

    /// 前台直跑路径（更早系统/提交失败/超时回落）的体面收尾（C4 评审修复 2026-10-03）：
    /// 注释曾声称「beginBackgroundTask ≈30 秒宽限」但从未请求——切后台即挂起
    /// （业主「不稳定不持续」直接机制）。现如实请求宽限（iOS 13+ 事实 ≈30s，
    /// 只够收尾一段），对齐 ASRInstallCenter 先例；expiration 回调在系统线程，
    /// 结束动作线程安全。
    private static func runForegroundWithAssertion(operation: @escaping ContinuedOperation) async -> Bool {
        let box = BackgroundAssertionBox()
        await MainActor.run { box.begin(name: "vitaliber-continued-fallback") }
        defer { Task { @MainActor in box.end() } }
        return await operation(nil) { Task.isCancelled }
    }

    /// 用户动作发起的长任务**单一入口**（手动健康同步 / ASR 模型下载解压）：
    /// - iOS 26 且标识符已登记：提交 `BGContinuedProcessingTaskRequest`（系统 Live Activity 显示 `title/subtitle` 与进度、
    ///   切后台续跑、用户可取消），operation 在系统回调里执行；提交失败或 `startTimeout` 内系统未启动 → 回落前台直接执行；
    /// - 更早系统：直接前台执行（此时只有 `beginBackgroundTask` 的 ≈30 秒宽限，调用方文案须如实）。
    /// 返回 operation 的结果。
    ///
    /// 2026-10-04 评审 C1-1/C1-2/C1-3（discussions/2026-10-04-background-tasks-council.md）三处契约修复：
    /// - C1-1 单飞：同 identifier 已有在途 pending 时不覆盖（覆盖曾使第一调用方的
    ///   continuation 永不 resume、双装场景永久「安装中」），本调用方回落前台直跑；
    /// - C1-2 孤儿撤销：回落执行前撤掉系统队列中的挂起同名请求（官方语义只撤挂起，
    ///   不伤运行中任务）——此前超时回落遗留孤儿请求，下一轮同 identifier 提交可能
    ///   撞 tooManyPendingTaskRequests；
    /// - C1-3 取消穿透：调用方取消且系统尚未取走 pending 时，撤销系统请求并以 false
    ///   确定性收尾；系统已取走则不杀工作（工作保全，系统侧由到期/进度机制管控）。
    ///   三条路径对 continuation 恰一次 resume（takePending 的 taken 标志保证）。
    public func runContinued(identifier: String, title: String, subtitle: String,
                             startTimeout: Duration = .seconds(8),
                             operation: @escaping ContinuedOperation) async -> Bool {
        guard #available(iOS 26, *), isContinuedRegistered(identifier) else {
            return await Self.runForegroundWithAssertion(operation: operation)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        return await withTaskCancellationHandler {
            let resolution = await withCheckedContinuation { (completion: CheckedContinuation<ContinuedResolution, Never>) in
                let pending = PendingContinued(operation: operation, completion: completion)
                guard installPending(identifier, pending) else {
                    completion.resume(returning: .runForeground)   // C1-1：已有在途，不安装不提交
                    return
                }
                do {
                    // C1-2：先撤后提（与 submit(_:now:) 同纪律;官方同名重提=替换,
                    // 保守对齐——进程重启后遗留的陈旧同名请求在此被清）
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    let kind = Self.classify(error)
                    lock.lock()
                    lastSubmitFailure[identifier] = String(describing: error)
                    lastSubmitFailureKind[identifier] = kind
                    lock.unlock()
                    guard let taken = takePending(identifier) else { return }
                    Task { taken.completion.resume(returning: .runForeground) }
                    return
                }
                // 系统迟迟不启动（排队/资源受限）→ 不让用户干等：回落前台执行；谁先 take 谁执行，另一方看到 nil 即退出
                Task {
                    try? await Task.sleep(for: startTimeout)   // try?-ok: 取消即不回落
                    guard let taken = self.takePending(identifier) else { return }
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)   // C1-2：孤儿撤销
                    taken.completion.resume(returning: .runForeground)
                }
            }
            switch resolution {
            case .done(let ok): return ok
            case .runForeground: return await Self.runForegroundWithAssertion(operation: operation)
            }
        } onCancel: {
            // C1-3：调用方取消——系统未取走则撤请求并以 false 收尾；已取走则不杀工作
            guard let taken = self.takePending(identifier) else { return }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            taken.completion.resume(returning: .done(false))
        }
    }

    /// 安装 pending（C1-1 单飞）：identifier 已有在途即失败返回 false（锁内判定，
    /// 杜绝覆盖——覆盖曾使第一调用方的 continuation 永不 resume）。
    private func installPending(_ identifier: String, _ pending: PendingContinued) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingContinued[identifier] == nil else { return false }
        pendingContinued[identifier] = pending
        return true
    }

    private func isContinuedRegistered(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registered && continuedIdentifiers.contains(identifier)
    }

    private func takePending(_ identifier: String) -> PendingContinued? {
        lock.lock(); defer { lock.unlock() }
        guard let pending = pendingContinued[identifier], !pending.taken else { return nil }
        pending.taken = true
        pendingContinued[identifier] = nil
        return pending
    }

    private final class ExpiryFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            get { lock.withLock { flag } }
            set { lock.withLock { flag = newValue } }
        }
    }
}
/// beginBackgroundTask 断言句柄盒（C4）：identifier 须在过期回调与 defer 间共享，
/// 锁串行化（过期回调线程未知）。C1-7a（2026-10-04 评审）自 private 提级为共享类型：
/// 医疗目录更新等「无系统续跑通道的前台收尾」场景复用（iOS ≤25 只有 ≈30s 宽限）。
final class BackgroundAssertionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin(name: String) {
        lock.lock(); defer { lock.unlock() }
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

#endif
