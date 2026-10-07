import Foundation
import Domain
import Infrastructure
import Perception

/// ASR 索引「检查更新」状态机（2026-10-07 统一更新中心批，自 `ASREngineSettingsSection`
/// 原子提升；架构席 §3 设计）。
///
/// **搬迁纪律**（该文件祖先有两起「主线程冻结→看门狗强杀」事故档案，见
/// `ASREngineSettingsSection` 内注释）：本类只搬「网络 + 计数 + 看门狗 + 单飞」——
/// 信任库取锁/读盘派生（`rebuildAvailability`）仍留在视图侧 detached 路径，不引入
/// 任何新锁面。单飞/看门狗/离场语义与提升前逐条同源。
@MainActor
@Perceptible
final class ASRIndexCheckState {
    /// 「检查更新」三元结果（原视图私有枚举原样上提）。
    enum CheckState: Equatable {
        case idle, checking, upToDate, updates(Int), failed
    }

    private(set) var index: ASRModelReleaseIndex?
    private(set) var state: CheckState = .idle
    /// 派生结论重算代次：新索引落定 / 视图侧删除完成时自增（视图 `.task(id:)` 依赖）。
    private(set) var derivationEpoch = 0

    private let fetchIndex: @Sendable (URL) async throws -> ASRModelReleaseIndex
    private let appVersion: @MainActor () -> String
    private let isInstallActive: @MainActor () -> Bool
    private let checkTimeout: Duration

    private var refreshTask: Task<Void, Never>?
    private var fetchTask: Task<ASRModelReleaseIndex, Error>?

    /// 测试缝（DoD 覆盖）：拉取与超时时长可注入——默认生产实现与提升前逐字同源
    /// （`service.fetchIndex(from: indexURL)` / 30s 看门狗）。
    init(fetchIndex: @escaping @Sendable (URL) async throws -> ASRModelReleaseIndex = {
             try await ASRModelDownloadService.shared.fetchIndex(from: $0)
         },
         appVersion: @escaping @MainActor () -> String = {
             (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
         },
         checkTimeout: Duration = .seconds(30),
         isInstallActive: @escaping @MainActor () -> Bool) {
        self.fetchIndex = fetchIndex
        self.appVersion = appVersion
        self.checkTimeout = checkTimeout
        self.isInstallActive = isInstallActive
    }

    /// 是否处于「真在跑的安装」（暂停中的安装不算——任务已退出、暂存保留；
    /// 与提升前 `installCenter.active.contains { !$0.isPaused }` 逐字同源）。
    var installBusy: Bool { isInstallActive() }

    /// 域链面聚合态（统一更新中心主行输入；安装进行中优先呈 updating）。
    var chainSummary: UpdateChainRowState {
        if isInstallActive() { return .updating }
        switch state {
        case .idle: return .notChecked
        case .checking: return .checking
        case .upToDate: return .upToDate
        case .updates: return .updateAvailable
        case .failed: return .failed
        }
    }

    /// 显式检查（单飞；同步置位 `.checking` 后入异步——「检查全部更新」编排
    /// 依赖此同步段防连点）。
    func check() {
        guard refreshTask == nil else { return }
        state = .checking
        let fetch = Task { try await fetchIndex(ASRModelDownloadService.indexURL) }
        fetchTask = fetch
        // 看门狗：超时即取消请求（`metadata` 逐字节遍历里有 `Task.checkCancellation()`，
        // 取消能真正中断），回到「失败可重试」而不是永久转圈（业主 2026-09-16 第 4 项）。
        let timeout = checkTimeout
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }   // 正常路径下被取消
            fetch.cancel()
        }
        refreshTask = Task { [weak self] in
            defer { fetch.cancel(); watchdog.cancel() }
            do {
                let fetched = try await fetch.value
                guard let self, !Task.isCancelled else { return }
                self.index = fetched
                self.derivationEpoch += 1
                let version = self.appVersion()
                // 统计循环移出主 actor（2026-10-05 审查修正原样保留）：每档位数次
                // 取信任库锁 + 读盘，主线程同款模式即冻结事故成因。
                let count = await Task.detached(priority: .userInitiated) { () -> Int in
                    VoiceEngineChoice.allCases.reduce(into: 0) { total, choice in
                        let latest = ASRModelDownloadService.latest(for: choice, in: fetched, appVersion: version)
                        let update = ASRModelDownloadService.updateAvailable(for: choice, index: fetched, appVersion: version)
                        let isNewInstall = latest != nil && ASRModelDownloadService.installedVersion(for: choice) == nil
                        if update != nil || isNewInstall { total += 1 }
                    }
                }.value
                self.state = count > 0 ? .updates(count) : .upToDate
                self.refreshTask = nil
                self.fetchTask = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                // 安装进行中：服务层互斥的诚实呈现（2026-09-16 评审事故的对偶）——
                // 「正在下载」不得渲染为「功能坏了」，归 notChecked（.idle）。
                if let failure = error as? ASRDownloadFailure, case .installInProgress = failure {
                    self.state = .idle
                } else {
                    // 拉取失败保留旧索引（若有）：更新/下载按钮仍可用。
                    self.state = .failed
                }
                self.refreshTask = nil
                self.fetchTask = nil
            }
        }
    }

    /// 取消检查：真中断（外层 + 内层 fetch 一并取消，看门狗随 defer 收口）+
    /// 回 `.idle`；迟到结果由任务内 `Task.isCancelled` 守卫丢弃。
    func cancel() {
        guard state == .checking else { return }
        refreshTask?.cancel()
        fetchTask?.cancel()
        state = .idle
        refreshTask = nil
        fetchTask = nil
    }

    /// 外部事实变化（如视图侧删除完成）时由调用方自增派生代次。
    func bumpDerivation() {
        derivationEpoch += 1
    }
}
