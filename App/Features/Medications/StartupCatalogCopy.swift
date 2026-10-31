import Foundation
import Domain

/// 启动目录卡文案纯映射（2026-10-31 owner rule：mock parity 必须是可执行契约）。
///
/// 从 `DatabaseInitializationView` 抽出：此前规则层（descriptor 动作）与渲染层
/// （标题/状态文案）各写一份，mock 1:1 只能靠人工对照，F5/F9 的文案漂移即由此而来。
/// 本类型只消费 `CatalogSlicesPromptStatus` + 动作枚举，输出 L10n 值；
/// 视图不再自行拼文案，测试逐状态断言（见 `StartupCatalogCopyParityTests`）。
enum StartupCatalogCopy {
    static func primaryTitle(_ action: MedicalCatalogPromptAction,
                             status: CatalogSlicesPromptStatus,
                             sizeText: String?) -> String {
        switch action {
        case .check: return L10n.resourceCatalogCheck
        case .recheck: return L10n.resourceCatalogRecheck
        case .install: return L10n.startupCatalogInstallFmt(sizeText ?? "")
        case .retryInstall: return L10n.startupCatalogRetryInstall
        case .enter: return L10n.startupCatalogEnter
        case .enterKeepingUpdate: return L10n.startupCatalogUseWhileUpdating
        case .continueWithout: return L10n.startupCatalogContinue
        case .cancelCheckAndContinue: return L10n.startupCatalogCancelCheckContinue
        case .cancelUpdateAndContinue: return L10n.startupCatalogCancelUpdateContinue
        case .busy:
            // mock primaryLabel：phase 下载/校验/解密=「正在下载…」；
            // activating=「正在完成安装，请勿关闭」；仅检查态才是「正在检查…」。
            if case .phase(_, let progress) = status {
                if case .activating = progress { return L10n.startupCatalogActivating }
                return L10n.startupCatalogDownloading
            }
            return L10n.resourceCatalogChecking
        case .none: return L10n.startupCatalogUpgradeUnavailable
        }
    }

    static func secondaryTitle(_ action: MedicalCatalogPromptAction,
                               networkBlocked: Bool = false) -> String {
        switch action {
        case .cancelCheckAndContinue: return L10n.startupCatalogCancelCheckContinue
        case .cancelUpdateAndContinue: return L10n.startupCatalogCancelUpdateContinue
        case .continueWithout:
            // 强制卡离线/仅 Wi-Fi 拦截出口用「先进入」；常规跳过仍为「暂不下载，继续」。
            return networkBlocked ? L10n.startupCatalogEnterFirst : L10n.startupCatalogContinue
        default: return L10n.startupCatalogContinue
        }
    }

    /// 状态短语（切片聚合；未知进行中片显示其名 + 阶段）。
    static func statusText(_ status: CatalogSlicesPromptStatus, mandatory: Bool) -> String {
        switch status {
        case .idleNoLocal(let installed):
            if installed > 0 {
                return L10n.startupCatalogStatusIdleLocalFmt(
                    installed, CatalogSliceKind.allCases.count)
            }
            // 强制首启时状态短语与标题「（必需）」同口径。
            return mandatory
                ? L10n.startupCatalogStatusIdleNoLocalRequired
                : L10n.startupCatalogStatusIdleNoLocal
        case .checking:
            return L10n.resourceCatalogSlicesChecking
        case .candidate(_, let totalSize):
            // mock 1:1：「有新版本，约 %@。」
            return L10n.startupCatalogCandidateFmt(
                ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
        case .phase(let kind, let progress):
            return kindName(kind) + " · " + MedicalCatalogPromptCopy.phaseText(progress)
        case .completed(let version):
            return version.map { L10n.startupCatalogCompletedFmt($0) }
                ?? L10n.startupCatalogCompleted
        case .upToDate:
            return L10n.resourceCatalogSlicesAllCurrent
        case .sourcePartial(let count):
            return L10n.resourceCatalogSlicesSourcePartialFmt(count)
        case .failure(let failed, let hasLocal):
            return hasLocal
                ? L10n.resourceCatalogSlicesPartialFailureFmt(failed)
                : L10n.resourceCatalogUpdateFailedNoLocal
        case .appUpdateRequired(let count):
            return L10n.resourceCatalogSlicesAppUpdateRequiredFmt(count)
        case .unavailable:
            return L10n.resourceCatalogUnavailable
        }
    }

    static func kindName(_ kind: CatalogSliceKind) -> String {
        switch kind {
        case .drug: return L10n.resourceCatalogSliceDrugName
        case .facility: return L10n.resourceCatalogSliceFacilityName
        case .reference: return L10n.resourceCatalogSliceReferenceName
        case .profile: return L10n.resourceCatalogSliceProfileName
        }
    }
}
