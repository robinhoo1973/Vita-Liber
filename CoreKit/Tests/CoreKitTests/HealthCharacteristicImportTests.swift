import Foundation
import Testing
@testable import Domain

/// Apple 健康特征型 → 档案候选（业主 2026-09-17 定：导入，走档案候选；不覆盖已有值；精度不细化）。
@Suite("SU-FR16.1 · 特征型档案候选（血型/出生日期/生理性别）")
struct HealthCharacteristicImportTests {

    private func profile(blood: String? = nil, birth: String? = nil, gender: String? = nil) -> PatientProfile {
        PatientProfile(displayName: "张三", relation: "本人", gender: gender, birthDate: birth, bloodType: blood)
    }

    @Test("档案无值 → 可采纳；健康未填的字段不出现")
    func 无值可采纳() {
        let health = HealthCharacteristics(bloodType: "A+", birthDate: "1990-05-03", gender: "male")
        let candidates = HealthCharacteristicImport.candidates(characteristics: health, profile: profile())
        #expect(candidates.map(\.field) == [.bloodType, .birthDate, .gender])
        #expect(candidates.allSatisfy { $0.isAdoptable }, "三项都可采纳")
        #expect(HealthCharacteristicImport.hasAdoptable(candidates))

        let partial = HealthCharacteristics(bloodType: "O−")
        #expect(HealthCharacteristicImport.candidates(characteristics: partial, profile: profile()).map(\.field) == [.bloodType],
                "健康里只填了血型 → 只有一行")
        #expect(!HealthCharacteristicImport.hasAdoptable(HealthCharacteristicImport.candidates(
            characteristics: HealthCharacteristics(), profile: profile())), "空特征 → 无可采纳（入口不出现）")
    }

    @Test("档案已有值 → 默认保留、不给「采用」（医院原文/用户手填优先级更高）")
    func 已有值不覆盖() {
        let health = HealthCharacteristics(bloodType: "A+", birthDate: "1990-05-03")
        let candidates = HealthCharacteristicImport.candidates(
            characteristics: health, profile: profile(blood: "B型（Rh阳性）", birth: "1988-01-02"))
        #expect(candidates.allSatisfy { $0.keepsExisting }, "两行都保留现值")
        #expect(candidates.allSatisfy { !$0.isAdoptable }, "不给「采用」= 不覆盖")
        #expect(candidates[0].existing == "B型（Rh阳性）", "现值原样呈现对照")
    }

    @Test("出生日期精度：档案是「仅年份」→ 候选降到年份，不擅自细化")
    func 精度不细化() {
        let health = HealthCharacteristics(birthDate: "1990-05-03")
        let yearOnly = HealthCharacteristicImport.candidates(characteristics: health, profile: profile(birth: "1990"))
        // 档案有值 → 该行本身不可采纳；此处验证的是**候选值**已被降到年份
        #expect(yearOnly[0].proposed == "1990", "仅年份精度 → 候选 `1990`；实得 \(yearOnly[0].proposed)")

        let noValue = HealthCharacteristicImport.candidates(characteristics: health, profile: profile())
        #expect(noValue[0].proposed == "1990-05-03", "档案无值 → 完整日期")
    }

    @Test("生理性别：Health 三档原样透传（male/female/other），不做本地化改写")
    func 性别透传() {
        for value in ["male", "female", "other"] {
            let candidates = HealthCharacteristicImport.candidates(
                characteristics: HealthCharacteristics(gender: value), profile: profile())
            #expect(candidates.first?.proposed == value, "原样透传：\(value)")
        }
    }
}
