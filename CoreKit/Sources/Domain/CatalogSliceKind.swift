import Foundation

/// 目录三切片身份（2026-10-28 切片-only 批次；自 Infrastructure 上移 Domain——
/// 检查结果/视图状态只消费 Domain 类型，Infrastructure 反向引用）。
///
/// 固定名资产（同名 stem，均挂在同一 Release 基址）：
/// - 清单 `<stem>.json`（签名信封，`vita-liber-app-slice-manifest/v1`）
/// - 包   `<stem>.bin`（ZIP 单成员 `<stem>.sqlite` + `zip+aes256gcm-v1` 信封）
public enum CatalogSliceKind: String, CaseIterable, Sendable {
    case drug
    case facility
    case reference

    public var stem: String { "app-catalog-" + rawValue }
    public var manifestAssetName: String { stem + ".json" }
    public var packageAssetName: String { stem + ".bin" }
    public var sqliteEntryName: String { stem + ".sqlite" }
}
