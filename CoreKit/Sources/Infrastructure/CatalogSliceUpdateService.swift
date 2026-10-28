#if os(iOS) || os(macOS)
// linux-blind: probe/GRDB 与传输语义只在 Apple 平台验证——Linux 型检编译空单元
import Domain
import Foundation

/// 三切片安装服务（2026-10-28 切片-only 批次）：每片独立 staging/last-good/journal/回执。
///
/// 入口只接收已验签密封候选（`VerifiedCatalogSliceCandidate`：pinned root 2-of-2 验签
/// + 22 键解码 + rootVersion 界限由 resolver 完成）。本服务负责：
/// 下载 → 包 SHA → 解密解包（成员名=载荷绑定）→ SQLite SHA → 切片契约探测
/// （表集/slice_meta/COUNT，App 注入）→ 原子替换 → 复开 → journal 收尾 → 回执。
///
/// 纪律（与 v4 `MedicalCatalogUpdateService` 同规）：
/// - 自 `journal.begin` 起不再响应取消：要么完成，要么恢复 last-good；
/// - 回执是派生数据：写失败不回滚已成功的激活（journal Record 可重建）；
/// - minApp 双门：resolver 已拦一次，安装前在此再验（定稿：resolver+installer 双门）；
/// - 任一片失败只影响该片（目录/备份/journal/回执全部按片命名）。
public actor CatalogSliceUpdateService: CatalogSliceInstalling {
    public typealias Progress = @Sendable (MedicalCatalogUpdateProgress) -> Void

    private let directory: URL
    private let fetcher: any MedicalCatalogPackageFetching
    private let opener: any MedicalCatalogPackageOpening
    /// 每片一 journal 文件（隔离身份/生命周期）；安装时按 candidate.kind 取实例。
    private let journalFor: @Sendable (CatalogSliceKind) -> CatalogSliceActivationJournal
    private let limits: MedicalCatalogUpdateLimits
    private let currentBuild: @Sendable () -> Int64
    /// 切片契约探测（App 注入 `CatalogSliceProbe.inspect` + `verifyCounts: true`）。
    private let verifySQLite: @Sendable (_ path: URL, _ candidate: VerifiedCatalogSliceCandidate) throws -> Void
    private let onActivated: (@Sendable (CatalogSliceKind) -> Void)?
    private var isUpdating = false

    /// `fetcher` 缺省由本文件构造「切片名门」版传输：L0 家族 Q 规定 App 层不得
    /// 引用传输实现符号（进度/错误/形态经 Domain 值类型，实现留 Infrastructure）——
    /// 资产名文法知识属于本层，不属于组合根。
    public init(directory: URL,
                fetcher: (any MedicalCatalogPackageFetching)? = nil,
                opener: any MedicalCatalogPackageOpening,
                journalFor: @escaping @Sendable (CatalogSliceKind) -> CatalogSliceActivationJournal,
                limits: MedicalCatalogUpdateLimits = .standard,
                currentBuild: @escaping @Sendable () -> Int64,
                verifySQLite: @escaping @Sendable (URL, VerifiedCatalogSliceCandidate) throws -> Void,
                onActivated: (@Sendable (CatalogSliceKind) -> Void)? = nil) {
        self.directory = directory
        self.fetcher = fetcher ?? URLSessionMedicalCatalogPackageFetcher(urlResolver: { name in
            CatalogSliceProtocol.kind(forPackageAsset: name).map(CatalogSliceProtocol.packageURL)
        })
        self.opener = opener
        self.journalFor = journalFor
        self.limits = limits
        self.currentBuild = currentBuild
        self.verifySQLite = verifySQLite
        self.onActivated = onActivated
    }

    /// 切片 active 落点：`…/catalog/v5/app-catalog-<kind>.sqlite`（固定名，发布单元=消费单元）。
    public static func activeURL(_ kind: CatalogSliceKind, directory: URL) -> URL {
        directory.appendingPathComponent(kind.stem + ".sqlite")
    }

    public func update(_ candidate: VerifiedCatalogSliceCandidate,
                       progress: @escaping Progress) async throws {
        guard !isUpdating else { throw MedicalCatalogUpdateError.updateInProgress }
        isUpdating = true
        defer { isUpdating = false }
        guard candidate.isSupported(byAppBuild: currentBuild()) else {
            throw MedicalCatalogUpdateError.catalogNotInstallable
        }
        guard candidate.packageSize <= limits.maxPackageBytes else {
            throw MedicalCatalogUpdateError.packageTooLarge
        }
        let active = Self.activeURL(candidate.kind, directory: directory)
        let identifier = UUID().uuidString
        let package = directory.appendingPathComponent(candidate.kind.stem + "-package-\(identifier).bin")
        let staging = directory.appendingPathComponent(candidate.kind.stem + "-staging-\(identifier).sqlite")
        defer {
            try? FileManager.default.removeItem(at: package) // try?-ok: 中间件清理
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging) // try?-ok: 未激活 staging 清理，不触碰 active
            }
        }
        try Self.requireFreeSpace(candidate.packageSize + candidate.sqliteSize, at: directory)

        progress(.downloading(receivedBytes: 0, totalBytes: candidate.packageSize))
        do {
            try await fetcher.fetch(assetName: candidate.assetName,
                                    expectedSize: candidate.packageSize,
                                    to: package) { received in
                progress(.downloading(receivedBytes: received, totalBytes: candidate.packageSize))
            }
        } catch {
            throw Self.mapped(error, fallback: .downloadFailed)
        }
        try Self.checkCancellation()

        progress(.verifyingPackage)
        guard try Self.size(of: package, failing: .downloadFailed) == candidate.packageSize,
              try await Self.sha256(of: package) == candidate.packageSHA256 else {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
        try Self.checkCancellation()

        progress(.decrypting)
        do {
            // identity = 验签候选的 sqliteSha256；entryName = 载荷绑定成员名。
            try await opener.open(packageURL: package, sqliteURL: staging,
                                  identity: candidate.sqliteSHA256,
                                  entryName: candidate.sqliteEntryName,
                                  maxSQLiteBytes: limits.maxSQLiteBytes)
        } catch {
            throw Self.mapped(error, fallback: .packageInvalid)
        }
        try Self.checkCancellation()
        let sqliteSize = try Self.size(of: staging, failing: .packageInvalid)
        guard sqliteSize > 0, sqliteSize == candidate.sqliteSize,
              sqliteSize <= limits.maxSQLiteBytes else {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        guard try await Self.sha256(of: staging) == candidate.sqliteSHA256 else {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
        progress(.verifyingCatalog)
        do {
            try verifySQLite(staging, candidate)
        } catch {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        try Self.checkCancellation()

        progress(.activating)
        try await activate(staging: staging, candidate: candidate, active: active)
    }

    /// 自 journal.begin 起不再响应取消：替换 + 复开要么完成，要么恢复 last-good。
    private func activate(staging: URL, candidate: VerifiedCatalogSliceCandidate,
                          active: URL) async throws {
        let fileManager = FileManager.default
        let hasActive = fileManager.fileExists(atPath: active.path)
        let backup = hasActive
            ? active.deletingLastPathComponent()
                .appendingPathComponent(active.lastPathComponent + ".last-good")
            : nil
        do {
            if let backup {
                if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
                do {
                    try fileManager.linkItem(at: active, to: backup)
                } catch {
                    try fileManager.copyItem(at: active, to: backup)
                }
            }
        } catch {
            throw MedicalCatalogUpdateError.activationFailed
        }
        let pending = CatalogSliceActivationJournal.Pending(
            kind: candidate.kind, catalogVersion: candidate.catalogVersion,
            rootVersion: candidate.rootVersion, sqliteSHA256: candidate.sqliteSHA256,
            signedPayloadDigest: candidate.signedPayloadDigest,
            stagingURL: staging, activeURL: active, lastGoodBackupURL: backup)
        let journal = journalFor(candidate.kind)
        do {
            try journal.begin(pending)
        } catch {
            throw MedicalCatalogUpdateError.activationFailed
        }
        guard Self.atomicRename(staging, to: active) else {
            throw MedicalCatalogUpdateError.activationFailed
        }
        do {
            // 复验最终 inode（不信任 staging 路径上的旧结论）。
            try verifySQLite(active, candidate)
            try journal.complete(pending)
        } catch {
            Self.restoreLastGood(backup, active: active)
            throw MedicalCatalogUpdateError.activationFailed
        }
        // 回执为派生数据：写失败只记诊断（journal Record 可重建），不影响激活。
        _ = CatalogSliceReceipt.write(
            CatalogSliceReceipt(candidate: candidate, installedAt: Date()), directory: directory)
        onActivated?(candidate.kind)
    }

    // MARK: - Helpers

    /// 复开失败时尽力回滚；回滚本身失败时 journal 停在 begin，交由启动恢复处理。
    private static func restoreLastGood(_ backup: URL?, active: URL) {
        if let backup {
            _ = atomicRename(backup, to: active)
            return
        }
        try? FileManager.default.removeItem(at: active) // try?-ok: 首次安装失败回未安装态；失败由 journal 恢复兜底
    }

    private static func atomicRename(_ source: URL, to target: URL) -> Bool {
        rename(source.path, target.path) == 0
    }

    private static func size(of url: URL, failing failure: MedicalCatalogUpdateError) throws -> Int64 {
        do {
            return try CatalogPackageFiles.size(of: url)
        } catch {
            throw failure
        }
    }

    private static func sha256(of url: URL) async throws -> String {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try StreamingFileHasher.sha256(of: url)
            }.value
        } catch {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
    }

    private static func requireFreeSpace(_ bytes: Int64, at url: URL) throws {
        let free: Int64?
        do {
            free = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        } catch {
            return
        }
        if let free, free < bytes { throw MedicalCatalogUpdateError.insufficientStorage }
    }

    private static func mapped(_ error: Error, fallback: MedicalCatalogUpdateError) -> MedicalCatalogUpdateError {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        return error as? MedicalCatalogUpdateError ?? fallback
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw MedicalCatalogUpdateError.cancelled }
    }
}
#endif
