import Foundation

/// 切片手动检查的 Domain 层值类型（2026-10-28 切片-only 批次）：
/// App 视图/状态只消费本层类型渲染检查态，不 import Infrastructure
/// （延续 `MedicalCatalogCheck.swift` 的同层纪律）。
///
/// 每片独立状态；聚合（已装 N/3 · 可更新 M 个等）由 App 状态层派生——
/// Domain 不锁死聚合语义，避免「部分可用」表达固化在数据层。

/// 已验签、`installable=true` 的切片远端候选摘要（视图展示所需字段）。
/// 完整候选（含签名摘要等安装字段）由 Infrastructure resolver 内部持有，
/// 仅在用户显式点「安装/更新」时进入安装链路。
public struct CatalogSliceCheckCandidate: Sendable, Equatable {
    public let kind: CatalogSliceKind
    public let catalogVersion: Int64
    /// 下载体积（签名 packageSize，供「约 %@」文案）。
    public let packageSize: Int64
    /// 安装后 SQLite 体积（磁盘预算用）。
    public let sqliteSize: Int64

    public init(kind: CatalogSliceKind, catalogVersion: Int64,
                packageSize: Int64, sqliteSize: Int64) {
        self.kind = kind
        self.catalogVersion = catalogVersion
        self.packageSize = packageSize
        self.sqliteSize = sqliteSize
    }
}

/// 单切片远端状态（ui-ux S0–S12 的远端子集；检查动作永远由用户显式触发）。
public enum CatalogSliceRemoteState: Sendable, Equatable {
    /// 未检查（页面进入默认态）。
    case idle
    /// 正在检查（该片 manifest 小响应，不下载包体）。
    case checking
    /// 与本机回执一致（catalogVersion + 内容身份）。
    case upToDate(catalogVersion: Int64?)
    /// 发现可安装/可更新候选。
    case updateAvailable(CatalogSliceCheckCandidate)
    /// 发布源未提供该片资产，且本机无副本。
    case sourceNotProvided
    /// 本机有副本而发布源已无该片资产（不删本地、不回落他片）。
    case removedFromSource(catalogVersion: Int64?)
    /// minAppBuild 高于当前 App（无重试、无外链；更新 App 后重新检查）。
    case appUpdateRequired(minAppBuild: Int64, minAppMarketingVersion: String)
    /// 受限流保护（403/429，含可重试时间；不自动重试）。
    case rateLimited(retryAfter: Date?)
    /// 网络不可用（无连接/5xx/传输失败）。
    case networkUnavailable
    /// 发布信息校验失败（manifest 畸形/验签不过/slice_meta 不符/同版异摘要——
    /// fail-closed，本机 last-good 不受影响）。
    case verificationFailed
    /// 本机未配置 pinned root（未 provisioning）——不联网。
    case unavailable
}

public struct CatalogSliceCheckResult: Sendable, Equatable {
    public let kind: CatalogSliceKind
    public let state: CatalogSliceRemoteState
    /// 本机回执版本（nil = 未安装或回执缺失；聚合「已装 N/3」与行文案用）。
    public let localCatalogVersion: Int64?

    public init(kind: CatalogSliceKind, state: CatalogSliceRemoteState,
                localCatalogVersion: Int64?) {
        self.kind = kind
        self.state = state
        self.localCatalogVersion = localCatalogVersion
    }
}

public struct CatalogSliceCheckOutcome: Sendable, Equatable {
    /// 覆盖 `CatalogSliceKind.allCases` 全量（当前四片）、顺序即行序（UI 稳定）。
    public let results: [CatalogSliceCheckResult]

    public init(results: [CatalogSliceCheckResult]) {
        self.results = results
    }

    public func state(for kind: CatalogSliceKind) -> CatalogSliceRemoteState {
        results.first { $0.kind == kind }?.state ?? .idle
    }

    public func localVersion(for kind: CatalogSliceKind) -> Int64? {
        results.first { $0.kind == kind }?.localCatalogVersion
    }

    /// 「全部安装/更新」的候选集（小片先行由安装层决定）。
    public var candidates: [CatalogSliceCheckCandidate] {
        results.compactMap { result in
            if case .updateAvailable(let candidate) = result.state { return candidate }
            return nil
        }
    }
}
