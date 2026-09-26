import Foundation

    /// 成员（家人档案）域文案键（业主 2026-09-26 L10n 重组：自 Home 分片迁出（旧名 `L10n+Keys-Home.swift`）——
    /// 命名按文件内部实际功能归位，与 `App/Features/Members/` 对齐；键名不变，
    /// Registry / 三语 .strings / SU-M15-L10N 键集断言均不受影响）。
extension L10n {

    static var member_title: String { t("member.title") }

    static var member_add: String { t("member.add") }

    static var member_current: String { t("member.current") }

    static var member_switch: String { t("member.switch") }

    static var member_namePlaceholder: String { t("member.namePlaceholder") }

    static var memberUpdateFailed: String { t("member.updateFailed") }

    static var memberUpdateFailedHint: String { t("member.updateFailedHint") }

    /// FR3.4 删除成员失败（不可逆动作的失败必须可见）
    static var memberDeleteFailed: String { t("member.deleteFailed") }

    static var member_relation: String { t("member.relation") }

    static var member_birthDatePlaceholder: String { t("member.birthDatePlaceholder") }

    /// 业主裁决 3（2026-09-26）：生日结构控件标签（DatePicker/Toggle 共用）
    static var member_birthDateLabel: String { t("member.birthDateLabel") }

    /// 业主裁决 3：存量非法生日值的补录提示
    static var member_birthDateInvalidHint: String { t("member.birthDateInvalidHint") }

    static var member_save: String { t("member.save") }

    static var member_quotaHint: String { t("member.quotaHint") }

    static var member_addedHint: String { t("member.addedHint") }

    static var member_addFailed: String { t("member.addFailed") }

    static var memberDetailBasic: String { t("member.detail.basic") }

    static var memberDetailMore: String { t("member.detail.more") }

    static var memberBloodType: String { t("member.bloodType") }

    static var memberIdNo: String { t("member.idNo") }

    static var memberInsuranceNo: String { t("member.insuranceNo") }

    static var memberNote: String { t("member.note") }

    static var memberDelete: String { t("member.delete") }

    static var memberSelfNoDelete: String { t("member.selfNoDelete") }

    static var memberDeleteImpact: String { t("member.delete.impact") }

    static var memberDeleteImpactDocs: String { t("member.delete.impactDocs") }

    static var memberDeleteImpactObs: String { t("member.delete.impactObs") }

    static var memberDeleteImpactPlans: String { t("member.delete.impactPlans") }

    static var memberDeleteImpactAppts: String { t("member.delete.impactAppts") }

    static var memberDeleteKeepDocs: String { t("member.delete.keepDocs") }

    static var memberDeletePlanChoice: String { t("member.delete.planChoice") }

    static var memberDeletePlans: String { t("member.delete.plans") }

    static var memberArchivePlans: String { t("member.archivePlans") }

    static var memberDeleteConfirm: String { t("member.delete.confirm") }

    static var memberDeleteConfirmButton: String { t("member.delete.confirmButton") }

    static var memberConfirmBelongsTo: String { t("member.confirm.belongsTo") }

    static var memberConfirmSwitch: String { t("member.confirm.switch") }

    static var member_relationSelf: String { t("member.relation.self") }

    static var member_relationPartner: String { t("member.relation.partner") }

    static var member_relationChild: String { t("member.relation.child") }

    static var member_relationParent: String { t("member.relation.parent") }

    static var member_relationGrandparent: String { t("member.relation.grandparent") }

    static var member_relationOther: String { t("member.relation.other") }

    static var member_relationFamily: String { t("member.relation.family") }

    static var member_relationFather: String { t("member.relation.father") }

    static var member_relationMother: String { t("member.relation.mother") }

    static var member_relationSon: String { t("member.relation.son") }

    static var member_relationDaughter: String { t("member.relation.daughter") }
}
