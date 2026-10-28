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
    @MainActor
    static func descriptor(for state: CatalogSlicesState) -> CatalogSlicesPromptDescriptor {
        // 一次性完成事件：全部完成后自动进入（§5.12.4「成功才展示完成」）。
        // P-批：聚合完成态不带版本——四片版本空间不可比（profile 的 catalogVersion
        // 与三片目录版本不同轴），逐片版本仍由 SP-64 行内展示。
        if state.hasCompletedAnyUpdate, state.aggregate == .allCurrent {
            return .init(primary: .enter, secondary: nil, autoEnter: true,
                         status: .completed(version: nil))
        }
        if let (kind, progress) = activeProgress(state) {
            if case .activating = progress {
                return .init(primary: .busy, secondary: nil, autoEnter: false,
                             status: .phase(kind: kind, progress: progress))
            }
            return .init(primary: .enterKeepingUpdate, secondary: .cancelUpdateAndContinue,
                         autoEnter: false, status: .phase(kind: kind, progress: progress))
        }
        switch state.aggregate {
        case .notChecked:
            return .init(primary: .check, secondary: .continueWithout, autoEnter: false,
                         status: .idleNoLocal(installed: state.installedCount))
        case .checking:
            return .init(primary: .busy, secondary: .cancelCheckAndContinue,
                         autoEnter: false, status: .checking)
        case .updatesAvailable, .partialFailure:
            let status = CatalogSlicesPromptStatus.candidate(
                count: state.candidates.count, totalSize: state.totalDownloadBytes)
            if state.hasCandidate, state.canUpdate {
                return .init(primary: .install, secondary: .continueWithout,
                             autoEnter: false, status: status)
            }
            return .init(primary: .recheck, secondary: .continueWithout,
                         autoEnter: false, status: status)
        case .allCurrent:
            return .init(primary: .enter, secondary: nil, autoEnter: true, status: .upToDate)
        case .sourcePartial:
            return .init(primary: .enter, secondary: nil, autoEnter: true,
                         status: .sourcePartial(count: sourceGapCount(state)))
        case .allFailed:
            return .init(primary: .recheck, secondary: .continueWithout, autoEnter: false,
                         status: .failure(failed: failureCount(state),
                                          hasLocal: state.installedCount > 0))
        case .appUpdateRequired:
            // B7：minApp 未达只给 [进入 App]，绝不自动进入（避免强迫升级式循环）。
            return .init(primary: .enter, secondary: nil, autoEnter: false,
                         status: .appUpdateRequired(count: appGatedCount(state)))
        case .unavailable:
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
