import Foundation

/// 医疗目录更新/下载的值类型（2026-09-27 委员会 P3c：自 Infrastructure 升层——
/// SP-64 视图渲染进度/错误时不再 import Infrastructure；typealias 兼容既有面）。

/// 更新进度（迁移自 Infrastructure；五阶段与 ui-ux §5.12.4 逐一对应——
/// 下载 / 包摘要校验 / 解密与解压 / 目录完整性校验 / 切换本机目录）。
public enum MedicalCatalogDownloadProgress: Sendable, Equatable {
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifyingPackage
    case decrypting
    case verifyingCatalog
    case activating
}

/// 更新错误词汇（迁移自 Infrastructure）。
public enum MedicalCatalogDownloadError: Error, Equatable {
    case catalogNotInstallable
    case updateInProgress
    case packageTooLarge
    case insufficientStorage
    case downloadFailed
    case redirectRejected
    case checksumMismatch
    case packageInvalid
    case catalogIntegrityFailed
    case activationFailed
    case cancelled
    /// 反回退 floor 拒绝（更低 catalogVersion，或同版本出现不同签名 digest——
    /// 发布方或传输层已不可信），不进入下载。
    case catalogRolledBack
}
