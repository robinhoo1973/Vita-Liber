import Foundation
import Domain
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
/// （语言列表与档位可用性据此重算）、后台窗口（`beginBackgroundTask`，~30min）。
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

        init(id: UUID, choice: VoiceEngineChoice) {
            self.id = id
            self.choice = choice
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
                if let current = self.progress,
                   current.series == progress.series,
                   current.receivedBytes >= progress.receivedBytes { return }
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
    private(set) var failed: Set<VoiceEngineChoice> = []
    /// 最近一次失败（2026-09-16 委员会评审）：此前失败只在设置页三跳外可见、
    /// 首页卡片静默消失——用户从首页发起下载后失败无任何反馈。留到用户
    /// 显式处置（重试/关闭）或再次发起。
    private(set) var lastFailure: VoiceEngineChoice?

    private let service = ASRModelDownloadService.shared
    private let dataChange: AppDataChangeCenter
    private var tasks: [VoiceEngineChoice: Task<Void, Never>] = [:]

    init(dataChange: AppDataChangeCenter) {
        self.dataChange = dataChange
    }

    func isInstalling(_ choice: VoiceEngineChoice) -> Bool {
        active.contains { $0.choice == choice }
    }

    func install(_ choice: VoiceEngineChoice) -> Install? {
        active.first { $0.choice == choice }
    }

    /// 启动安装（per-choice 幂等：同一模型在装时忽略重复请求）。
    func start(_ release: ASRModelRelease, baseURL: URL?) {
        guard let choice = VoiceEngineChoice(rawValue: release.id), !isInstalling(choice) else { return }
        let install = Install(id: UUID(), choice: choice)
        active.append(install)
        failed.remove(choice)
        lastFailure = nil
        tasks[choice] = Task { [weak self] in
            await self?.run(release, choice: choice, install: install, baseURL: baseURL)
        }
    }

    /// 首页失败卡关闭（用户已看到并处置）。
    func dismissFailure() { lastFailure = nil }

    func cancel(_ choice: VoiceEngineChoice) {
        tasks[choice]?.cancel()
    }

    private func run(_ release: ASRModelRelease, choice: VoiceEngineChoice, install: Install, baseURL: URL?) async {
        defer {
            active.removeAll { $0.id == install.id }
            tasks[choice] = nil
        }
        // 切后台继续下载窗口：beginBackgroundTask 给系统级 ~30min 宽限；
        // 更长（锁屏整夜）需 background URLSession——登记 tech §11 技术债。
        #if os(iOS)
        var assertion: UIBackgroundTaskIdentifier = .invalid
        assertion = UIApplication.shared.beginBackgroundTask(withName: "asr-model-install") {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
        #endif
        do {
            // 直接投递到该安装自身的可观察对象（见 `Install` 说明）——不再经
            // `active[index]` 变址写入，首页全量聚合因此不再被高频进度牵连。
            _ = try await service.install(release, baseURL: baseURL) { progress in
                install.submit(progress: progress)
            } onPhase: { phase in
                install.submit(phase: phase)
            }
            // 资产失效广播：语言列表/档位可用性据此重算（下载完了才能选）。
            dataChange.assetsChanged()
        } catch is CancellationError {
            // 用户取消：不记失败（可再发起）。
        } catch {
            failed.insert(choice)
            lastFailure = choice
        }
    }
}
