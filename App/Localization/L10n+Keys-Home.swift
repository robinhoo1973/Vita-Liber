// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var navHome: String { t("nav.home") }

    static var navRecords: String { t("nav.records") }

    static var navReminders: String { t("nav.reminders") }

    static var navHealth: String { t("nav.health") }

    static var navMe: String { t("nav.me") }

    static var onboard_yourName: String { t("onboard.yourName") }

    static var onboardNotSelected: String { t("onboard.notSelected") }

    static var onboardGender: String { t("onboard.gender") }

    static var onboardGenderMale: String { t("onboard.gender.male") }

    static var onboardGenderFemale: String { t("onboard.gender.female") }

    static var onboardGenderOther: String { t("onboard.gender.other") }

    static var onboardBirthYear: String { t("onboard.birthYear") }

    static var onboardBirthMonth: String { t("onboard.birthMonth") }

    static var onboardBirthDay: String { t("onboard.birthDay") }

    static var onboardBloodSpecial: String { t("onboard.blood.special") }

    static var onboardBloodNotePlaceholder: String { t("onboard.blood.notePlaceholder") }

    static var onboardProfileHeader: String { t("onboard.profile.header") }

    static var onboardProfileFooter: String { t("onboard.profile.footer") }

    static var onboardContactHeader: String { t("onboard.contact.header") }

    static var onboardContactFooter: String { t("onboard.contact.footer") }

    static var onboardContactName: String { t("onboard.contact.name") }

    static var onboardContactRelation: String { t("onboard.contact.relation") }

    static var onboardContactPhone: String { t("onboard.contact.phone") }

    static var onboardPrefillHint: String { t("onboard.prefillHint") }

    static var onboard_saveEdit: String { t("onboard.saveEdit") }

    static var onboard_createContinue: String { t("onboard.createContinue") }

    static var onboardSaveFailed: String { t("onboard.saveFailed") }

    static var onboardSaveFailedHint: String { t("onboard.saveFailedHint") }

    static var onboard_cancel: String { t("onboard.cancel") }

    static var onboard_finishEnterApp: String { t("onboard.finishEnterApp") }

    static var onboard_confirmed: String { t("onboard.confirmed") }

    static var onboard_buildProfile: String { t("onboard.buildProfile") }

    static var onboard_gotIt: String { t("onboard.gotIt") }

    static var onboard_confirm: String { t("onboard.confirm") }

    static var onboard_later: String { t("onboard.later") }

    static var onboard_ownerNote: String { t("onboard.ownerNote") }

    static var onboard_unconfirmedBadge: String { t("onboard.unconfirmedBadge") }

    static var onboardBoundaryTitle: String { t("onboard.boundaryTitle") }

    static var onboardStorageTitle: String { t("onboard.storageTitle") }

    static var onboardSkipInfoTitle: String { t("onboard.skipInfoTitle") }

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

    static var member_save: String { t("member.save") }

    static var member_quotaHint: String { t("member.quotaHint") }

    static var member_addedHint: String { t("member.addedHint") }

    static var member_addFailed: String { t("member.addFailed") }

    static var onboard_sourceConfirmed: String { t("onboard.sourceConfirmed") }

    static var onboard_unconfirmed2: String { t("onboard.unconfirmed2") }

    static var homeSwipeArchive: String { t("home.swipe.archive") }

    static var homeSwipeUndo: String { t("home.swipe.undo") }

    static var homeSwipeOpenCabinet: String { t("home.swipe.openCabinet") }

    static var homeSwipeSnoozeTomorrow: String { t("home.swipe.snoozeTomorrow") }

    static var homeSwipeViewEvidence: String { t("home.swipe.viewEvidence") }

    static var homeSwipeView: String { t("home.swipe.view") }

    static var homeSwipeFailed: String { t("home.swipe.failed") }

    static var homeTodayTodos: String { t("home.todayTodos") }

    static var homeExpiringSoon: String { t("home.expiringSoon") }

    static var homeRefill: String { t("home.refill") }

    static var homeAlertSummary: String { t("home.alertSummary") }

    static var homeRecentObs: String { t("home.recentObs") }

    static var homeQuickCapture: String { t("home.quickCapture") }

    static var homeCaptureRecord: String { t("home.capture.record") }

    static var homeCaptureReport: String { t("home.capture.report") }

    static var homeCapturePrescription: String { t("home.capture.prescription") }

    static var homeCaptureSymptom: String { t("home.capture.symptom") }

    static var homeCaptureHint: String { t("home.capture.hint") }

    static var homeCaptureAny: String { t("home.captureAny") }

    static var homeCaptureShoot: String { t("home.capture.shoot") }

    static var homeCaptureLibrary: String { t("home.capture.library") }

    static var homeCaptureFile: String { t("home.capture.file") }

    static var homeCaptureNoCamera: String { t("home.capture.noCamera") }

    static var homeCaptureSaved: String { t("home.capture.saved") }

    static var homeProfileProgressTitle: String { t("home.profileProgress") }

    static var homeModelDownloadTitle: String { t("home.model.downloadTitle") }

    static var homeModelDownloadView: String { t("home.model.downloadView") }

    static var homeProfileContinue: String { t("home.profileContinue") }

    static var homeDisclaimer: String { t("home.disclaimer") }

    static var homeGuide1: String { t("home.guide1") }

    static var homeGuide2: String { t("home.guide2") }

    static var homeGuide3: String { t("home.guide3") }

    static var homeGuide4: String { t("home.guide4") }

    static var homeMemberSwitch: String { t("home.memberSwitch") }

    static var homeNotifDenied: String { t("home.notifDenied") }

    static var homeNotifOpen: String { t("home.notifOpen") }

    static var homeCareMeds: String { t("home.care.meds") }

    static var homeCareRefill: String { t("home.care.refill") }

    static var homeCareCapture: String { t("home.care.capture") }

    static var homeCareSOS: String { t("home.care.sos") }

    static var homeDoseSlot: String { t("home.doseSlot") }

    static var homeAggregationTitle: String { t("home.aggregationTitle") }

    static var homeFilterAll: String { t("home.filter.all") }

    static var homeFilterMedication: String { t("home.filter.medication") }

    static var homeFilterAppointment: String { t("home.filter.appointment") }

    static var homeFilterDocument: String { t("home.filter.document") }

    static var homeFilterOcr: String { t("home.filter.ocr") }

    static var homeFilterAlert: String { t("home.filter.alert") }

    static var homeFilterFamily: String { t("home.filter.family") }

    static var homeFilterSOS: String { t("home.filter.sos") }

    static var homeFilterSystem: String { t("home.filter.system") }

    static var homeFilterPending: String { t("home.filter.pending") }

    static var homeWindowDefault: String { t("home.window.default") }

    static var homeWindowShort: String { t("home.window.short") }

    static var homeWindowLong: String { t("home.window.long") }

    static var homeEmptyFilter: String { t("home.emptyFilter") }

    static var homeEmptyReset: String { t("home.emptyReset") }

    static var homeL0Note: String { t("home.l0Note") }

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

    static var homePendingCards: String { t("home.pendingCards") }

    static var homePendingCardResume: String { t("home.pendingCardResume") }

    static var homeOcrOverdue: String { t("home.ocrOverdue") }

    static func homeExpiryMed(_ name: String) -> String { t("home.expiryMed").replacingOccurrences(of: "%@", with: name) }

    static var onboard_revise: String { t("onboard.revise") }

    static var onboardAddFamilyTitle: String { t("onboard.addFamily.title") }

    static var onboardAddFamilyHint: String { t("onboard.addFamily.hint") }

    static var onboardAddFamilyManual: String { t("onboard.addFamily.manual") }

    static var onboardAddFamilyVoiceP1: String { t("onboard.addFamily.voiceP1") }

    static var onboardAddFamilyContactsP1: String { t("onboard.addFamily.contactsP1") }

    static var onboardAddFamilySkip: String { t("onboard.addFamily.skip") }

    static var onboardAddFamilyFinish: String { t("onboard.addFamily.finish") }

    static var onboardAddFamilyCompleteHint: String { t("onboard.addFamily.completeHint") }

    static var captureSensitiveToggle: String { t("home.capture.sensitive") }

    static var homeVoice: String { t("home.voice") }
}
