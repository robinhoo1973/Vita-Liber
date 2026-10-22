import Testing
@testable import Domain

/// 疫苗程序参考目录：年龄/性别过滤，不判定漏种、不提供建议。
struct VaccineCatalogTests {
    @Test func catalogIDsAreUnique() {
        let ids = VaccineCatalog.allItems.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func ageFilterKeepsOnlyEligibleWindows() {
        let infant = VaccineCatalog.items(ageMonths: 0, sex: nil)
        #expect(infant.contains { $0.id == "bcg" })
        #expect(infant.contains { $0.id == "hepb_1" })
        #expect(!infant.contains { $0.id == "hpv" })

        let senior = VaccineCatalog.items(ageMonths: 70 * 12, sex: "male")
        #expect(senior.contains { $0.id == "shingles" })
        #expect(senior.contains { $0.id == "ppsv23" })
        #expect(!senior.contains { $0.id == "hpv" })
    }

    @Test func sexSpecificVaccinesFollowKnownSex() {
        let female = VaccineCatalog.items(ageMonths: 30 * 12, sex: "female")
        let male = VaccineCatalog.items(ageMonths: 30 * 12, sex: "male")
        #expect(female.contains { $0.id == "hpv" })
        #expect(!male.contains { $0.id == "hpv" })
    }

    @Test func unknownAgeShowsAllAndAllAgesEscapeWindow() {
        #expect(VaccineCatalog.items(ageMonths: nil, sex: nil).count == VaccineCatalog.allItems.count)
        #expect(VaccineCatalog.items(ageMonths: 30 * 12, sex: nil, includeAllAges: true)
            .count == VaccineCatalog.allItems.count)
    }

    @Test func ageMonthsRejectsMissingOrInvalidBirthDate() {
        #expect(VaccineCatalog.ageMonths(birthDate: nil) == nil)
        #expect(VaccineCatalog.ageMonths(birthDate: "not-a-date") == nil)
        #expect(VaccineCatalog.ageMonths(birthDate: "1980-01-01") != nil)
    }
}
