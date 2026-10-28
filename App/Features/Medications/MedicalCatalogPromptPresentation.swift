import Foundation
import Domain

/// 医疗目录提示的唯一状态→动作映射（2026-10-27 两席评审方案 B）。
///
/// 纯值：视图只渲染 descriptor；启动卡、设置页、更新中心共用文案例外，
/// 状态机仍唯一在 `MedicalCatalogState`。两次显式点击语义不在本层放宽：
/// `.check` 只取元数据，`.install/retryInstall` 才下载。
enum MedicalCatalogPromptAction: Equatable {
    case check
    case recheck
    case install
    case retryInstall
    case enter
    case enterKeepingUpdate
    case continueWithout
    case cancelCheckAndContinue
    case cancelUpdateAndContinue
    case busy
    case none
}

enum MedicalCatalogPromptStatus: Equatable {
    case idleNoLocal
    case idleLocal
    case checking
    case candidate(MedicalCatalogUpdateCandidate)
    case phase(MedicalCatalogDownloadProgress)
    case failure(MedicalCatalogDownloadError, hasLocal: Bool)
    case completed(Int64?)
    case upToDate
    case noInstallable
    case remote(MedicalCatalogRemoteState)
}

struct MedicalCatalogPromptDescriptor: Equatable {
    let primary: MedicalCatalogPromptAction
    let secondary: MedicalCatalogPromptAction?
    let autoEnter: Bool
    let status: MedicalCatalogPromptStatus
}

/// 快照输入（视图在 `WithPerceptionTracking` 内构造；纯函数便于单测）。
struct MedicalCatalogPromptInput: Equatable {
    let remoteState: MedicalCatalogRemoteState
    let progress: MedicalCatalogDownloadProgress?
    let error: MedicalCatalogDownloadError?
    let completedCatalogVersion: Int64?
    let completedDataVersion: String?
    let canUpdate: Bool
    let canCancelUpdate: Bool
    let hasLocalCatalog: Bool

    init(remoteState: MedicalCatalogRemoteState,
         progress: MedicalCatalogDownloadProgress?,
         error: MedicalCatalogDownloadError?,
         completedCatalogVersion: Int64?,
         completedDataVersion: String?,
         canUpdate: Bool,
         canCancelUpdate: Bool,
         hasLocalCatalog: Bool) {
        self.remoteState = remoteState
        self.progress = progress
        self.error = error
        self.completedCatalogVersion = completedCatalogVersion
        self.completedDataVersion = completedDataVersion
        self.canUpdate = canUpdate
        self.canCancelUpdate = canCancelUpdate
        self.hasLocalCatalog = hasLocalCatalog
    }

}

enum MedicalCatalogPromptPresentation {
    static func descriptor(_ input: MedicalCatalogPromptInput) -> MedicalCatalogPromptDescriptor {
        if input.completedDataVersion != nil || input.completedCatalogVersion != nil {
            return .init(primary: .enter, secondary: nil, autoEnter: true,
                         status: .completed(input.completedCatalogVersion))
        }
        if let progress = input.progress {
            if case .activating = progress {
                // 切换阶段不可取消（journal 契约）：只显示「请勿关闭」。
                return .init(primary: .busy, secondary: nil, autoEnter: false,
                             status: .phase(progress))
            }
            return .init(primary: .enterKeepingUpdate,
                         secondary: .cancelUpdateAndContinue,
                         autoEnter: false, status: .phase(progress))
        }
        switch input.remoteState {
        case .checking:
            return .init(primary: .busy, secondary: .cancelCheckAndContinue,
                         autoEnter: false, status: .checking)
        case .updateAvailable(let candidate):
            guard input.canUpdate else {
                return .init(primary: .none, secondary: .continueWithout,
                             autoEnter: false, status: .candidate(candidate))
            }
            if let error = input.error {
                return .init(primary: error.retryIsMeaningful ? .retryInstall : .recheck,
                             secondary: .continueWithout, autoEnter: false,
                             status: .failure(error, hasLocal: input.hasLocalCatalog))
            }
            return .init(primary: .install, secondary: .continueWithout,
                         autoEnter: false, status: .candidate(candidate))
        case .idle:
            return .init(primary: .check, secondary: .continueWithout, autoEnter: false,
                         status: input.hasLocalCatalog ? .idleLocal : .idleNoLocal)
        case .upToDate:
            return .init(primary: .enter, secondary: nil, autoEnter: true, status: .upToDate)
        case .noInstallableAvailable:
            return .init(primary: .enter, secondary: nil, autoEnter: true,
                         status: .noInstallable)
        case .unavailable, .networkUnavailable, .verificationFailed, .rateLimited:
            return .init(primary: .recheck, secondary: .continueWithout, autoEnter: false,
                         status: .remote(input.remoteState))
        }
    }
}

extension MedicalCatalogDownloadError {
    /// 第二次显式动作是否应为「重试下载」；其余错误只能重新检查/等待配置。
    var retryIsMeaningful: Bool {
        switch self {
        case .downloadFailed, .insufficientStorage, .cancelled, .redirectRejected:
            return true
        case .catalogNotInstallable, .catalogNotConfigured, .catalogRolledBack,
             .checksumMismatch, .packageInvalid, .catalogIntegrityFailed,
             .activationFailed, .updateInProgress, .packageTooLarge:
            return false
        }
    }
}

/// 文案与格式的唯一出口（启动卡/设置页/更新中心共用；测试只断言 descriptor）。
enum MedicalCatalogPromptCopy {
    static func statusText(_ status: MedicalCatalogPromptStatus, candidateSize: String?) -> String {
        switch status {
        case .idleNoLocal: return L10n.startupCatalogStatusIdleNoLocal
        case .idleLocal: return L10n.startupCatalogStatusIdleLocal
        case .checking: return L10n.resourceCatalogChecking
        case .candidate:
            return L10n.startupCatalogCandidateFmt(candidateSize ?? "")
        case .phase(let progress): return phaseText(progress)
        case .failure(let error, let hasLocal): return errorText(error, hasLocal: hasLocal)
        case .completed(let version):
            return version.map { L10n.startupCatalogCompletedFmt($0) }
                ?? L10n.startupCatalogCompleted
        case .upToDate: return L10n.resourceCatalogUpToDate
        case .noInstallable: return L10n.resourceCatalogNoInstallable
        case .remote(let state): return remoteText(state)
        }
    }

    static func primaryTitle(_ descriptor: MedicalCatalogPromptDescriptor,
                             candidateSize: String?) -> String {
        switch descriptor.primary {
        case .check: return L10n.resourceCatalogCheck
        case .recheck: return L10n.resourceCatalogRecheck
        case .install: return L10n.startupCatalogInstallFmt(candidateSize ?? "")
        case .retryInstall: return L10n.startupCatalogRetryInstall
        case .enter: return L10n.startupCatalogEnter
        case .enterKeepingUpdate: return L10n.startupCatalogUseWhileUpdating
        case .continueWithout: return L10n.startupCatalogContinue
        case .cancelCheckAndContinue: return L10n.startupCatalogCancelCheckContinue
        case .cancelUpdateAndContinue: return L10n.startupCatalogCancelUpdateContinue
        case .busy:
            if case .phase(.activating) = descriptor.status {
                return L10n.startupCatalogActivating
            }
            return L10n.resourceCatalogChecking
        case .none: return L10n.startupCatalogUpgradeUnavailable
        }
    }

    static func secondaryTitle(_ action: MedicalCatalogPromptAction) -> String {
        switch action {
        case .cancelCheckAndContinue: return L10n.startupCatalogCancelCheckContinue
        case .cancelUpdateAndContinue: return L10n.startupCatalogCancelUpdateContinue
        default: return L10n.startupCatalogContinue
        }
    }

    static func phaseText(_ progress: MedicalCatalogDownloadProgress) -> String {
        switch progress {
        case .downloading: return L10n.resourceCatalogPhaseDownloading
        case .verifyingPackage: return L10n.resourceCatalogPhaseVerifyingPackage
        case .decrypting: return L10n.resourceCatalogPhaseDecrypting
        case .verifyingCatalog: return L10n.resourceCatalogPhaseVerifyingCatalog
        case .activating: return L10n.resourceCatalogPhaseActivating
        }
    }

    static func errorText(_ error: MedicalCatalogDownloadError, hasLocal: Bool) -> String {
        if !hasLocal {
            switch error {
            case .cancelled, .downloadFailed, .checksumMismatch, .packageInvalid,
                 .catalogIntegrityFailed, .activationFailed:
                return L10n.resourceCatalogUpdateFailedNoLocal
            default: break
            }
        }
        switch error {
        case .cancelled: return L10n.resourceCatalogUpdateCancelled
        case .insufficientStorage: return L10n.resourceCatalogFailedStorage
        case .catalogRolledBack: return L10n.resourceCatalogFailedRolledBack
        case .catalogNotConfigured: return L10n.resourceCatalogNotConfigured
        case .catalogNotInstallable: return L10n.resourceCatalogNotInstallable
        default: return L10n.resourceCatalogUpdateFailed
        }
    }

    static func remoteText(_ state: MedicalCatalogRemoteState) -> String {
        switch state {
        case .idle: return L10n.resourceCatalogNotAvailable
        case .checking: return L10n.resourceCatalogChecking
        case .upToDate: return L10n.resourceCatalogUpToDate
        case .updateAvailable(let candidate):
            return L10n.resourceCatalogUpdateAvailableFmt(candidate.catalogVersion)
        case .noInstallableAvailable: return L10n.resourceCatalogNoInstallable
        case .unavailable: return L10n.resourceCatalogUnavailable
        case .rateLimited: return L10n.resourceCatalogRateLimited
        case .verificationFailed: return L10n.resourceCatalogVerificationFailed
        case .networkUnavailable: return L10n.resourceCatalogNetworkUnavailable
        }
    }

    /// 候选大小（ByteCountFormatter 系统本地化；不写死单位）。
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
