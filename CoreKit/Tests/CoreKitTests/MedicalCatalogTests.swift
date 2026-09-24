import Foundation
import Testing
import Domain

@Suite("Medical catalog exact-first matching")
struct MedicalCatalogMatchingTests {
    private let exactDrug = MedicalCatalogDrug(
        id: 1, region: "CN", sourceID: "CN:1", licenseNo: "L1", nameZh: "阿司匹林",
        nameEn: nil, brandName: nil, dosageForm: "片剂", spec: "100mg", drugCategory: nil,
        licenseHolder: nil, manufacturer: nil, insuranceCode: "INS-1", drugCode: "DRUG-1",
        activeIngredients: "阿司匹林", usageReferenceJSON: "{}")

    private let secondDrug = MedicalCatalogDrug(
        id: 2, region: "TW", sourceID: "TW:2", licenseNo: "L2", nameZh: "阿司匹林",
        nameEn: nil, brandName: nil, dosageForm: "片剂", spec: "100mg", drugCategory: nil,
        licenseHolder: nil, manufacturer: nil, insuranceCode: "INS-2", drugCode: "DRUG-2",
        activeIngredients: "阿司匹林", usageReferenceJSON: "{}")

    @Test("exact match wins over name candidates")
    func exactMatchWins() {
        let result = MedicalCatalogMatching.resolve(exact: [exactDrug], candidates: [secondDrug])
        #expect(result.status == .exact)
        #expect(result.exact?.id == exactDrug.id)
        #expect(result.candidates.map(\.id) == [exactDrug.id])
    }

    @Test("multiple exact rows become conflict without automatic selection")
    func exactConflictIsReadOnly() {
        let result = MedicalCatalogMatching.resolve(exact: [exactDrug, secondDrug], candidates: [])
        #expect(result.status == .conflict)
        #expect(result.exact == nil)
        #expect(result.candidates.map(\.id) == [exactDrug.id, secondDrug.id])
    }

    @Test("one name candidate remains a candidate")
    func oneCandidateRemainsUnconfirmed() {
        let result = MedicalCatalogMatching.resolve(exact: [], candidates: [secondDrug])
        #expect(result.status == .candidate)
        #expect(result.exact == nil)
        #expect(result.candidates.map(\.id) == [secondDrug.id])
    }

    @Test("no evidence remains unmatched")
    func noEvidenceIsUnmatched() {
        let result = MedicalCatalogMatching.resolve(exact: [], candidates: [])
        #expect(result.status == .unmatched)
        #expect(result.exact == nil)
        #expect(result.candidates.isEmpty)
    }

    @Test("medical catalog detail route is Codable and typed")
    func detailRouteRoundTrips() throws {
        let route = AppRoute.medicalCatalogDetail(id: 42)
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(AppRoute.self, from: data) == route)
    }

    @Test("drug detail preserves usage and source payloads")
    func drugDetailPreservesSourcePayloads() {
        let detail = MedicalCatalogDrugDetail(
            region: "CN", sourceID: "CN:1", usageText: "遵说明书",
            indications: "原始适应证", activeIngredients: "阿司匹林",
            usageReferenceJSON: "{\"freq\":\"qd\"}", rawJSON: "{\"raw\":true}")
        #expect(detail.usageText == "遵说明书")
        #expect(detail.indications == "原始适应证")
        #expect(detail.rawJSON.contains("raw"))
    }
}
