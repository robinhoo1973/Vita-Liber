import Foundation

/// SP-64 医疗目录手动检查的 Domain 层值类型（2026-09-27）：
/// App 视图/状态只消费本层类型渲染检查态，不 import Infrastructure
/// （委员会 P3c 纪律延续——进度/错误已先行升层，见 `MedicalCatalogDownload.swift`）。

/// 通过 pinned root 验签、`installable=true` 的远端候选摘要（视图展示所需字段）。
/// 完整候选（含签名摘要等安装所需字段）由 Infrastructure resolver 内部持有，
/// 仅在用户显式点「更新」时进入安装链路。
public struct MedicalCatalogUpdateCandidate: Sendable, Equatable {
    public let catalogVersion: Int64
    public let dataVersion: String
    public let schemaVersion: Int
    public let packageSize: Int64
    public let expiresAt: Date

    public init(catalogVersion: Int64, dataVersion: String, schemaVersion: Int,
                packageSize: Int64, expiresAt: Date) {
        self.catalogVersion = catalogVersion
        self.dataVersion = dataVersion
        self.schemaVersion = schemaVersion
        self.packageSize = packageSize
        self.expiresAt = expiresAt
    }
}

/// 远端检查状态（ui-ux §5.12.4 八态清单 + 未检查）。检查动作永远由用户显式触发，
/// 本类型纯值无行为；「受限流保护」携带可重试时间、UI 不自动重试。
public enum MedicalCatalogRemoteState: Sendable, Equatable {
    /// 未检查（页面进入/启动默认态）。
    case idle
    /// 正在检查（inventory + 被选中的小 pointer，不下载包体）。
    case checking
    /// 已是最新完整目录（验签通过且 `(schemaVersion,dataVersion)` 与本机一致，
    /// 或远端目录版本不高于本机已验证地板）。
    case upToDate
    /// 发现可安装更新（验签通过、`installable=true`、数据与本机不同）。
    case updateAvailable(MedicalCatalogUpdateCandidate)
    /// 暂无新的完整可安装目录（Release 只有 progress pointer 或无 pointer——
    /// 绝不把 progress 呈现为更新）。
    case noInstallableAvailable
    /// 暂不可用（Release tag 404 尚未发布，或本机未配置 pinned root/信任锚）。
    case unavailable
    /// 受限流保护（403/429，含可重试时间；不自动重试）。
    case rateLimited(retryAfter: Date?)
    /// 信息校验失败（inventory/pointer 畸形、签名不通过、同版本异摘要等价冲突——
    /// fail-closed，本机 last-good 不受影响）。
    case verificationFailed
    /// 网络不可用（无连接/5xx/传输失败）。
    case networkUnavailable
}
