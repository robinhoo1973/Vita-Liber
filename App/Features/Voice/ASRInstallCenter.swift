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

    /// 单个进行中的安装（有序数组供首页稳定呈现；进度/阶段随回调更新）。
    struct Install: Identifiable, Equatable {
        let id: UUID
        let choice: VoiceEngineChoice
        var progress: ASRModelDownloadService.DownloadProgress?
        var phase: ASRModelDownloadService.InstallPhase?
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
        let id = UUID()
        active.append(Install(id: id, choice: choice))
        failed.remove(choice)
        lastFailure = nil
        tasks[choice] = Task { [weak self] in
            await self?.run(release, choice: choice, id: id, baseURL: baseURL)
        }
    }

    /// 首页失败卡关闭（用户已看到并处置）。
    func dismissFailure() { lastFailure = nil }

    func cancel(_ choice: VoiceEngineChoice) {
        tasks[choice]?.cancel()
    }

    private func run(_ release: ASRModelRelease, choice: VoiceEngineChoice, id: UUID, baseURL: URL?) async {
        defer {
            active.removeAll { $0.id == id }
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
            _ = try await service.install(release, baseURL: baseURL) { progress in
                Task { @MainActor [weak self] in
                    guard let index = self?.active.firstIndex(where: { $0.id == id }) else { return }
                    self?.active[index].progress = progress
                }
            } onPhase: { phase in
                Task { @MainActor [weak self] in
                    guard let index = self?.active.firstIndex(where: { $0.id == id }) else { return }
                    self?.active[index].phase = phase
                }
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
