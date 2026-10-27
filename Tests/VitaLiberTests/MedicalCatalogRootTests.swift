import Foundation
import XCTest
@testable import VitaLiber

/// 信任根打包守卫（2026-10-27）：`Resources/MedicalCatalogRoot.json` 缺失时
/// `AppContainer` 的 catalogChecker 恒为 nil，医疗数据检查/更新永久「暂不可用」。
/// 该文件曾长期未入库（CNB 已发布 installable 包但 App 从不联网）；本测试保证
/// 它随 App 打包且形状正确（2-of-2 根/目录签名域）。
final class MedicalCatalogRootTests: XCTestCase {
    func testPinnedRootIsBundledAndWellFormed() throws {
        // App 类所在 bundle 最可靠（宿主测试里 Bundle.main 通常也是 App，
        // 但先按类定位可避免 runner 差异）；缺失即失败。
        let appBundle = Bundle(for: AppSessionHolder.self)
        let url = try XCTUnwrap(
            appBundle.url(forResource: "MedicalCatalogRoot", withExtension: "json")
                ?? Bundle.main.url(forResource: "MedicalCatalogRoot", withExtension: "json"),
            "Resources/MedicalCatalogRoot.json 未随 App 打包——医疗数据检查将永久不可用")
        let data = try Data(contentsOf: url)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let signatures = try XCTUnwrap(envelope["signatures"] as? [[String: Any]])
        XCTAssertEqual(signatures.count, 2, "根信封应由两把根密钥签署")

        let payloadString = try XCTUnwrap(envelope["payload"] as? String)
        let payloadData = try XCTUnwrap(Data(base64Encoded: payloadString))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(root["role"] as? String, "root")
        XCTAssertEqual(root["assetKind"] as? String, "medical-data")
        XCTAssertEqual(root["rootThreshold"] as? Int, 2)
        XCTAssertEqual(root["catalogThreshold"] as? Int, 2)
        XCTAssertEqual((root["rootKeyIDs"] as? [String])?.count, 2)
        XCTAssertEqual((root["catalogKeyIDs"] as? [String])?.count, 2)
        XCTAssertNotNil(root["expiresAt"] as? String)
        XCTAssertEqual(root["assetBaseURL"] as? String,
                       "https://cnb.cool/robinhoo1973/Resources/-/releases/download/medical-data")
    }
}
