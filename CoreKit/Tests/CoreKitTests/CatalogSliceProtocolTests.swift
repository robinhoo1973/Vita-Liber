import Domain
import Foundation
import Testing
@testable import Infrastructure

/// 切片线协议语法闸金样（2026-10-28 切片-only 批次）。
/// 纯 Foundation，Linux 也真跑。
@Suite("SU-M2-SLICE · 切片协议语法闸")
struct CatalogSliceProtocolTests {
    @Test("四切片固定名：stem/manifest/package/entry 一一对应；profile 走 stem 例外")
    func fixedNames() {
        #expect(CatalogSliceKind.drug.stem == "app-catalog-drug")
        #expect(CatalogSliceKind.drug.manifestAssetName == "app-catalog-drug.json")
        #expect(CatalogSliceKind.drug.packageAssetName == "app-catalog-drug.bin")
        #expect(CatalogSliceKind.drug.sqliteEntryName == "app-catalog-drug.sqlite")
        // profile：数据侧资产名已冻结，不走 app-catalog- 前缀（rawValue 仍是身份键）。
        #expect(CatalogSliceKind.profile.stem == "app-profile-chronic_surgery")
        #expect(CatalogSliceKind.profile.manifestAssetName == "app-profile-chronic_surgery.json")
        #expect(CatalogSliceKind.profile.packageAssetName == "app-profile-chronic_surgery.bin")
        #expect(CatalogSliceKind.profile.sqliteEntryName == "app-profile-chronic_surgery.sqlite")
        #expect(CatalogSliceKind.allCases.map(\.rawValue)
                == ["drug", "facility", "reference", "profile"])
        // v4 替代集钉字面量：加新片不得改变（profile 不是 v4 替代物）。
        #expect(CatalogSliceKind.legacyReplacedKinds == [.drug, .facility, .reference])
    }

    @Test("资产名→kind 精确匹配；profile 合法；v4 旧名/错名/噪声一律不认")
    func grammarRejectsLegacyAndNoise() {
        #expect(CatalogSliceProtocol.kind(forManifestAsset: "app-catalog-drug.json") == .drug)
        #expect(CatalogSliceProtocol.kind(forPackageAsset: "app-catalog-reference.bin") == .reference)
        // profile 第四切片：stem 例外后的冻结资产名为唯一合法形。
        #expect(CatalogSliceProtocol.kind(forManifestAsset: "app-profile-chronic_surgery.json") == .profile)
        #expect(CatalogSliceProtocol.kind(forPackageAsset: "app-profile-chronic_surgery.bin") == .profile)
        for legacy in ["manifest.json", "overview.json", "package-1793039624.bin",
                       "package-1.bin", "app-catalog-medical.bin",
                       // profile 的错名形（按 rawValue 拼出的 app-catalog-profile）永不接受
                       "app-catalog-profile.bin", "app-catalog-profile.json",
                       "app-catalog-drug.bin.bak", "App-Catalog-drug.bin",
                       "app-catalog-drug.bin/../x"] {
            #expect(CatalogSliceProtocol.kind(forPackageAsset: legacy) == nil,
                    "不应接受：\(legacy)")
            #expect(CatalogSliceProtocol.kind(forManifestAsset: legacy) == nil,
                    "不应接受：\(legacy)")
        }
    }

    @Test("URL 只由固定名拼出，主机与基址同源")
    func urlsAreDeterministic() {
        #expect(CatalogSliceProtocol.manifestURL(.facility).absoluteString
                == MedicalCatalogReleaseProtocol.releaseBaseURL + "/app-catalog-facility.json")
        #expect(CatalogSliceProtocol.packageURL(.reference).absoluteString
                == MedicalCatalogReleaseProtocol.releaseBaseURL + "/app-catalog-reference.bin")
        #expect(CatalogSliceProtocol.manifestURL(.drug).host == "cnb.cool")
    }

    @Test("minApp 门：build 单调比较")
    func minAppGate() {
        #expect(CatalogSliceProtocol.supportsAppBuild(minAppBuild: 1, currentBuild: 1))
        #expect(CatalogSliceProtocol.supportsAppBuild(minAppBuild: 185, currentBuild: 190))
        #expect(!CatalogSliceProtocol.supportsAppBuild(minAppBuild: 191, currentBuild: 190))
    }

    @Test("线常量冻结值")
    func wireConstants() {
        #expect(CatalogSliceProtocol.manifestFormat == "vita-liber-app-slice-manifest/v1")
        #expect(CatalogSliceProtocol.manifestAssetKind == "app-catalog-slice")
        #expect(CatalogSliceProtocol.containerFormat == "zip+aes256gcm-v1")
        #expect(CatalogSliceProtocol.supportedSliceSchemaVersion == 1)
    }
}
