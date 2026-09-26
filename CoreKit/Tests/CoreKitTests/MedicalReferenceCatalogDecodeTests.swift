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
        let list = try? JSONDecoder().decode([MedicalCatalogDepartmentRef].self, from: Data(json.utf8))
        #expect(list?.first?.code == "03.02")
        #expect(list?.first?.nameZh == "心血管內科")
    }

    @Test func hospitalAliasesDecodeStringArray() {
        let hospital = MedicalCatalogHospital(id: 1, region: "CN", sourceID: "CN:1", code: nil,
                                              nameZh: "協和", shortName: nil, typeZh: nil, levelZh: nil,
                                              address: nil, phone: nil, adminArea: nil,
                                              deptsJSON: "[]", aliasesJSON: #"["協和醫院","协和医院"]"#,
                                              contractEnd: nil)
        #expect(hospital.aliases == ["協和醫院", "协和医院"])
    }

    @Test func hospitalDepartmentsFallBackToEmptyOnInvalidJSON() {
        // 降级契约：非法 depts_json → 空科室表（不崩、不伪造数据）
        let hospital = MedicalCatalogHospital(id: 1, region: "CN", sourceID: "CN:1", code: nil,
                                              nameZh: "協和", shortName: nil, typeZh: nil, levelZh: nil,
                                              address: nil, phone: nil, adminArea: nil,
                                              deptsJSON: "not-json", aliasesJSON: "[]",
                                              contractEnd: nil)
        #expect(hospital.departments.isEmpty)
    }
}
