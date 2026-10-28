import Foundation

/// 启动自检的切片策略（U-批 2026-10-28；Domain 纯类型，Linux 可测）。
///
/// 三个集合语义严格分开，禁止互相替代：
/// - `startupRequiredKinds`：启动门/首启卡展开判据（缺失→提示安装；仍可
///   「暂不下载，直接进入」，不阻断 P0 离线可用）；
/// - `optionalKinds`：可选但常显（profile：健康史选择器增强；缺片不弹卡、
///   不阻塞进入，行/SP-64 恒显示）；
/// - `CatalogSliceKind.legacyReplacedKinds`：v4 残留清理判据（属残留清理，
///   与启动语义无关，**不得**复用）。
///
/// 分母（行 3/摘要显示 N/M）= `displayedSliceCount` = allCases.count（含
/// profile）；required 集**永不**参与除法/分母。业主 O4 改判（如四片必需）
/// 时只改本文件常量与 16 矩阵期望，卡/行代码不动。
public enum CatalogSliceBootPolicy {
    /// 启动必需集：缺失则首启卡展开（用户仍可显式「暂不下载，直接进入」）。
    public static let startupRequiredKinds: Set<CatalogSliceKind> = [
        .drug, .facility, .reference,
    ]

    /// 可选但常显集：不参与卡展开判据、不阻断进入。
    public static let optionalKinds: Set<CatalogSliceKind> = [.profile]

    /// 显示分母（自检行 3/聚合摘要的 N/M）。
    public static var displayedSliceCount: Int { CatalogSliceKind.allCases.count }

    /// 缺失的启动必需片（卡展开展示用：点名缺哪几类）。
    public static func missingRequired(installed: Set<CatalogSliceKind>) -> Set<CatalogSliceKind> {
        startupRequiredKinds.subtracting(installed)
    }

    /// 启动必需集是否全装（首启卡展开判据 = 取反）。
    public static func isStartupReady(installed: Set<CatalogSliceKind>) -> Bool {
        startupRequiredKinds.isSubset(of: installed)
    }
}
