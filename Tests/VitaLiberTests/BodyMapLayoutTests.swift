import XCTest
import CoreGraphics
import Domain
@testable import VitaLiber

/// 人体图二级器官布局：目录完整覆盖、性别过滤、坐标不出画布。
final class BodyMapLayoutTests: XCTestCase {
    func testEveryCatalogOrganHasPlacement() {
        for region in HealthHistoryCatalog.bodyRegions {
            for organ in region.organs {
                XCTAssertNotNil(OrganLayout.placement(regionID: region.id, organID: organ.id),
                                "\(region.id)/\(organ.id) 缺少人体图位置")
            }
        }
    }

    func testPelvicOrgansFollowKnownGender() {
        let male = Set(OrganLayout.placements(regionID: "pelvis", gender: "male").map(\.id))
        XCTAssertFalse(male.contains("uterus"))
        XCTAssertFalse(male.contains("ovary"))
        XCTAssertTrue(male.contains("prostate"))
        XCTAssertTrue(male.contains("bladder"))

        let female = Set(OrganLayout.placements(regionID: "pelvis", gender: "female").map(\.id))
        XCTAssertFalse(female.contains("prostate"))
        XCTAssertTrue(female.contains("uterus"))
        XCTAssertTrue(female.contains("ovary"))
    }

    func testPlacementsStayInsideCanvas() {
        for region in HealthHistoryCatalog.bodyRegions {
            for placement in OrganLayout.placements(regionID: region.id, gender: nil) {
                XCTAssertGreaterThanOrEqual(placement.x, 0.0)
                XCTAssertLessThanOrEqual(placement.x, 1.0)
                XCTAssertGreaterThanOrEqual(placement.y, 0.0)
                XCTAssertLessThanOrEqual(placement.y, 1.0)
                XCTAssertGreaterThan(placement.width, 0.0)
                XCTAssertGreaterThan(placement.height, 0.0)
            }
        }
    }

    /// 二级剪影裁切窗口必须落在全身图内（越界会在放大层露出空白/错位）。
    func testRegionCropsStayInsideBodySilhouette() {
        for region in HealthHistoryCatalog.bodyRegions where region.id != "systemic" {
            guard let crop = BodySilhouette.crop(for: region.id) else {
                XCTFail("\(region.id) 缺少剪影裁切窗口")
                continue
            }
            XCTAssertGreaterThanOrEqual(crop.minX, 0)
            XCTAssertGreaterThanOrEqual(crop.minY, 0)
            XCTAssertLessThanOrEqual(crop.maxX, 1)
            XCTAssertLessThanOrEqual(crop.maxY, 1)
        }
    }
}
