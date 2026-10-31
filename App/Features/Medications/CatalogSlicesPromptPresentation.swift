import Foundation
import Domain

/// 首启卡聚合映射（2026-10-28 切片-only）：`CatalogSlicesState` 聚合态 → 单卡
/// descriptor。复用 `MedicalCatalogPromptAction` 动作词汇（两次显式点击语义不变：
/// check 只取元数据，install 才下载；activating 阶段不可取消 = journal 契约）。
/// 纯映射、无副作用，便于单测；文案由视图层用 L10n 键渲染。
enum CatalogSlicesPromptStatus: Equatable {
    /// 未检查（含「已装 N/3」副行）。
    case idleNoLocal(installed: Int)
    case checking
    /// 有候选（数量 + 预计下载总量）。
    case candidate(count: Int, totalSize: Int64)
    /// 某片安装阶段（kind 用于「正在更新 2/3 · 医院与科室」）。
    case phase(kind: CatalogSliceKind, progress: MedicalCatalogDownloadProgress)
    case completed(version: Int64?)
    case upToDate
    case sourcePartial(count: Int)
    case failure(failed: Int, hasLocal: Bool)
    case appUpdateRequired(count: Int)
    case unavailable
}

struct CatalogSlicesPromptDescriptor: Equatable {
    let primary: MedicalCatalogPromptAction
    let secondary: MedicalCatalogPromptAction?
    let autoEnter: Bool
    let status: CatalogSlicesPromptStatus
}

enum CatalogSlicesPromptPresentation {
    /// 强制模式判定（2026-10-29 业主两条原则）：**当前基础数据库没有 ∧ 第一次启动**
    /// 时下载不可跳过。任一不满足（已有任一片、或非首次启动）→ 维持常规旁路语义
    /// （V4.87 行为）——更新/补装对老用户不设强制门。
    @MainActor
    static func mandatoryDownload(state: CatalogSlicesState, firstLaunch: Bool) -> Bool {
        mandatoryDownload(firstLaunch: firstLaunch,
                          installedCount: state.installedCount,
                          installedCountAtUpdateStart: state.installedCountAtUpdateStart)
    }

    /// 纯判定（可单测）：一次安装会话内「本机 0 片」冻结在开始下载那一刻——
    /// installAll 逐片完成会让 installedCount 递增，旧实现据此把强制卡中途翻成
    /// 「可选」，下载中突然长出「取消下载并继续」第二个按钮。mock 的
    /// `mandatory()` 等价于 `firstLaunch && installed === 0`，且演示状态
    /// 只在四片全部完成后才把 installed 置 4——冻结起点即 1:1。
    static func mandatoryDownload(firstLaunch: Bool,
                                  installedCount: Int,
                                  installedCountAtUpdateStart: Int?) -> Bool {
        guard firstLaunch else { return false }
        if let startCount = installedCountAtUpdateStart { return startCount == 0 }
        return installedCount == 0
    }

    @MainActor
    static func descriptor(for state: CatalogSlicesState,
                           firstLaunch: Bool = false,
                           networkAvailable: Bool = true,
                           policyBlocked: Bool = false) -> CatalogSlicesPromptDescriptor {
        // 一次性完成事件：全部完成后自动进入（§5.12.4「成功才展示完成」）。
        if state.hasCompletedAnyUpdate, state.aggregate == .allCurrent {
            return .init(primary: .enter, secondary: nil, autoEnter: true,
                         status: .completed(version: nil))
        }
        // 业主第二原则（网络确认前置，2026-10-29）：强制模式下**先确认网络是否
        // 可用**——已知离线时不把用户困在卡上：直接给「先进入」（稍后到
        // 我的 → 模型与数据资源手动更新）；联网后再检查/安装。
        if mandatoryDownload(state: state, firstLaunch: firstLaunch), !networkAvailable || policyBlocked {
            return .init(primary: .recheck, secondary: .continueWithout, autoEnter: false,
                         status: .unavailable)
        }
        if let (kind, progress) = activeProgress(state) {
            // mock 1:1（2026-10-31）：进行中主按钮恒为禁用忙碌态（下载/校验/
            // 解密显示「正在下载…」，激活显示「正在完成安装，请勿关闭」），
            // 不再给「先去使用（下载继续）」的**可点**主按钮——mock 的
            // catalogPrimary() 在 phase 恒返回 null，renderCatalogCard 以
            // disabled + spinner 呈现。强制模式无次动作；常规模式只保留
            // 「取消下载并继续」。activating 阶段不可取消（journal 契约）。
            if case .activating = progress {
                return .init(primary: .busy, secondary: nil, autoEnter: false,
                             status: .phase(kind: kind, progress: progress))
            }
            return .init(primary: .busy,
                         secondary: mandatoryDownload(state: state, firstLaunch: firstLaunch)
                            ? nil : .cancelUpdateAndContinue,
                         autoEnter: false, status: .phase(kind: kind, progress: progress))
        }
        let strict = mandatoryDownload(state: state, firstLaunch: firstLaunch)
        switch state.aggregate {
        case .notChecked:
            return .init(primary: .check, secondary: strict ? nil : .continueWithout,
                         autoEnter: false,
                         status: .idleNoLocal(installed: state.installedCount))
        case .checking:
            return .init(primary: .busy, secondary: strict ? nil : .cancelCheckAndContinue,
                         autoEnter: false, status: .checking)
        case .updatesAvailable, .partialFailure:
            let status = CatalogSlicesPromptStatus.candidate(
                count: state.candidates.count, totalSize: state.totalDownloadBytes)
            if state.hasCandidate, state.canUpdate {
                return .init(primary: .install, secondary: strict ? nil : .continueWithout,
                             autoEnter: false, status: status)
            }
            return .init(primary: .recheck, secondary: strict ? nil : .continueWithout,
                         autoEnter: false, status: status)
        case .allCurrent:
            return .init(primary: .enter, secondary: nil, autoEnter: true, status: .upToDate)
        case .sourcePartial:
            return .init(primary: .enter, secondary: nil, autoEnter: true,
                         status: .sourcePartial(count: sourceGapCount(state)))
        case .allFailed:
            // 业主第二原则：无网络时不得把用户困在首启卡（只能退出系统的死路）——
            // 存在网络类失败（networkUnavailable）时允许「先进入」，稍后到
            // 我的 → 模型与数据资源 手动更新；校验/限流类失败仍只给重试。
            let allowOfflineExit = !strict || hasNetworkFailure(state)
            return .init(primary: .recheck, secondary: allowOfflineExit ? .continueWithout : nil,
                         autoEnter: false,
                         status: .failure(failed: failureCount(state),
                                          hasLocal: state.installedCount > 0))
        case .appUpdateRequired:
            // B7：minApp 未达只给 [进入 App]，绝不自动进入（避免强迫升级式循环）。
            return .init(primary: .enter, secondary: nil, autoEnter: false,
                         status: .appUpdateRequired(count: appGatedCount(state)))
        case .unavailable:
            // 业主第二原则：完全无网络/源不可达 → 允许先进入（稍后手动更新）。
            return .init(primary: .recheck, secondary: .continueWithout,
                         autoEnter: false, status: .unavailable)
        case .updating:
            // 理论不可达（进行中已在上面 activeProgress 分支拦截）；保守返回 busy。
            return .init(primary: .busy, secondary: nil, autoEnter: false, status: .checking)
        }
    }

    @MainActor
    private static func activeProgress(_ state: CatalogSlicesState)
        -> (CatalogSliceKind, MedicalCatalogDownloadProgress)? {
        for kind in CatalogSliceKind.allCases {
            if let progress = state.progress[kind] { return (kind, progress) }
        }
        return nil
    }

    /// 是否存在网络类失败（离线豁免判定；校验/限流不算）。
    @MainActor
    private static func hasNetworkFailure(_ state: CatalogSlicesState) -> Bool {
        CatalogSliceKind.allCases.contains {
            if case .networkUnavailable = state.remoteState($0) { return true }
            return false
        }
    }

    @MainActor
    private static func failureCount(_ state: CatalogSlicesState) -> Int {
        CatalogSliceKind.allCases.filter {
            switch state.remoteState($0) {
            case .rateLimited, .networkUnavailable, .verificationFailed: return true
            default: return false
            }
        }.count
    }

    @MainActor
    private static func sourceGapCount(_ state: CatalogSlicesState) -> Int {
        CatalogSliceKind.allCases.filter {
            switch state.remoteState($0) {
            case .sourceNotProvided, .removedFromSource: return true
            default: return false
            }
        }.count
    }

    @MainActor
    private static func appGatedCount(_ state: CatalogSlicesState) -> Int {
        CatalogSliceKind.allCases.filter {
            if case .appUpdateRequired = state.remoteState($0) { return true }
            return false
        }.count
    }
}
