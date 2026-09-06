import Foundation
import Domain

/// F8.4 / tech-spec §5.10 敏感媒体资产仓端口（BR-007/008）。
///
/// - 照片写入即敏感：原始图 + 强制模糊缩略图双产物落敏感目录
///   （`Documents/MedicalNotes/sensitive/{memberId}/`，文件保护 `.complete`）；
/// - 资产行写入 `asset` 表（kind = photo / blur），观察行以 media_asset_ids 引用；
/// - 读取只暴露模糊缩略图数据（路径由 memberId + assetId 确定性派生，无表查询）——
///   原图路径不流入视图层（§5.10：锁定 UI 永远只读 blur 版，暴露面最小化）。
public protocol SensitiveAssetStoring: Sendable {
    /// 保存一张照片（JPEG Data）→ 返回资产 id。写入失败整体回滚（不产生半成品文件）。
    func savePhoto(_ data: Data, memberId: UUID) async throws -> UUID
    /// 读取该资产的模糊缩略图数据（列表/锁定态渲染专用）；无则返回 nil。
    func blurData(for assetId: UUID, memberId: UUID) async throws -> Data?
    /// 读取原图数据（评审修正 U3）：详情页解锁查看的读取端口——此前协议无
    /// 此能力，原图字节在 UI 层完全不可达（SensitiveMediaOriginalView 零调用
    /// 方，§5.7.1「点击解锁查看原图」整链缺失）。只在显式解锁动作后调用。
    func originalData(for assetId: UUID, memberId: UUID) async throws -> Data?
    /// 回滚删除一张已保存照片（文件 + 资产行）——观察行写入失败时补偿用。
    func removePhoto(_ assetId: UUID, memberId: UUID) async
    /// 启动对账：清除未被任何观察引用的孤儿照片（文件 + 资产行）——
    /// 崩溃/断电窗口或历史失败写入的残留，防止敏感文件永久滞留。
    func reconcileUnreferenced(validAssetIds: Set<String>) async
}
