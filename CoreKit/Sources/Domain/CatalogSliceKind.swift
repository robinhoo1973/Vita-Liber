import Foundation

/// 目录切片身份（2026-10-28 切片-only 批次；同日晚 P-批升四片——
/// 三目录片 + 医疗档案 profile 片）。自 Infrastructure 上移 Domain——
/// 检查结果/视图状态只消费 Domain 类型，Infrastructure 反向引用。
///
/// 固定名资产（同名 stem，均挂在同一 Release 基址）：
/// - 清单 `<stem>.json`（签名信封，`vita-liber-app-slice-manifest/v1`）
/// - 包   `<stem>.bin`（ZIP 单成员 `<stem>.sqlite` + `zip+aes256gcm-v1` 信封）
///
/// **profile stem 例外**：`app-profile-chronic_surgery`（数据侧资产名已冻结，
/// 不走 `app-catalog-` 前缀；rawValue=`profile` 仍是 trust/receipt/journal 的
/// 身份键）。其余 kind 的 stem 前缀不变——三片既有落盘/floor 文件名零迁移。
public enum CatalogSliceKind: String, CaseIterable, Sendable {
    case drug
    case facility
    case reference
    /// 医疗档案目录（慢性病/手术/器官/科室；业主 2026-10-28 定为基本需求数据）。
    case profile

    public var stem: String {
        switch self {
        case .profile: return "app-profile-chronic_surgery"
        default: return "app-catalog-" + rawValue
        }
    }
    public var manifestAssetName: String { stem + ".json" }
    public var packageAssetName: String { stem + ".bin" }
    public var sqliteEntryName: String { stem + ".sqlite" }

    /// v4 单包被替换的 kind 集（v4 残留清理判据）。`profile` 不是 v4 替代物，
    /// 永不参与；加新片不得改变本集合（测试钉字面量）。
    public static let legacyReplacedKinds: [Self] = [.drug, .facility, .reference]
}
