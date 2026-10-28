import Domain
import Foundation

/// 切片级 trust floor（抗回滚 + 反等价），身份 = **内容**（`sqliteSha256`）。
///
/// 每片一文件：`…/catalog/v5/app-catalog-<kind>-trust.json`。逐文件隔离替代
/// 「单文件加 kind 命名空间」——后者要升 floor schema 并迁移 v4 文件，风险更大；
/// 而 v4 的 `medical-catalog-trust.json`（floor 值 1793…）绝不能被切片读到，
/// 否则会把 catalogVersion=2 永久判为回滚（2026-10-28 二轮质询裁决 7）。
///
/// 语义（复用 `MedicalCatalogTrustStore` 的读-验-写锁与原子落盘）：
/// - 同版同 `sqliteSha256`：幂等空操作——f7 仅重签 minApp*/rootVersion 时
///   payloadDigest 变了但内容身份不变，重签是 no-op，不触发 equivocation。
/// - 同版异 `sqliteSha256`：`Failure.equivocation`（同版本两份不同内容=发布方不可信）。
/// - 低 `catalogVersion`：`Failure.rollback`。
/// - 只在 pinned root 验签 + 元数据全过后由 resolver 推进；安装失败绝不回退。
public struct CatalogSliceTrust: Sendable {
    public static let fileNamePrefix = "app-catalog-"
    public static let fileNameSuffix = "-trust.json"

    /// 生产文件名注入点（L0 第 22 节断言用）。
    public static func fileURL(kind: CatalogSliceKind, directory: URL) -> URL {
        directory.appendingPathComponent(fileNamePrefix + kind.rawValue + fileNameSuffix)
    }

    private let stores: [CatalogSliceKind: MedicalCatalogTrustStore]

    /// `directory` = 切片支持目录（`AppSupport/VitaLiber/catalog/v5`）。
    public init(directory: URL) {
        var stores: [CatalogSliceKind: MedicalCatalogTrustStore] = [:]
        for kind in CatalogSliceKind.allCases {
            stores[kind] = MedicalCatalogTrustStore(fileURL: Self.fileURL(kind: kind, directory: directory))
        }
        self.stores = stores
    }

    public func observedFloor(_ kind: CatalogSliceKind) -> MedicalCatalogTrustStore.ObservedFloor? {
        stores[kind]?.observedFloor
    }

    /// 内容身份推进入口（见类型注释语义）。`installable` 恒真由
    /// `VerifiedCatalogSliceCandidate` 的密封构造保证（解码层拒非 installable）。
    public func accept(_ candidate: VerifiedCatalogSliceCandidate) throws {
        guard let store = stores[candidate.kind] else {
            throw MedicalCatalogTrustStore.Failure.invalidState
        }
        try store.acceptVerifiedInstallable(catalogVersion: candidate.catalogVersion,
                                            payloadDigest: candidate.sqliteSHA256)
    }
}
