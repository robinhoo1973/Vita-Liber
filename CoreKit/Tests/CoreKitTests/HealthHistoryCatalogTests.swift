import Testing
@testable import Domain

/// 健康史目录：稳定 id + 部位引用完整性；目录只做索引，不做诊断。
struct HealthHistoryCatalogTests {
    @Test func regionAndOrganIDsAreUnique() {
        let regions = HealthHistoryCatalog.bodyRegions
        #expect(Set(regions.map(\.id)).count == regions.count)
        let organIDs = regions.flatMap { $0.organs.map(\.id) }
        #expect(Set(organIDs).count == organIDs.count)
    }

    @Test func catalogEntriesReferenceKnownRegions() {
        let regionIDs = Set(HealthHistoryCatalog.bodyRegions.map(\.id))
        for condition in HealthHistoryCatalog.commonConditions {
            #expect(regionIDs.contains(condition.regionID), "\(condition.id) 部位不存在")
        }
        for surgery in HealthHistoryCatalog.commonSurgeries {
            #expect(regionIDs.contains(surgery.regionID), "\(surgery.id) 部位不存在")
        }
    }

    @Test func catalogOrganReferencesResolveInsideRegion() {
        for region in HealthHistoryCatalog.bodyRegions {
            let organIDs = Set(region.organs.map(\.id))
            for condition in HealthHistoryCatalog.conditions(in: region.id) {
                if let organID = condition.organID {
                    #expect(organIDs.contains(organID),
                            "\(condition.id) 的器官 \(organID) 不在 \(region.id)")
                }
            }
            for surgery in HealthHistoryCatalog.surgeries(in: region.id) {
                if let organID = surgery.organID {
                    #expect(organIDs.contains(organID),
                            "\(surgery.id) 的器官 \(organID) 不在 \(region.id)")
                }
            }
        }
    }

    @Test func organFilterFallsBackToRegionLevel() {
        let liver = HealthHistoryCatalog.conditions(in: "abdomen", organID: "liver")
        #expect(liver.contains { $0.id == "fatty_liver" })
        #expect(liver.allSatisfy { $0.organID == "liver" })

        let spleen = HealthHistoryCatalog.conditions(in: "abdomen", organID: "spleen")
        #expect(spleen.isEmpty, "脾无常见病条目时应为空，不混入肝胆疾病")
    }

    @Test func commonConditionsCoverOfficialFourGroups() {
        let names = Set(HealthHistoryCatalog.commonConditions.map(\.name))
        #expect(names.contains("高血压"))
        #expect(names.contains("冠心病"))
        #expect(names.contains("脑卒中"))
        #expect(names.contains("2 型糖尿病"))
        #expect(names.contains("慢性阻塞性肺疾病"))
        #expect(names.contains("哮喘"))
    }

    @Test func allergenKindsMatchAllergyVocabulary() {
        for allergen in HealthHistoryCatalog.commonAllergens {
            #expect(SevereReactionRules.allergenKinds.contains(allergen.kind),
                    "\(allergen.id) 类型不在 allergy_event 词表")
        }
    }
}
