import Foundation
import Domain

/// 首启卡动作词汇（2026-10-27 两席评审方案 B；U-批 B7-optional 2026-10-28 精简）。
///
/// v4 单目录 descriptor 族（Status/Descriptor/Input/Presentation/`retryIsMeaningful`）
/// 随三切片-only 全面退役已删除；**动作词表保留**——切片 descriptor
/// （`CatalogSlicesPromptPresentation`）复用同一词表。两次显式点击语义不在本层
/// 放宽：`.check` 只取元数据，`.install/retryInstall` 才下载。
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

/// 文案与格式出口（启动卡/设置页/更新中心共用；切片化后仅保留三助手——
/// 旧 statusText/primaryTitle/secondaryTitle/remoteText 随 v4 descriptor 族删除）。
enum MedicalCatalogPromptCopy {
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

    /// 候选大小（ByteCountFormatter 系统本地化；不写死单位）。
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
