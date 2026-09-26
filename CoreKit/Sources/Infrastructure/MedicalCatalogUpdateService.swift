import Foundation

/// 包解密 + 解包端口；identity 由 App 发布配置注入，更新服务本身不保存/生成私钥。
/// 实现须把解出的 SQLite 限制在 `maxSQLiteBytes` 内。
public protocol MedicalCatalogPackageOpening: Sendable {
    func open(packageURL: URL, sqliteURL: URL, maxSQLiteBytes: Int64) async throws
}

/// 按签名的 packageAssetName 取密文包；实现须把落盘字节限制在 `expectedSize` 内。
public protocol MedicalCatalogPackageFetching: Sendable {
    func fetch(assetName: String, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// 一次激活的全部文件位置：staging 与 active 同卷同目录。
public struct PendingActivation: Sendable, Equatable {
    public let candidate: VerifiedMedicalCatalogCandidate
    public let stagingURL: URL
    public let activeURL: URL
    public let lastGoodBackupURL: URL?
}

/// `begin` 只在全部校验门通过后、原子替换前调用；`complete` 在替换且复开通过后调用。
public protocol MedicalCatalogActivationJournaling: Sendable {
    func begin(_ pending: PendingActivation) throws
    func complete(_ pending: PendingActivation) throws
}

/// 资源预算（字节数上限，不是医疗数值）。
public struct MedicalCatalogUpdateLimits: Sendable, Equatable {
    public let maxPackageBytes: Int64
    public let maxSQLiteBytes: Int64

    public init(maxPackageBytes: Int64, maxSQLiteBytes: Int64) {
        self.maxPackageBytes = maxPackageBytes
        self.maxSQLiteBytes = maxSQLiteBytes
    }

    public static let standard = MedicalCatalogUpdateLimits(maxPackageBytes: 2_147_483_647,
                                                            maxSQLiteBytes: 4_294_967_296)
}

public enum MedicalCatalogUpdateProgress: Sendable, Equatable {
    case downloading(receivedBytes: Int64, totalBytes: Int64)
    case verifying
    case activating
}

public enum MedicalCatalogUpdateError: Error, Equatable {
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

/// 本机已激活目录库的身份（取自 `catalog_meta`）。
public struct MedicalCatalogInstalledVersion: Sendable, Equatable {
    public let schemaVersion: Int
    public let dataVersion: String

    public init(schemaVersion: Int, dataVersion: String) {
        self.schemaVersion = schemaVersion
        self.dataVersion = dataVersion
    }
}

/// 下载/校验/原子替换独立目录库；患者主库完全不参与。
/// 入口只接收 pinned verifier 放行的 `VerifiedMedicalCatalogCandidate`，
/// 安装链路（`update(candidate:opener:progress:)`）见 `MedicalCatalogUpdateService+Install.swift`。
public actor MedicalCatalogUpdateService {
    static let lastGoodSuffix = ".last-good"

    let destination: URL
    let fetcher: any MedicalCatalogPackageFetching
    let journal: (any MedicalCatalogActivationJournaling)?
    let limits: MedicalCatalogUpdateLimits
    let activeCheck: @Sendable (URL) throws -> Void
    /// 反回退 floor（tech-spec §5.53）：`update` 入口对已验签候选推进 floor——
    /// 更低 catalogVersion / 同版本异 digest 就地拒绝，不进入下载（2026-09-26
    /// 审查接线：此前 TrustStore 生产零构造、防回退判据悬空）。
    let trust: MedicalCatalogTrustStore?
    var isUpdating = false

    init(destination: URL, fetcher: any MedicalCatalogPackageFetching,
         journal: (any MedicalCatalogActivationJournaling)?, limits: MedicalCatalogUpdateLimits,
         activeCheck: @escaping @Sendable (URL) throws -> Void,
         trust: MedicalCatalogTrustStore? = nil) {
        self.destination = destination
        self.fetcher = fetcher
        self.journal = journal
        self.limits = limits
        self.activeCheck = activeCheck
        self.trust = trust
    }

    /// 数据未变（schema 与 dataVersion 同时相等）即无需下载包；metadata trust floor 仍可推进。
    public static func sameDataVersion(local: MedicalCatalogInstalledVersion,
                                       candidate: VerifiedMedicalCatalogCandidate) -> Bool {
        local.schemaVersion == candidate.schemaVersion && local.dataVersion == candidate.dataVersion
    }

    public static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        return size.int64Value
    }
}
