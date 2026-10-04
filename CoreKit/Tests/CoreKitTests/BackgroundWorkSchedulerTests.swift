import Foundation
import Testing
@testable import Domain
@testable import Infrastructure
@testable import Protocols

/// 2026-10-04 后台任务专项评审 C1-4 seam（discussions/2026-10-04-background-tasks-council.md）：
/// BackgroundWorkScheduler 经 BackgroundTaskScheduling 端口注入假调度器，runContinued
/// 三契约（单飞/孤儿撤销/取消穿透）与 register/submit/handle 链路在 Linux 即可断言——
/// 此前门面整体 `#if os(iOS)`，这些契约唯一可见面是 macOS CI 事后红。
@Suite("SU-M2-HEALTHSYNC · BackgroundWorkScheduler 调度契约")
struct BackgroundWorkSchedulerTests {

    // MARK: - 假调度器

    private final class FakeScheduler: BackgroundTaskScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var launches: [String: @Sendable (any BackgroundTaskHandle) -> Void] = [:]
        private var submittedRequests: [BackgroundTaskRequest] = []
        private var cancelledIDs: [String] = []
        var submitError: BackgroundTaskSubmitError?
        var registerResult = true

        func register(identifier: String, launch: @escaping @Sendable (any BackgroundTaskHandle) -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            launches[identifier] = launch
            return registerResult
        }
        func submit(_ request: BackgroundTaskRequest) throws {
            lock.lock(); defer { lock.unlock() }
            if let submitError { throw submitError }
            submittedRequests.append(request)
        }
        func cancel(identifier: String) {
            lock.lock(); defer { lock.unlock() }
            cancelledIDs.append(identifier)
        }

        func launch(identifier: String, with handle: any BackgroundTaskHandle) {
            let handler = lock.lock { launches[identifier] }
            handler?(handle)
        }
        func submitted() -> [BackgroundTaskRequest] { lock.lock { submittedRequests } }
        func cancelled() -> [String] { lock.lock { cancelledIDs } }
    }

    private final class FakeHandle: BackgroundTaskHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var completed: [Bool] = []
        private var storedExpiration: (@Sendable () -> Void)?
        var progressValue: Progress?
        func setTaskCompleted(success: Bool) { lock.lock { completed.append(success) } }
        var expirationHandler: (@Sendable () -> Void)? { lock.lock { storedExpiration } }
        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.lock { storedExpiration = handler }
        }
        var progress: Progress? { progressValue }
        func completions() -> [Bool] { lock.lock { completed } }
        func fireExpiration() { expirationHandler?() }
    }

    private struct EchoJob: BackgroundJob {
        let descriptor: BackgroundJobDescriptor
        let result: BackgroundJobOutcome
        func run(budget: Duration) async -> BackgroundJobOutcome { result }
    }

    private struct SlowJob: BackgroundJob {
        let descriptor: BackgroundJobDescriptor
        func run(budget: Duration) async -> BackgroundJobOutcome {
            try? await Task.sleep(for: .milliseconds(200))   // try?-ok: 取消即提前返回
            return BackgroundJobOutcome(success: true, reschedule: false)
        }
    }

    private func makeScheduler(_ fake: FakeScheduler, registerContinued: Bool = true) -> BackgroundWorkScheduler {
        let scheduler = BackgroundWorkScheduler(system: fake)
        scheduler.continuedPlatformAvailable = true
        if registerContinued { scheduler.addContinued(identifier: "com.test.continued") }
        scheduler.registerAll()
        scheduler.registerContinuedAll()
        return scheduler
    }

    /// 作业型装配：add 必须在 registerAll 之前（registerAll 之后的登记会被拒绝——响亮失败语义本身）。
    private func makeJobScheduler(_ fake: FakeScheduler, _ job: any BackgroundJob) -> BackgroundWorkScheduler {
        let scheduler = BackgroundWorkScheduler(system: fake)
        #expect(scheduler.add(job))
        scheduler.registerAll()
        return scheduler
    }

    // MARK: - register/submit/handle 链路

    @Test("registerAll 登记回执落账；submit 先撤后提")
    func registerAndSubmitOrder() {
        let fake = FakeScheduler()
        let job = EchoJob(descriptor: BackgroundJobDescriptor(identifier: "com.test.job", kind: .refresh, minimumInterval: 900),
                          result: BackgroundJobOutcome(success: true, reschedule: false))
        let scheduler = makeJobScheduler(fake, job)
        #expect(scheduler.submit("com.test.job") == true)
        #expect(fake.cancelled().last == "com.test.job")   // 先撤
        #expect(fake.submitted().last?.identifier == "com.test.job")   // 后提
    }

    @Test("submit 失败按平台无关错误分类落账")
    func submitFailureKindMapping() {
        let fake = FakeScheduler()
        let job = EchoJob(descriptor: BackgroundJobDescriptor(identifier: "com.test.job", kind: .refresh, minimumInterval: 900),
                          result: BackgroundJobOutcome(success: true, reschedule: false))
        let scheduler = makeJobScheduler(fake, job)
        fake.submitError = .notPermitted
        #expect(scheduler.submit("com.test.job") == false)
        #expect(scheduler.submitFailureKind(for: "com.test.job") == .notPermitted)
        #expect(scheduler.registrationFailed(for: "com.test.job") == false)   // 注册回执 true → 非注册失败
    }

    @Test("系统唤起：作业按结果回报完成并按 outcome 重排")
    func launchRunsJobAndCompletes() async {
        let fake = FakeScheduler()
        let job = EchoJob(descriptor: BackgroundJobDescriptor(identifier: "com.test.job", kind: .refresh, minimumInterval: 900),
                          result: BackgroundJobOutcome(success: true, reschedule: true))
        let scheduler = makeJobScheduler(fake, job)
        let handle = FakeHandle()
        fake.launch(identifier: "com.test.job", with: handle)
        try? await Task.sleep(for: .milliseconds(50))   // try?-ok: 测试同步等待,取消即提前返回 // 让 work Task 落定
        #expect(handle.completions() == [true])
        #expect(fake.submitted().count == 1)   // reschedule:true → 重排一次
    }

    // MARK: - runContinued 三契约

    @Test("C1-1 单飞：同 identifier 第二调用方不覆盖、直接前台回落；系统仅一次提交")
    func runContinuedSingleFlight() async {
        let fake = FakeScheduler()
        let scheduler = makeScheduler(fake)
        var firstRan = false
        var secondRan = false
        async let first: Bool = scheduler.runContinued(identifier: "com.test.continued",
                                                       title: "t", subtitle: "s",
                                                       startTimeout: .seconds(1)) { _, _ in
            firstRan = true
            try? await Task.sleep(for: .milliseconds(30))   // try?-ok: 测试同步等待,取消即提前返回
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))   // try?-ok: 测试同步等待,取消即提前返回 // 让第一个先安装 pending
        async let second: Bool = scheduler.runContinued(identifier: "com.test.continued",
                                                        title: "t", subtitle: "s",
                                                        startTimeout: .seconds(1)) { _, _ in
            secondRan = true
            return true
        }
        _ = await (first, second)
        #expect(firstRan && secondRan)   // 两方都执行（第二方回落前台，不悬挂）
        #expect(fake.submitted().count == 1)   // 系统仅一次提交（不覆盖不重提）
    }

    @Test("C1-2 孤儿撤销：启动超时回落后撤掉挂起请求")
    func runContinuedTimeoutFallbackCancelsOrphan() async {
        let fake = FakeScheduler()
        let scheduler = makeScheduler(fake)
        var ran = false
        let ok = await scheduler.runContinued(identifier: "com.test.continued",
                                              title: "t", subtitle: "s",
                                              startTimeout: .milliseconds(30)) { _, _ in
            ran = true
            return true
        }
        #expect(ok && ran)
        #expect(fake.cancelled().filter { $0 == "com.test.continued" }.count == 2)   // 先撤后提 + 孤儿撤销
        #expect(fake.submitted().count == 1)
    }

    @Test("C1-3 取消穿透：调用方取消且系统未取走 → 撤请求并以 false 确定性收尾")
    func runContinuedCancellationPropagates() async {
        let fake = FakeScheduler()
        let scheduler = makeScheduler(fake)
        var ran = false
        let task = Task {
            await scheduler.runContinued(identifier: "com.test.continued",
                                         title: "t", subtitle: "s",
                                         startTimeout: .seconds(1)) { _, _ in
                ran = true
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(10))   // try?-ok: 测试同步等待,取消即提前返回
        task.cancel()
        let ok = await task.value
        #expect(ok == false)
        #expect(ran == false)   // 系统未取走即取消：operation 不执行
        #expect(fake.submitted().count == 1)
    }

    @Test("C1-3 已取走不杀工作：系统唤起路径正常执行并恰一次 resume")
    func runContinuedSystemLaunchRunsOperation() async {
        let fake = FakeScheduler()
        let scheduler = makeScheduler(fake)
        let handle = FakeHandle()
        let op = Task {
            await scheduler.runContinued(identifier: "com.test.continued",
                                         title: "t", subtitle: "s",
                                         startTimeout: .seconds(1)) { _, _ in
                true
            }
        }
        try? await Task.sleep(for: .milliseconds(10))   // try?-ok: 测试同步等待,取消即提前返回
        fake.launch(identifier: "com.test.continued", with: handle)   // 系统先取走
        let ok = await op.value
        #expect(ok == true)
        #expect(handle.completions() == [true])
        // 超时回落 Task 见 takePending 为 nil 即退出——无二次 resume（崩溃即失败）
        try? await Task.sleep(for: .milliseconds(30))   // try?-ok: 测试同步等待,取消即提前返回
    }

    @Test("过期回调：expirationHandler 触发即取消作业并回报失败")
    func expirationCancelsJob() async {
        let fake = FakeScheduler()
        // 慢作业：到期必须落在执行中（EchoJob 即时返回时完成先于取消，测不到折叠语义）
        let slow = SlowJob(descriptor: BackgroundJobDescriptor(identifier: "com.test.job", kind: .refresh, minimumInterval: 900))
        let scheduler = makeJobScheduler(fake, slow)
        let handle = FakeHandle()
        fake.launch(identifier: "com.test.job", with: handle)
        try? await Task.sleep(for: .milliseconds(20))   // try?-ok: 测试同步等待,取消即提前返回
        handle.fireExpiration()
        try? await Task.sleep(for: .milliseconds(250))   // try?-ok: 测试同步等待,取消即提前返回
        #expect(handle.completions() == [false])   // Task.isCancelled → success 折叠为 false
    }
}

private extension NSLock {
    func lock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
