// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var emergency_title: String { t("emergency.title") }

    static var emergency_bloodType: String { t("emergency.bloodType") }

    static var emergency_allergy: String { t("emergency.allergy") }

    static var emergency_meds: String { t("emergency.meds") }

    static var emergency_health: String { t("emergency.health") }

    static var emergency_contacts: String { t("emergency.contacts") }

    static var emergency_notSet: String { t("emergency.notSet") }

    /// 装载态：成员数据未完成前不把空卡呈现成「未配置」。
    static var emergencyLoading: String { t("emergency.loading") }

    /// 装载失败态：与「空卡」区分，可重试。
    static var emergencyLoadFailed: String { t("emergency.loadFailed") }

    static var emergency_sos_hold: String { t("emergency.sos.hold") }

    static var emergency_sos_confirmPrompt: String { t("emergency.sos.confirmPrompt") }

    static var emergency_sos_confirm: String { t("emergency.sos.confirm") }

    static var emergency_sos_cancel: String { t("emergency.sos.cancel") }

    static var emergency_manageCard: String { t("emergency.manageCard") }

    static var emergencyNumber: String { t("emergency.number") }

    static var emergencyWriteTitle: String { t("emergency.write.title") }

    static var emergencyWriteSubtitle: String { t("emergency.write.subtitle") }

    static var emergencyViewGuide: String { t("emergency.viewGuide") }

    static var emergencySectionAllergy: String { t("emergency.section.allergy") }

    static var emergencySectionMeds: String { t("emergency.section.meds") }

    static var emergencySectionHealth: String { t("emergency.section.health") }

    static var emergencySectionContacts: String { t("emergency.section.contacts") }

    static var emergencySelectTitle: String { t("emergency.select.title") }

    static var emergencyNoCandidates: String { t("emergency.noCandidates") }

    static var emergencySelected: String { t("emergency.selected") }

    static var emergencyUnselected: String { t("emergency.unselected") }

    static var sosHelpTitle: String { t("sos.help.title") }

    static var sosCall120: String { t("sos.call120") }

    static var sosNoContacts: String { t("sos.noContacts") }

    static var sosViewCard: String { t("sos.viewCard") }

    static var sosSendLocationP1: String { t("sos.sendLocationP1") }

    /// FR18.6 / BR-012：SOS 拨号失败（设备不可拨号或号码归一失败）。
    /// 免门禁路径的失败必须**响亮可见**——静默死控件会让用户以为已拨出。
    static var sosDialFailed: String { t("sos.dialFailed") }
static var medicalIDTitle: String { t("medicalID.title") }
    static var medicalIDStep1: String { t("medicalID.step1") }
    static var medicalIDStep1Hint: String { t("medicalID.step1Hint") }
    static var medicalIDStep2: String { t("medicalID.step2") }
    static var medicalIDStep2Hint: String { t("medicalID.step2Hint") }
    static var medicalIDStep3: String { t("medicalID.step3") }
    static var medicalIDStep3Hint: String { t("medicalID.step3Hint") }
    static var medicalIDOpenHealth: String { t("medicalID.openHealth") }
    static var medicalIDNote: String { t("medicalID.note") }

    // MARK: - 紧急联系人管理（2026-10-23 业主：档案既有联系人须可补录入卡）

    static var emergencyContactsHubHint: String { t("emergency.contacts.hubHint") }
    static var emergencyContactsManage: String { t("emergency.contacts.manage") }
    static var emergencyContactsEmpty: String { t("emergency.contacts.empty") }
    static var emergencyContactsAdd: String { t("emergency.contacts.add") }
    static var emergencyContactsEdit: String { t("emergency.contacts.edit") }
    static var emergencyContactsHint: String { t("emergency.contacts.hint") }
    static var emergencyContactsPhoneHint: String { t("emergency.contacts.phoneHint") }
    static var emergencyContactsDeleteTitle: String { t("emergency.contacts.deleteTitle") }
    static var emergencyContactsDeleteHint: String { t("emergency.contacts.deleteHint") }
    static var emergencyContactsActionFailed: String { t("emergency.contacts.actionFailed") }
}
