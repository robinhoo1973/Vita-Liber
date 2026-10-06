import Foundation
import Domain
import Protocols
import Infrastructure
import Perception
#if os(iOS)
import UIKit   // beginBackgroundTask（切后台继续下载窗口）
#endif

/// ASR 模型安装中心（2026-09-16 业主实测）：下载进行态从设置页 `@State` 提升到
/// App 层可观察对象——两个直接动因：
/// ① **首页可见**：后台任务进度显示在首页（形如档案完善进度卡），离开设置页/切后台
///    仍能看到与取消；
/// ② 原自持状态在离开设置页时**丢失**（下载仍在跑但 UI 归零，回来显示「未下载」），
///    提升后状态与生命周期脱离视图。
///
/// 职责：启动/取消安装、持有进行态（进度/阶段）、完成广播 `assetsChanged()`
/// （语言列表与档位可用性据此重算）、后台窗口。
/// **后台事实（round5 Q2 更正）**：`beginBackgroundTask` 在 iOS 13+ 只给**约 30 秒**（前台切后台约 3 分钟）宽限——此前注释
/// 误记「~30min」、UI 文案「可切到后台继续下载」在 iOS ≤25 属误导。现：iOS 26 经 `BackgroundWorkScheduler.runContinued`
/// 提交 continued processing（切后台续跑、系统显示进度、可取消）；更早系统如实提示「请保持在前台」。
/// 锁屏整夜级下载需后台 `URLSession`（下载任务 + 委托持久化）——登记 tech §11 技术债，另轮迁移。
/// 索引与授权检查留在调用方（设置页自持 `index`，安全审查 2026-09-12 的显式联网面不变）。
@MainActor
@Perceptible
final class ASRInstallCenter {

    /// 单个进行中的安装（有序数组供首页稳定呈现）。
    ///
    /// **进度/阶段是独立可观察对象，不是数组元素里的值**——2026-09-16 业主实测
    /// 「下载没有实时进度展示」的根因：原先写作 `active[index].progress = x`，
    /// 经数组 `_modify` 变址写入会让**所有**观察 `active` 的视图失效。首页 body
    /// 恰是一个 `WithPerceptionTracking` 包住全量提醒聚合（`HomeView:228` +
    /// `aggregatedItems`：5 遍扫描 + 逐项日历运算），于是**每 200ms 一次的进度写入
    /// 都重跑一遍全量聚合**（`ProgressCounter` 节流上限 = 5 Hz），主 actor 饱和后
    /// 进度条自身的渲染反而被挤掉——现象就是「卡住不动」。
    ///
    /// 拆开后观察域分离：`active` 只在安装开始/结束时变化（低频），进度只让持有它
    /// 的那张卡片重渲染（高频）。
    @MainActor
    @Perceptible
    final class Install: Identifiable {
        let id: UUID
        let choice: VoiceEngineChoice
        var progress: ASRModelDownloadService.DownloadProgress?
        var phase: ASRModelDownloadService.InstallPhase?
        /// 2026-09-19 审查修复（并发槽满排队）：true = 在等下载槽位（服务端 FIFO 排队，
        /// 尚无任何阶段/进度回调）；首个阶段回调到达即翻转。等待态如实呈现
        /// 「排队中」，不再把本机并发上限误报成网络错误。
        var waiting = true
        /// 2026-10-05 业主反馈修复批（完成态保留）：安装成功终态标记——
        /// `.pruning` 是真实进行阶段不可当终态，故独立标志一次性翻转
        /// （低频，与 waiting 同频级——组卡头观察域纪律不受破坏）。
        private(set) var isFinished = false
        /// 暂停态（2026-10-06 业主反馈批第 2 项：子卡滑动「暂停」）：低频一次性翻转，
        /// 与 waiting/isFinished 同频级——组卡头观察域纪律不受破坏（头只读低频道标量）。
        /// 暂停 = 停止本次传输但保留卡片与已收字节（服务端按暂停标记保留续传暂存）。
        private(set) var isPaused = false
        /// 暂停/恢复重启所需载荷：暂停只停任务不弃卡片，恢复按原条目原地址接续
        /// （续传起点由服务端 `resumableStaging` 命中暂停暂存后自行解析）。
        let release: ASRModelRelease
        let baseURL: URL?

        init(id: UUID, choice: VoiceEngineChoice, release: ASRModelRelease, baseURL: URL?) {
            self.id = id
            self.choice = choice
            self.release = release
            self.baseURL = baseURL
        }

        /// 仅安装中心在成功分支标记（失败/取消不标记）。
        fileprivate func markFinished() { isFinished = true }
        fileprivate func markPaused() { isPaused = true }
        fileprivate func clearPause() { isPaused = false }
        /// 恢复前重置进度基线（2026-10-06 评审修正）：暂停点显示的是各段峰值之和，
        /// 而续传起点是**连续前缀**（可能显著小于峰值）——不清基线则恢复后的回调
        /// （同 series、received 更低）被单调守卫整体丢弃，进度条钉在高于实际存量的
        /// 旧值、`fraction` 也失真。清空后首个回调即入账（回落不确定态仅一瞬）。
        fileprivate func resetProgressForResume() { progress = nil }

        /// 可暂停窗口（Domain 纯函数门控）：排队/下载段可暂停；校验/解压段
        /// package.zip 已完整、暂停无有价值续传点，只提供取消。
        var isPausable: Bool {
            ASRDownloadProgress.isPausable(phase: phase, waiting: waiting,
                                           isFinished: isFinished, isPaused: isPaused)
        }

        /// 进度写入（下载线程可调，内部 hop 主 actor）。
        /// **单调守卫**：原实现每次回调新建一个无序 `Task{}` 跳主线程，乱序到达会让
        /// 进度条**往回跳**；此处丢弃 `receivedBytes` 不增的旧值。
        /// 保留单次 hop（5 Hz 量级，成本可忽略）——病根是观察域而非 hop 频率。
        nonisolated func submit(progress: ASRModelDownloadService.DownloadProgress) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 2026-09-20 修复：阶段切换（submit(phase:) 清空 progress）后，
                // 下载阶段排队在途的旧系列 hop（series 0/1）可能晚到并重新装回
                // 已清空的槽位——校验/解压分支用旧下载快照渲染，条钉死在旧百分比。
                // 校验/解压系列自 2 起（下载 = 0/1，ASRModelDownloadService 契约），
                // 非下载阶段直接弃下载系列回包。
                if let phase = self.phase, phase != .downloading, progress.series < 2 { return }
                // 单调守卫**限同系列**（审查修复 2026-09-18）：同系列内乱序旧值
                // 丢弃；跨系列（分段退单流/校验/解压——同一 totalBytes 从 0 重计）
                // 一律放行——此前按 totalBytes 相同 + received 不增判定，单流重建
                // 计数器的每次回调都被当作旧值丢弃，进度条钉死在分段峰值数分钟
                // （业主实测「进度条无反应、百分比不变化」）。
                // 2026-10-03 评审 R1-10b：委托 Domain 纯函数（Linux 已测）——
                // 行为差异仅在 received 相等时：Domain 收（totalBytes 服务端修正
                // 得以入账，更诚实），旧 App 复本拒；差异已登记测试用例。
                if !ASRDownloadProgress.shouldAccept(previous: self.progress, incoming: progress) { return }
                self.progress = progress
            }
        }

        nonisolated func submit(phase: ASRModelDownloadService.InstallPhase) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 2026-09-19：首个阶段回调 = 排队结束（槽位已获），等待态翻转。
                self.waiting = false
                // 阶段切换即重置进度基线（2026-09-16 审查修复）：校验/解压自本批起
                // 复用同一 progress 出口，而它们的「已处理字节」从 0 起算，下载阶段
                // 收尾停在 totalBytes——`submit(progress:)` 的单调守卫会把新阶段的
                // 每一次回调都判成「不增」而丢弃，进度条钉在 100% 不动（现象与
                // 「校验无反馈」同，只是从「转圈」变成「满格不动」）。清空后新阶段
                // 的第一个回调即可入账；跨阶段仍不会回跳（新阶段从 0 单调上升）。
                // 激活/清理两阶段无粒度：清空后界面回落不确定进度（spinner）。
                if self.phase != phase { self.progress = nil }
                self.phase = phase
            }
        }
    }

    private(set) var active: [Install] = []
    /// 2026-10-05 业主反馈修复批（第 1 项）：**最近完成**的安装保留列表——
    /// 组卡子信息卡继续显示完成项（完成图标），未完成继续；`active` 语义
    /// 「进行中」不变（isInstalling/失败卡门控/关怀卡全读 active，不污染）。
    /// 驻留至用户显式移除（或新批次开始）；跨重启不持久化（App 层状态，
    /// 与 active 同生命周期）。
    private(set) var finished: [Install] = []
    private(set) var failed: Set<VoiceEngineChoice> = []
    /// 最近一次失败（2026-09-16 委员会评审）：此前失败只在设置页三跳外可见、
    /// 首页卡片静默消失——用户从首页发起下载后失败无任何反馈。留到用户
    /// 显式处置（重试/关闭）或再次发起。
    /// 2026-09-27 委员会 UX 席：升级为可重试载荷——注释曾谎称「含 [重试]」实为
    /// 仅关闭（HomeSubviews 漂移），重试需携带 release/baseURL 才能原样重启。
    struct LastFailure {
        let choice: VoiceEngineChoice
        let release: ASRModelRelease
        let baseURL: URL?
    }
    private(set) var lastFailure: LastFailure?

    private let service = ASRModelDownloadService.shared
    private let dataChange: AppDataChangeCenter
    private var tasks: [VoiceEngineChoice: Task<Void, Never>] = [:]
    /// 暂停登记任务（2026-10-06 业主反馈批第 2 项）：保证「先登记服务端暂停标记、
    /// 再取消任务」的时序——乱序会让 performInstall 退出先于标记到达，按普通取消
    /// 清掉续传暂存。恢复/取消前 await 本任务，防残留标记。
    private var pauseOps: [VoiceEngineChoice: Task<Void, Never>] = [:]

    init(dataChange: AppDataChangeCenter) {
        self.dataChange = dataChange
        // 启动清扫（2026-10-05 删除模型流程）：补删上一会话被租约挡住的
        // 显式删除目录——后台执行，绝不阻塞启动（R2 交叉质询裁决 f1）。
        Task.detached(priority: .utility) {
            ASRModelDownloadService.sweepPendingRemovals()
        }
    }

    func isInstalling(_ choice: VoiceEngineChoice) -> Bool {
        active.contains { $0.choice == choice }
    }

    func install(_ choice: VoiceEngineChoice) -> Install? {
        active.first { $0.choice == choice }
    }

    /// 启动安装（per-choice 幂等：同一模型在装时忽略重复请求——含暂停中：
    /// 暂停的卡片仍在 `active`，恢复走 `resume` 而非重发 `start`）。
    func start(_ release: ASRModelRelease, baseURL: URL?) {
        guard let choice = VoiceEngineChoice(rawValue: release.id), !isInstalling(choice) else { return }
        let install = Install(id: UUID(), choice: choice, release: release, baseURL: baseURL)
        active.append(install)
        failed.remove(choice)
        lastFailure = nil
        // 新批次开始（无其他进行中任务）时清空上一批的完成行——防陈旧完成项
        // 混入新批次组卡（跨批次驻留无意义，批内可见即够）。
        if active.count == 1 { finished.removeAll() }
        tasks[choice] = Task { [weak self] in
            await self?.run(release, choice: choice, install: install, baseURL: baseURL)
        }
    }

    /// 移除单个完成行（组卡完成行的显式处置）。
    func removeFinished(_ choice: VoiceEngineChoice) {
        finished.removeAll { $0.choice == choice }
    }

    /// 首页失败卡关闭（用户已看到并处置）。
    /// 2026-10-05 审查修复:此前只清 lastFailure——failed 集合残留,设置页
    /// 失败徽标(ASREngineSettingsSection 读 failed.contains)永久点亮,
    /// 与首页卡状态分裂。
    func dismissFailure() {
        if let failure = lastFailure { failed.remove(failure.choice) }
        lastFailure = nil
    }

    /// 首页失败卡 [重试]（2026-09-27 UX 席）：携带失败载荷原样重启安装。
    func retryLastFailed() {
        guard let failure = lastFailure, !isInstalling(failure.choice) else { return }
        start(failure.release, baseURL: failure.baseURL)
    }

    /// 暂停单个安装（2026-10-06 业主反馈批第 2 项）：停止传输但保留卡片与已收字节。
    /// 时序（评审修正，勿再调换）：**先 await 服务端暂停标记落定，再置卡片暂停态并
    /// 取消任务**——① 先取消的话 performInstall 可能抢在标记到达前收尾，按普通取消
    /// 清掉续传暂存（暂停语义落空）；② 先置暂停态的话标记落定前若安装真失败，
    /// `run` 会按「暂停」吞掉失败（卡片显示已暂停却无任何字节与任务）。登记期间
    /// 安装可能已完成/失败（事实优先）：此时撤销标记，不留残旗。
    func pause(_ choice: VoiceEngineChoice) {
        guard let install = active.first(where: { $0.choice == choice }), install.isPausable else { return }
        let service = self.service
        pauseOps[choice] = Task { [weak self] in
            await service.markPaused(choice)
            guard let self, self.active.contains(where: { $0.id == install.id }) else {
                await service.clearPaused(choice)
                return
            }
            install.markPaused()
            self.tasks[choice]?.cancel()
        }
    }

    /// 恢复暂停的安装：清服务端残留标记后按原条目重启（服务端 `resumableStaging`
    /// 命中暂停暂存即从续传点接续，未命中则整包重下——如实语义）。
    /// 等待暂停登记期间若被新的暂停接管（本任务被取消）或安装又回到暂停态，
    /// 直接退出且**不清标记**（标记归新暂停所有，防把它的续传意图擦掉）。
    func resume(_ choice: VoiceEngineChoice) {
        guard let install = active.first(where: { $0.choice == choice }), install.isPaused,
              tasks[choice] == nil else { return }
        install.clearPause()
        install.resetProgressForResume()
        let service = self.service
        let pending = pauseOps[choice]
        pauseOps[choice] = nil
        tasks[choice] = Task { [weak self] in
            if let pending { _ = await pending.value }   // 暂停登记先落定，再清标记/重启（防乱序）
            guard !Task.isCancelled, !install.isPaused, let self,
                  self.active.contains(where: { $0.id == install.id }) else {
                // 启动前被取消/接管（2026-10-06 二轮评审）：本任务从未进入 `run`，
                // 句柄只能在此释放——否则 `tasks[choice]` 永久非 nil，后续「继续」
                // 全被幂等守卫吃掉（暂停僵尸死锁）。非暂停态且仍在 active = 用户
                // 取消的意图，卡片随本路径移除（`run` 的 defer 不会执行）。
                self?.tasks[choice] = nil
                if let self, !install.isPaused {
                    self.active.removeAll { $0.id == install.id }
                }
                return
            }
            await service.clearPaused(choice)
            await self.run(install.release, choice: choice, install: install, baseURL: install.baseURL)
        }
    }

    func cancel(_ choice: VoiceEngineChoice) {
        // 暂停中的取消（2026-10-06）：卡片即时移除 + 取消任务 + 丢弃**本代**续传暂存
        // （显式取消 = 不要部分数据）；await 暂停登记落定后再丢弃——乱序会让丢弃先执行、
        // 标记后落，留下残旗。清暂停态保证「系统已取走续跑任务后的完成回调」不把已取消
        // 卡片复活成已完成（与 2026-10-05 取消不标记完成的守卫同语义）。
        if let install = active.first(where: { $0.choice == choice }), install.isPaused {
            install.clearPause()
            active.removeAll { $0.id == install.id }
            tasks[choice]?.cancel()
            let service = self.service
            let pending = pauseOps[choice]
            pauseOps[choice] = nil
            Task {
                if let pending { _ = await pending.value }
                await service.discardPaused(choice, version: install.release.version)
            }
            return
        }
        // 进行中：只取消任务——暂存由 `run`→服务端 performInstall 的退出清理按
        // 「取消」处置（不在此处 discard：会删掉仍在写入的暂存目录）；卡片留给
        // run 的兜底清理，收尾窗口内 isInstalling 继续挡住重复发起。
        tasks[choice]?.cancel()
    }

    private func run(_ release: ASRModelRelease, choice: VoiceEngineChoice, install: Install, baseURL: URL?) async {
        defer {
            // 暂停（2026-10-06 业主反馈批第 2 项）：卡片保留在 active（呈现「已暂停」，
            // 可恢复/取消），仅释放任务句柄；取消/完成/失败照旧移除。
            if !install.isPaused { active.removeAll { $0.id == install.id } }
            tasks[choice] = nil
        }
        // 切后台宽限：beginBackgroundTask ≈30 秒（iOS 13+ 事实，非 30 分钟）——只够收尾一段；
        // 切后台续跑靳 iOS 26 continued processing（下方 runContinued）；锁屏整夜级需后台 URLSession（tech §11 技术债）。
        #if os(iOS)
        var assertion: UIBackgroundTaskIdentifier = .invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "asr-model-install") {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
        #endif
        let service = self.service
        // 值承接盒（CI 35588830526 告警族）：@Sendable operation 内不得变异捕获 var
        // （Swift 6 语言模式为错误）；nil = operation 从未执行（取消先于系统取走
        // 待处理续跑任务）。
        let outcome = ValueBox<Result<Void, Error>>()
        // 用户动作发起 → 统一入口 runContinued（iOS 26 续跑 + 系统进度；更早系统/提交失败回落前台直跑同一 operation）
        let completed = await BackgroundWorkScheduler.shared.runContinued(
            identifier: BackgroundWorkScheduler.asrInstallContinuedIdentifier,
            title: L10n.asrModelDownloading, subtitle: [release.id, release.variant].compactMap { $0 }.joined(separator: " · ")) { progress, _ in
            do {
                // 直接投递到该安装自身的可观察对象（见 `Install` 说明）——不再经
                // `active[index]` 变址写入，首页全量聚合因此不再被高频进度牵连。
                _ = try await service.install(release, baseURL: baseURL) { downloaded in
                    install.submit(progress: downloaded)
                    if let progress, downloaded.totalBytes > 0 {
                        progress.totalUnitCount = downloaded.totalBytes
                        progress.completedUnitCount = downloaded.receivedBytes
                    }
                } onPhase: { phase in
                    install.submit(phase: phase)
                }
                return true
            } catch {
                outcome.value = .failure(error)
                return false
            }
        }
        // 2026-10-05 审查修复:此前 `outcome.value ?? .success(())` 把「取消先于
        // 系统取走任务(operation 从未执行,outcome 恒 nil)」并入成功分支——
        // 未跑过的安装被标记完成并广播资产变更。completed = 系统侧真实完成
        // 与否;nil outcome + completed=false 一律按取消处置,不记失败不记完成。
        // 暂停判定（2026-10-06 二轮评审）：专用中断错误优先——服务端在传输层中断的
        // 时刻判定（无竞态）；`install.isPaused`/登记表查询兜底排队段暂停等路径。
        let pauseInterrupted: Bool = {
            if case .failure(let error)? = outcome.value { return error is ASRInstallPausedInterruption }
            return false
        }()
        if completed {
            // 暂停与完成竞态（2026-10-06）：系统已取走续跑任务后用户按暂停——操作
            // 已真实完成，完成事实优先（清暂停态走完成分支），不留在「已暂停」假态。
            let pausedRace = install.isPaused
            install.clearPause()
            // 2026-10-05 审查修正：系统已取走续跑任务后用户取消（takePending == nil
            // 无法中断）——系统侧完成回调仍会到达，但取消态不得标记完成/广播资产
            // 变更（否则「已取消」却以完成图标呈现且触发 assetsChanged 重算）。
            // 暂停竞态例外：完成是事实，同上按完成处置。
            guard !Task.isCancelled || pausedRace else { return }
            // 2026-10-05 业主反馈修复批（第 1 项）：完成态保留——标记终态并移入
            // finished（组卡子信息卡继续显示，完成图标；未完成继续）。defer 已把
            // 本安装移出 active，两列表互斥。
            install.markFinished()
            finished.append(install)
            if finished.count > 8 { finished.removeFirst(finished.count - 8) }
            // 资产失效广播：语言列表/档位可用性据此重算（下载完了才能选）。
            dataChange.assetsChanged()
        } else if pauseInterrupted || install.isPaused || await service.isPauseRequested(choice) {
            // 暂停：不记失败、不广播——卡片保留（defer 依 `isPaused` 保留），进度停在
            // 暂停点，恢复经 `resume` 从服务端续传暂存接续。
            // 2026-10-06 评审修正：以服务端登记为第二判据——传输层中断可能先于 App 侧
            // `markPaused` 到达（暂停时序是「先登记、后置卡片态」），只看卡片态会把暂停
            // 误判成取消（卡片被 defer 移除）。此处补置暂停态，让 defer 保留卡片。
            install.markPaused()
            return
        } else if case .failure(let error)? = outcome.value, error is CancellationError {
            return   // 用户取消：不记失败（可再发起）。
        } else if case .failure? = outcome.value {
            failed.insert(choice)
            lastFailure = LastFailure(choice: choice, release: release, baseURL: baseURL)
        }
    }

    /// 删除已装模型（2026-10-05 业主反馈修复批，第 6 项）：
    /// 服务层删除 → 引擎缓存/运行时池逐出（释放目录租约，R2 交叉质询）→
    /// 同会话补删 deferred 目录 → 资产广播（语言页/设置页可用性重算）。
    func delete(_ choice: VoiceEngineChoice) async throws {
        // 暂停登记在途先落定再删（2026-10-06 评审修正）：否则 pending 的 markPaused
        // 可能在 remove 清旗之后落下，给已删家族留下残旗（下一次安装退出时误判暂停、
        // 失败/取消也不清理暂存）。
        if let pending = pauseOps[choice] {
            _ = await pending.value
            pauseOps[choice] = nil
        }
        try await service.remove(choice)
        if let switchable = EngineRegistry.shared.resolve(TranscriptionEngineFactory.self) as? any TranscribingEngineEvicting {
            await switchable.evictEngine(choice)
        }
        await service.retryPendingRemovals(for: choice)
        // 暂停中的卡片随删除消失（2026-10-06 第 2 项）：暂停态属于本安装中心，
        // 服务删除不感知；不清理会留下指向已删家族的幽灵卡片。
        if let install = active.first(where: { $0.choice == choice }), install.isPaused {
            active.removeAll { $0.id == install.id }
            pauseOps[choice] = nil
        }
        failed.remove(choice)
        if lastFailure?.choice == choice { lastFailure = nil }
        finished.removeAll { $0.choice == choice }
        dataChange.assetsChanged()
    }
}
