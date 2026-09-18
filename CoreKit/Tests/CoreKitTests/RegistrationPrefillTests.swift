import Foundation
import Testing
@testable import Domain

/// 首启注册预填与紧急联系人草稿（业主 2026-09-17 定：注册必要字段 =
/// 特征性数据（血型/出生日期/生理性别）+ 紧急联系人；健康里有数据 → 默认值，
/// 没有 → 手动填写，绝不阻断注册）。
@Suite("SU-FR21.9 · 注册预填映射与联系人校验")
struct RegistrationPrefillTests {

    @Test("完整日期/仅年份/性别三档/标准血型 → 表单默认值")
    /// 原名：预填映射
    func prefillMapping() {
        let full = RegistrationPrefill.defaults(from: HealthCharacteristics(
            bloodType: "O+", birthDate: "1990-05-03", gender: "female"))
        #expect(full.gender == "female")
        #expect(full.birthYear == "1990" && full.birthMonth == "05" && full.birthDay == "03")
        #expect(full.bloodType == "O+")
        #expect(!full.isEmpty)

        let yearOnly = RegistrationPrefill.defaults(from: HealthCharacteristics(birthDate: "1990"))
        #expect(yearOnly.birthYear == "1990" && yearOnly.birthMonth == nil && yearOnly.birthDay == nil,
                "仅年份精度随来源，不擅自细化")

        let empty = RegistrationPrefill.defaults(from: HealthCharacteristics())
        #expect(empty.isEmpty, "健康里没填 → 无默认值，表单手动填写（绝不阻断注册）")
    }

    @Test("血型只在标准八档内预填；非标准值不进默认值（机器不代写用户措辞）")
    /// 原名：血型八档
    func bloodTypeEightTiers() {
        for type in RegistrationPrefill.standardBloodTypes {
            #expect(RegistrationPrefill.defaults(from: HealthCharacteristics(bloodType: type)).bloodType == type)
        }
        // HealthKit 只产出标准八档；防御性：非标准值不预填
        #expect(RegistrationPrefill.defaults(from: HealthCharacteristics(bloodType: "RhD 变异型")).bloodType == nil)
    }

    @Test("联系人校验：三字段非空 ∧ 手机号 5–20 位数字（允许 + - 空格括号）")
    /// 原名：联系人校验
    func contactValidation() {
        #expect(EmergencyContactDraft(name: "张三", relation: "配偶", phone: "13800138000").isValid)
        #expect(EmergencyContactDraft(name: "张三", relation: "配偶", phone: "+86 138-0013-8000").isValid,
                "国际区号与分隔符形态合法")
        #expect(!EmergencyContactDraft(name: "  ", relation: "配偶", phone: "13800138000").isValid, "姓名空白无效")
        #expect(!EmergencyContactDraft(name: "张三", relation: "配偶", phone: "123").isValid, "数字过短无效")
        #expect(!EmergencyContactDraft(name: "张三", relation: "配偶", phone: "abc12345678").isValid, "字母无效")
        #expect(!EmergencyContactDraft(name: "张三", relation: "", phone: "13800138000").isValid, "关系空白无效")
    }
}
