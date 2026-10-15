import Foundation
import Testing
@testable import Domain

/// 四域参考目录的行内 JSON 解码契约（CI 36250690955 修复族）：
/// 契约在 Domain 层且无平台守卫——本测试 Linux/macOS 双跑，
/// 让 snake_case↔camelCase 键漂移在本地可见，而非仅 macOS 运行时暴露。
struct MedicalReferenceCatalogDecodeTests {

    @Test func hospitalDepartmentsDecodeCanonicalDeptsJSON() {
        // 与生产 depts_json 同形（fetch 管线落库形态）
        let json = #"[{"code":"03.02","name_zh":"心血管內科"}]"#
        let list = try? JSONDecoder().decode([MedicalCatalogDepartmentRef].self, from: Data(json.utf8)) // try?-ok: 解码契约测试——try? 即被测语义（非法 JSON 降级为空）
        #expect(list?.first?.code == "03.02")
        #expect(list?.first?.nameZh == "心血管內科")
    }

    @Test func hospitalAliasesDecodeStringArray() {
        let hospital = MedicalCatalogHospital(id: 1, region: "CN", sourceID: "CN:1", code: nil,
                                              nameZh: "協和", shortName: nil, typeZh: nil, levelZh: nil,
                                              address: nil, phone: nil, adminArea: nil,
                                              deptsJSON: "[]", aliasesJSON: #"["協和醫院","协和医院"]"#)
        #expect(hospital.aliases == ["協和醫院", "协和医院"])
    }

    @Test func hospitalDepartmentsFallBackToEmptyOnInvalidJSON() {
        // 降级契约：非法 depts_json → 空科室表（不崩、不伪造数据）
        let hospital = MedicalCatalogHospital(id: 1, region: "CN", sourceID: "CN:1", code: nil,
                                              nameZh: "協和", shortName: nil, typeZh: nil, levelZh: nil,
                                              address: nil, phone: nil, adminArea: nil,
                                              deptsJSON: "not-json", aliasesJSON: "[]")
        #expect(hospital.departments.isEmpty)
    }

    @Test func openObjectAliasesKeepUnknownJSONAcrossAllReferenceDomains() throws {
        let raw = #"[{"text":" 開放別名😀 ","type":"future/open-type","unknown":{"raw":[null,9007199254740993]}},"舊字串別名",{"text":7},{"unknown":"not a name"},null,true]"#
        let hospital = MedicalCatalogHospital(
            id: 1, region: "TW", sourceID: "h", code: nil, nameZh: "醫院", shortName: nil,
            typeZh: nil, levelZh: nil, address: nil, phone: nil, adminArea: nil,
            deptsJSON: "[]", aliasesJSON: raw)
        let department = MedicalCatalogDepartment(
            id: 2, region: "TW", sourceID: "d", code: "d", nameZh: "科室",
            categoryZh: nil, aliasesJSON: raw)
        let diagnosis = MedicalCatalogDiagnosis(
            id: 3, region: "TW", sourceID: "dx", code: "dx", nameZh: "疾病",
            codeSystem: "source", chapterZh: nil, aliasesJSON: raw)
        let exam = MedicalCatalogExamItem(
            id: 4, region: "TW", sourceID: "e", code: "e", nameZh: "檢查", nameEn: nil,
            category: nil, method: nil, specimen: nil, unit: nil, priceRef: nil,
            loincConceptID: nil, aliasesJSON: raw)
        for aliases in [hospital.aliases, department.aliases, diagnosis.aliases, exam.aliases] {
            #expect(aliases == ["開放別名😀", "舊字串別名"])
        }
        for original in [hospital.aliasesJSON, department.aliasesJSON, diagnosis.aliasesJSON, exam.aliasesJSON] {
            #expect(original == raw)
        }
        let encoded = try JSONEncoder().encode(hospital)
        let decoded = try JSONDecoder().decode(MedicalCatalogHospital.self, from: encoded)
        #expect(decoded.aliasesJSON == raw)
        #expect(CatalogJSON.stringArray(#"{"text":"not an array"}"#).isEmpty)
    }
}
