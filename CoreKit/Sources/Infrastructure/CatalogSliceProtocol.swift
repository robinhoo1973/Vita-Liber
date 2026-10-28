import Domain
import Foundation

/// 目录 v5 切片线协议（2026-10-28 业主裁决：v4 package 模式全面退役，切片-only；
/// 同日晚 P-批升四片——三目录片 + 医疗档案 profile 片）。
///
/// 固定名资产（同名 stem，均挂在同一 Release 基址）：
/// - 清单 `<stem>.json`（签名信封，`vita-liber-app-slice-manifest/v1`）
/// - 包   `<stem>.bin`（ZIP 单成员 `<stem>.sqlite` + `zip+aes256gcm-v1` 信封）
///
/// 发现面 = tag 页 SSR 资产清单（`CNBReleasePageInventoryParser`）——manifest.json
/// 指针文件与 `package-<ver>.bin` 旧名一律不再接受（业主裁决无兼容）。
/// 纯 Foundation、无平台守卫——Linux 可跑语法闸金样。
/// （`CatalogSliceKind` 已于 2026-10-28 上移 `Domain/CatalogSliceKind.swift`。）

public enum CatalogSliceProtocol {
    /// 清单载荷线格式（f7 publisher 与 App 两侧同源冻结）。
    public static let manifestFormat = "vita-liber-app-slice-manifest/v1"
    public static let manifestAssetKind = "app-catalog-slice"
    /// 切片**内容 schema** 版本（每片表集随 kind 在此版本冻结）。原名
    /// `supportedManifestSchemaVersion`——2026-10-28 二轮质询正名：清单格式在
    /// `format` 字符串，此字段描述的是包内 SQLite 的表布局契约。
    public static let supportedSliceSchemaVersion = 1
    /// 包内单成员容器格式（与 v4/ASR 同构，复用同一 opener）。
    public static let containerFormat = "zip+aes256gcm-v1"
    /// 信封/载荷尺寸上限（与既有 `MedicalCatalogReleaseProtocol.maxEnvelopeBytes/
    /// maxPayloadBytes` 同值；切片清单远小于此，沿用同一传输上限语义）。
    public static let maxEnvelopeBytes = 2 << 20
    public static let maxPayloadBytes = 1 << 20

    /// 四切片清单/包的固定名→kind（精确匹配；v4 旧名与未知资产不认——profile
    /// 经 per-kind stem 例外识别为 `app-profile-chronic_surgery.{json,bin}`）。
    public static func kind(forManifestAsset name: String) -> CatalogSliceKind? {
        CatalogSliceKind.allCases.first { $0.manifestAssetName == name }
    }

    public static func kind(forPackageAsset name: String) -> CatalogSliceKind? {
        CatalogSliceKind.allCases.first { $0.packageAssetName == name }
    }

    public static func manifestURL(_ kind: CatalogSliceKind) -> URL {
        URL(string: MedicalCatalogReleaseProtocol.releaseBaseURL + "/" + kind.manifestAssetName)!
    }

    public static func packageURL(_ kind: CatalogSliceKind) -> URL {
        URL(string: MedicalCatalogReleaseProtocol.releaseBaseURL + "/" + kind.packageAssetName)!
    }

    /// minApp 门（f7 信封字段 `minAppMarketingVersion`/`minAppBuild`）。
    /// 当前 App 的版本由调用方从 Bundle 读出后传入——本函数保持纯比较：
    /// build 为唯一硬门（CURRENT_PROJECT_VERSION 单调）；marketing 不参与比较
    /// （MARKETING_VERSION 由 CI 按最高 Release 派生，tag 回退会降，不可作单调门）。
    public static func supportsAppBuild(minAppBuild: Int64, currentBuild: Int64) -> Bool {
        minAppBuild <= currentBuild
    }
}
