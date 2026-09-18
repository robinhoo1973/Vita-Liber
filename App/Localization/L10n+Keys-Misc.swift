// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var dispenseHeaders: [String] {
        [t("dispense.header.name"), t("dispense.header.spec"), t("dispense.header.unit"),
         t("dispense.header.plan"), t("dispense.header.confirmed"), t("dispense.header.expire")]
    }

    static var docTypeLabels: [String] {
        [t("docTypeLabel.outpatient"), t("docTypeLabel.inpatient"), t("docTypeLabel.labReport"),
         t("docTypeLabel.imageReport"), t("docTypeLabel.prescription"), t("docTypeLabel.payment"),
         t("docTypeLabel.dischargeSummary"), t("docTypeLabel.diagnosisProof"),
         t("docTypeLabel.vaccineRecord"), t("docTypeLabel.checkupReport"),
         t("docTypeLabel.pathologyReport"), t("docTypeLabel.surgeryRecord"),
         t("docTypeLabel.allergyRecord"), t("docTypeLabel.other"), t("docTypeLabel.custom")]
    }

    static var security_unlockTitle: String { t("security.unlockTitle") }

    static var security_unlockSubtitle: String { t("security.unlockSubtitle") }

    static var security_unlockButton: String { t("security.unlockButton") }

    static var security_unlockReason: String { t("security.unlockReason") }

    static var security_unlockFailed: String { t("security.unlockFailed") }

    static var sensitive_unlockReason: String { t("sensitive.unlockReason") }

    static var care_title: String { t("care.title") }

    static var care_footer: String { t("care.footer") }

    static var care_parameters_section: String { t("care.parameters.section") }

    static var care_parameters_touchTarget: String { t("care.parameters.touchTarget") }

    static var care_parameters_speechRate: String { t("care.parameters.speechRate") }

    static var care_parameters_readback: String { t("care.parameters.readback") }

    static var care_parameters_voiceInput: String { t("care.parameters.voiceInput") }

    static var care_parameters_sos: String { t("care.parameters.sos") }

    static var care_parameters_valueSlow: String { t("care.parameters.valueSlow") }

    static var care_parameters_valueAskEachTime: String { t("care.parameters.valueAskEachTime") }

    static var care_parameters_valueDefaultOn: String { t("care.parameters.valueDefaultOn") }

    static var currencyCNY: String { t("currency.CNY") }

    static var deeplink_title: String { t("deeplink.title") }

    static var deeplink_jump: String { t("deeplink.jump") }

    static var deeplink_open: String { t("deeplink.open") }

    static var deeplink_notFound: String { t("deeplink.notFound") }

    static var deeplink_bookingNo: String { t("deeplink.bookingNo") }

    static var deeplink_saveNo: String { t("deeplink.saveNo") }

        static var fr24_title: String { t("fr24.title") }

    static var fr24_empty: String { t("fr24.empty") }

    static var fr24_emptyHint: String { t("fr24.emptyHint") }

    static var fr24_recipient: String { t("fr24.recipient") }

    static var fr24_kindHelpCard: String { t("fr24.kindHelpCard") }

    static var fr24_kindSos: String { t("fr24.kindSos") }

    static var fr24_statusSent: String { t("fr24.statusSent") }

    static var fr24_statusAckPending: String { t("fr24.statusAckPending") }

    static var fr24_statusAcked: String { t("fr24.statusAcked") }

    static var fr24_statusTimeout: String { t("fr24.statusTimeout") }

    static var hub_healthRecords: String { t("hub.healthRecords") }

    static var hub_guidelines: String { t("hub.guidelines") }

    static var hub_helpCardOpen: String { t("hub.helpCardOpen") }

    static var paywallPurchaseFailed: String { t("paywall.purchaseFailed") }

    static var paywallRestoreNothing: String { t("paywall.restoreNothing") }

    static var paywallRestoreFailed: String { t("paywall.restoreFailed") }

    static func deeplinkJump(_ hospital: String) -> String {
        t("deeplink.jump").replacingOccurrences(of: "%@", with: hospital)
    }

    static func deeplinkOpen(_ hospital: String) -> String {
        t("deeplink.open").replacingOccurrences(of: "%@", with: hospital)
    }

    static func qualityTag(_ raw: String) -> String { t(raw) }

    static func trendPeriodRange(_ from: Date, _ to: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: bundleLanguage)
        return formatter.string(from: from, to: to)
    }

    static func trendDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: bundleLanguage)
        return formatter.string(from: date)
    }

    static var gsDetailNotFound: String { t("gsDetail.notFound") }

    static var gsDetailThresholds: String { t("gsDetail.thresholds") }

    static var gsDetailNote: String { t("gsDetail.note") }

    static var commonSave: String { t("common.save") }

    /// 布尔字段的展示词（审查修复：观察详情「是否首现 / 是否已咨询医生」
    /// 此前借用 onboard.confirm「确认」/ common.cancel「取消」当真假词，
    /// 读起来成了「是否首现：取消」这种与存储事实相反的陈述句）。
    static var commonYes: String { t("common.yes") }
    static var commonNo: String { t("common.no") }

    static var commonCancel: String { t("common.cancel") }

    static var commonConfirm: String { t("common.confirm") }

    static var commonMember: String { t("common.member") }

    static var paywallPreviewTitle: String { t("paywall.previewTitle") }

    static var tabRemindersBadge: String { t("tab.reminders.badge") }

    static var sensitiveMedia_originalTitle: String { t("sensitiveMedia.original.title") }

    static var sensitiveMedia_unlockToView: String { t("sensitiveMedia.unlockToView") }

    static var sensitiveMedia_loadFailed: String { t("sensitiveMedia.loadFailed") }

    static var caregiverTitle: String { t("caregiver.title") }

    static var caregiverEmpty: String { t("caregiver.empty") }

    static var caregiverEmptyHint: String { t("caregiver.emptyHint") }

    static var caregiverAlertTitle: String { t("caregiver.alertTitle") }

    static var caregiverAlertConfirm: String { t("caregiver.alertConfirm") }

    static var disclosureTitle: String { t("disclosure.title") }

    static var disclosureAcknowledge: String { t("disclosure.acknowledge") }

    static var ncTitle: String { t("nc.title") }

    static var ncSectionPending: String { t("nc.section.pending") }

    static var ncSectionAppointment: String { t("nc.section.appointment") }

    static var ncSectionExpiry: String { t("nc.section.expiry") }

    static var ncSectionAlert: String { t("nc.section.alert") }

    static var ncSectionOcr: String { t("nc.section.ocr") }

    static var ncNextActionDose: String { t("nc.nextAction.dose") }

    static var ncConfirmDose: String { t("nc.confirmDose") }

    static var ncEmpty: String { t("nc.empty") }

    static var ncEmptyHint: String { t("nc.emptyHint") }

    static var languageTitle: String { t("language.title") }

    static var languageFooter: String { t("language.footer") }

    static var voiceLangTitle: String { t("voiceLang.title") }

    static var voiceLangInputSection: String { t("voiceLang.inputSection") }

    static var voiceLangInputHint: String { t("voiceLang.inputHint") }

    static var voiceLangOutputSection: String { t("voiceLang.outputSection") }

    static var voiceLangOutputHint: String { t("voiceLang.outputHint") }

    static var voiceLangBestEffort: String { t("voiceLang.bestEffort") }

    static var voiceLangFallback: String { t("voiceLang.fallback") }

    static var voiceLangMix: String { t("voiceLang.mix") }

    static var voiceLangMixHint: String { t("voiceLang.mixHint") }

    static var retry: String { t("common.retry") }

    static var knowledgeTitle: String { t("knowledge.title") }

    static var knowledgeAdvice: String { t("knowledge.advice") }

    static var knowledgeAdviceBadge: String { t("knowledge.adviceBadge") }

    static var knowledgeNoAdvice: String { t("knowledge.noAdvice") }

    static var knowledgeStorage: String { t("knowledge.storage") }

    static var knowledgeStorageHint: String { t("knowledge.storageHint") }

    static var knowledgeCaution: String { t("knowledge.caution") }

    static var knowledgeCautionText: String { t("knowledge.cautionText") }

    static var problemTitle: String { t("problem.title") }

    static var problemEmpty: String { t("problem.empty") }

    static var problemEmptyHint: String { t("problem.emptyHint") }

    static var problemCreateTitle: String { t("problem.createTitle") }

    static var problemSaveFailedHint: String { t("problem.saveFailedHint") }

    static var problemNamePlaceholder: String { t("problem.namePlaceholder") }

    static var problemMerge: String { t("problem.merge") }

    static var problemMergeTitle: String { t("problem.mergeTitle") }

    static var problemMergeHint: String { t("problem.mergeHint") }

    static var problemArchive: String { t("problem.archive") }

    static var problemUnarchive: String { t("problem.unarchive") }

    static var prepTitle: String { t("prep.title") }

    static var prepPatient: String { t("prep.patient") }

    static var prepBloodType: String { t("prep.bloodType") }

    static var prepMeds: String { t("prep.meds") }

    static var prepObservations: String { t("prep.observations") }

    static var prepQuestions: String { t("prep.questions") }

    static var prepNoData: String { t("prep.noData") }

    static var prepNoQuestions: String { t("prep.noQuestions") }

    static var prepDisclaimer: String { t("prep.disclaimer") }

    static var questionTitle: String { t("question.title") }

    static var questionPlaceholder: String { t("question.placeholder") }

    static var questionMarkAsked: String { t("question.markAsked") }

    static var docLibraryTitle: String { t("docLibrary.title") }

    static var docLibraryEmpty: String { t("docLibrary.empty") }

    static var docLibraryEmptyHint: String { t("docLibrary.emptyHint") }

    static var docLibraryUntitled: String { t("docLibrary.untitled") }

    static func docTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return t("docLibrary.untitled") }
        return title
    }

    static var scanRegionTitle: String { t("scanRegion.title") }

    static var scanRegionHint: String { t("scanRegion.hint") }

    static var scanRegionReset: String { t("scanRegion.reset") }

    static var scanRegionConfirm: String { t("scanRegion.confirm") }

    static var scanRegionAutoDetectFailed: String { t("scanRegion.autoDetectFailed") }

    static var scanRegionCorrectionFailed: String { t("scanRegion.correctionFailed") }

    static var pendingCardReasonOcrMissing: String { t("pendingCard.reasonOcrMissing") }

    static var pendingCardRawText: String { t("pendingCard.rawText") }

    static var docTypeLabelVaccineRecord: String { t("docTypeLabel.vaccineRecord") }

    static var docTypeLabelDiagnosisProof: String { t("docTypeLabel.diagnosisProof") }

    static var docTypeLabelOther: String { t("docTypeLabel.other") }

    static var sharedFieldsTitle: String { t("sharedFields.title") }

    static var sharedFieldsHint: String { t("sharedFields.hint") }

    static var sharedFieldsContinue: String { t("sharedFields.continue") }

    static var sharedFieldsReasonRepeated: String { t("sharedFields.reason.repeated") }

    static var sharedFieldsReasonCritical: String { t("sharedFields.reason.critical") }

    static func entityCardKindName(_ kind: String) -> String {
        let key = "entityCard.kind.\(kind)"
        let value = t(key)
        return value == key ? kind : value
    }

    static var pendingCardResume: String { t("pendingCard.resume") }

    static var pendingCardViewSource: String { t("pendingCard.viewSource") }

    static var pendingCardDiscard: String { t("pendingCard.discard") }

    static var pendingCardNotFound: String { t("pendingCard.notFound") }

    static func templateFieldLabel(_ key: String) -> String {
        let l10nKey = "field.\(key)"
        let value = t(l10nKey)
        return value == l10nKey ? key : value
    }

    static var ocConfirmCardAll: String { t("oc.confirm.cardAll") }

    static var ocFieldDept: String { t("oc.field.dept") }

    static var ocFieldReportDate: String { t("oc.field.reportDate") }

    static var ocFieldLabItem: String { t("oc.field.labItem") }

    static var ocFieldReferenceRange: String { t("oc.field.referenceRange") }

    static var ocFieldChiefComplaint: String { t("oc.field.chiefComplaint") }

    static var ocFieldDiagnosis: String { t("oc.field.diagnosis") }

    static var ocFieldTreatment: String { t("oc.field.treatment") }

    static var healthProblemOfferTitle: String { t("healthProblem.offer.title") }

    static var healthProblemOfferBody: String { t("healthProblem.offer.body") }

    static var healthProblemCreate: String { t("healthProblem.create") }

    static func voiceIntentName(_ key: String) -> String { t("voiceIntent.\(key)") }

    static var voicePanelAutoHint: String { t("voicePanel.autoHint") }

    static var voicePanelEditHint: String { t("voicePanel.editHint") }

    static var voicePanelConfirm: String { t("voicePanel.confirm") }

    static var voicePanelClearTitle: String { t("voicePanel.clearTitle") }

    static var voicePanelClear: String { t("voicePanel.clear") }

    static var voicePanelClearLast: String { t("voicePanel.clearLast") }

    static var voicePanelClearAll: String { t("voicePanel.clearAll") }

    static var voiceConfirmJudgedTarget: String { t("voiceConfirm.judgedTarget") }

    static var voiceConfirmCandidates: String { t("voiceConfirm.candidates") }

    static var imageInputNoText: String { t("image_input.noText") }

    static var prescriptionFieldHospital: String { t("prescription.field.hospital") }

    static var prescriptionFieldDoctor: String { t("prescription.field.doctor") }

    static var prescriptionFieldFrequency: String { t("prescription.field.frequency") }

    static var prescriptionFieldDosage: String { t("prescription.field.dosage") }

    static var prescriptionFieldDrugName: String { t("prescription.field.drugName") }

    static var prescriptionFieldOther: String { t("prescription.field.other") }

    static var prescriptionLineTitle: String { t("prescriptionLine.title") }

    static var prescriptionLineSection: String { t("prescriptionLine.section") }

    static var prescriptionLineNone: String { t("prescriptionLine.none") }

    static var prescriptionLineUnavailable: String { t("prescriptionLine.unavailable") }

    static var prescriptionLineHeader: String { t("prescriptionLine.header") }

    static var prescriptionLineNoSource: String { t("prescriptionLine.noSource") }

    static func prescriptionTypeName(_ raw: String) -> String {
        let key = "prescription.type.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static func diagnosisTypeName(_ raw: String) -> String {
        let key = "diagnosis.type.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static func examReportTypeName(_ raw: String) -> String {
        let key = "exam.type.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static var labReportSamplesSection: String { t("labReport.samplesSection") }

    static var labReportResultsSection: String { t("labReport.resultsSection") }

    static var labReportNoRows: String { t("labReport.noRows") }

    static var hospitalizationEpisode: String { t("hospitalization.episode") }

    static var profileSuggestionTitle: String { t("profileSuggestion.title") }

    static var profileSuggestionHint: String { t("profileSuggestion.hint") }

    static var profileSuggestionAccept: String { t("profileSuggestion.accept") }

    static var profileSuggestionSkip: String { t("profileSuggestion.skip") }

    static var profileSuggestionSkipAll: String { t("profileSuggestion.skipAll") }

    static var profileSuggestionDone: String { t("profileSuggestion.done") }

    static var profileSuggestionApplied: String { t("profileSuggestion.applied") }

    static var profileSuggestionExisting: String { t("profileSuggestion.existing") }

    static var profileSuggestionSkipped: String { t("profileSuggestion.skipped") }

    static var profileSuggestionFailed: String { t("profileSuggestion.failed") }

    static var profileSuggestionSeverityUnset: String { t("profileSuggestion.severityUnset") }

    static func profileSuggestionKindName(_ raw: String) -> String {
        let key = "profileSuggestion.kind.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static var timezoneChangedTitle: String { t("timezone.changed.title") }

    static var timezoneChangedBody: String { t("timezone.changed.body") }

    static var ncArchive: String { t("nc.archive") }

    static var showcaseTitle: String { t("showcase.title") }

    static var showcaseExit: String { t("showcase.exit") }

    static var showcaseEmpty: String { t("showcase.empty") }

    static var showcaseUnlockReason: String { t("showcase.unlockReason") }

    static var remchTitle: String { t("remch.title") }

    static var remchSectionHint: String { t("remch.sectionHint") }

    static var remchSectionFooter: String { t("remch.sectionFooter") }

    static var remchMeds: String { t("remch.meds") }

    static var remchApts: String { t("remch.apts") }

    static var remchExam: String { t("remch.exam") }

    static var remchExpiry: String { t("remch.expiry") }

    static var remchAlert: String { t("remch.alert") }

    static var remchBackup: String { t("remch.backup") }

    static var remchLocal: String { t("remch.local") }

    static var remchRing: String { t("remch.ring") }

    static var remchInApp: String { t("remch.inApp") }

    static var remchBannerToggle: String { t("remch.bannerToggle") }

    static var remchBannerFooter: String { t("remch.bannerFooter") }

    static var bannerDoseDue: String { t("banner.doseDue") }

    static var bannerConfirm: String { t("banner.confirm") }

    static var bannerLater: String { t("banner.later") }

    static var occlusionTitle: String { t("occlusion.title") }

    static var occlusionSkip: String { t("occlusion.skip") }

    static var occlusionDone: String { t("occlusion.done") }

    static var filterAll: String { t("filter.all") }

    static var filter3d: String { t("filter.3d") }

    static var filter72h: String { t("filter.72h") }

    static var voiceLangMixedToggle: String { t("voicelang.mixedToggle") }

    static var voiceLangMixedHint: String { t("voicelang.mixedHint") }

    static func voiceLangT2Title(_ name: String) -> String { t("voicelang.t2Title").replacingOccurrences(of: "%@", with: name) }

    static var voiceLangT2Point1: String { t("voicelang.t2Point1") }

    static var voiceLangT2Point2: String { t("voicelang.t2Point2") }

    static var voiceLangT2Point3: String { t("voicelang.t2Point3") }

    static var gradeBadgeA: String { t("gradebadge.a") }

    static var gradeBadgeB: String { t("gradebadge.b") }

    static var gradeBadgeC: String { t("gradebadge.c") }

    static var gradeBadgeD: String { t("gradebadge.d") }

    static var gradeBadgeE: String { t("gradebadge.e") }

    static var gradeBadgePending: String { t("gradebadge.pending") }

    static var reportIssueKind: String { t("report.issueKind") }

    static var reportIssueField: String { t("report.issueField") }

    static var reportIssueFieldAll: String { t("report.issueFieldAll") }

    static var reportIssueNote: String { t("report.issueNote") }

    static var reportIssueNoteHint: String { t("report.issueNoteHint") }

    static var reportIssueMinimal: String { t("report.issueMinimal") }

    static var reportIssueSubmit: String { t("report.issueSubmit") }

    static var reportIssueSubmitted: String { t("report.issueSubmitted") }

    static var reportIssueFieldWrong: String { t("report.issueFieldWrong") }

    static var reportIssueMissing: String { t("report.issueMissing") }

    static var reportIssueLayout: String { t("report.issueLayout") }

    static var reportIssueEngine: String { t("report.issueEngine") }

    static var prepExport: String { t("prep.export") }

    static var prepTrendSnapshot: String { t("prep.trendSnapshot") }

    static var ocrQueueTitle: String { t("ocrQueue.title") }

    static var ocrQueueEmpty: String { t("ocrQueue.empty") }

    static var ocrQueueEmptyHint: String { t("ocrQueue.emptyHint") }

    static var ocrQueueHint: String { t("ocrQueue.hint") }

    static var ocrQueue72h: String { t("ocrQueue.72h") }

    static var ocrQueueJumpSource: String { t("ocrQueue.jumpSource") }

    static var aiFeedbackUseful: String { t("aiFeedback.useful") }

    static var aiFeedbackUseless: String { t("aiFeedback.useless") }

    static var aiFeedbackCitationError: String { t("aiFeedback.citationError") }

    static var aiFeedbackDanger: String { t("aiFeedback.danger") }

    static var aiFeedbackMore: String { t("aiFeedback.more") }

    static var authOcrLabel: String { t("auth.ocr") }

    static var authAILabel: String { t("auth.ai") }

    static var authFamilyLabel: String { t("auth.family") }

    static var authSharingLabel: String { t("auth.sharing") }

    static var authCloudBackupLabel: String { t("auth.cloudBackup") }

    static var authAnonymizedLabel: String { t("auth.anonymized") }

    static var authHealthLabel: String { t("auth.health") }

    static var authVoiceDictationLabel: String { t("auth.voiceDictation") }

    static var lifecycleSingle: String { t("lifecycle.single") }

    static var lifecycleSingleHint: String { t("lifecycle.singleHint") }

    static var lifecycleMember: String { t("lifecycle.member") }

    static var lifecycleMemberHint: String { t("lifecycle.memberHint") }

    static var lifecycleClearAll: String { t("lifecycle.clearAll") }

    static var lifecycleClearHint: String { t("lifecycle.clearHint") }

    static var lifecycleClearButton: String { t("lifecycle.clearButton") }

    static var lifecycleClearImpact: String { t("lifecycle.clearImpact") }

    static var lifecycleResetSettings: String { t("lifecycle.resetSettings") }

    static var lifecycleResetSettingsHint: String { t("lifecycle.resetSettingsHint") }

    static var lifecycleResetSettingsImpact: String { t("lifecycle.resetSettingsImpact") }

    static var lifecycleLogout: String { t("lifecycle.logout") }

    static var lifecycleLogoutHint: String { t("lifecycle.logoutHint") }

    static var feedbackTitle: String { t("feedback.title") }

    static var feedbackCategory: String { t("feedback.category") }

    static func feedbackCategoryName(_ i: Int) -> String { t("feedback.category.\(i)") }

    static var feedbackDetail: String { t("feedback.detail") }

    static var feedbackDetailPlaceholder: String { t("feedback.detailPlaceholder") }

    static var feedbackAttachments: String { t("feedback.attachments") }

    static var feedbackAttachScreenshot: String { t("feedback.attachScreenshot") }

    static var feedbackAttachOriginal: String { t("feedback.attachOriginal") }

    static var feedbackAttachMedia: String { t("feedback.attachMedia") }

    static var feedbackAttachmentHint: String { t("feedback.attachmentHint") }

    static var feedbackSubmit: String { t("feedback.submit") }

    static var feedbackSubmitted: String { t("feedback.submitted") }

    static var fr24_markDelivered: String { t("fr24.markDelivered") }

    static var fr24_offlineNote: String { t("fr24.offlineNote") }

    static var voicePanelTitle: String { t("voicePanel.title") }

    static var voicePanelHint: String { t("voicePanel.hint") }

    static var voicePanelStart: String { t("voicePanel.start") }

    static var routeComingSoon: String { t("route.comingSoon") }

    static var routeComingSoonHint: String { t("route.comingSoonHint") }

    static var routeEntityGone: String { t("route.entityGone") }

    static var routeEntityGoneHint: String { t("route.entityGoneHint") }

    static var startupDegradedTitle: String { t("startup.degradedTitle") }

    static var startupDatabaseMissing: String { t("startup.databaseMissing") }

    static var startupLoadFailed: String { t("startup.loadFailed") }

    static var medicalIDTitle: String { t("medicalID.title") }

    static var medicalIDStep1: String { t("medicalID.step1") }

    static var medicalIDStep1Hint: String { t("medicalID.step1Hint") }

    static var medicalIDStep2: String { t("medicalID.step2") }

    static var medicalIDStep2Hint: String { t("medicalID.step2Hint") }

    static var medicalIDStep3: String { t("medicalID.step3") }

    static var medicalIDStep3Hint: String { t("medicalID.step3Hint") }

    static var medicalIDOpenHealth: String { t("medicalID.openHealth") }

    static var medicalIDNote: String { t("medicalID.note") }

    static var appointmentAdd: String { t("appointment.add") }

    static var problemAdd: String { t("problem.add") }

    static var questionAdd: String { t("question.add") }

    static var notificationCenterTitle: String { t("notification.center") }

    static func conclusionTypeName(_ raw: String) -> String {
        let key = "conclusion.type.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static func treatmentTypeName(_ raw: String) -> String {
        let key = "treatment.type.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static func appointmentPurposeName(_ raw: String) -> String {
        let key = "appointment.purpose.\(raw)"
        let value = t(key)
        return value == key ? raw : value
    }

    static func docTypeName(_ key: String) -> String {
        let l10nKey = "docType.\(key)"
        let value = t(l10nKey)
        return value == l10nKey ? key : value
    }

    static func docTypeName(_ key: DocumentTypeKey) -> String { docTypeName(key.rawValue) }

    static func legacyDocTypeLabelKey(forLabel label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // (L10n 键, 旧标签键)——标签键 = DocumentTypeKey.legacyLabelKeys 的键，或直接是稳定键 rawValue
        let sources: [(String, String)] = [
            ("docTypeLabel.outpatient", "outpatient"), ("docTypeLabel.inpatient", "inpatient"), ("docTypeLabel.labReport", "labReport"),
            ("docTypeLabel.imageReport", "imageReport"), ("docTypeLabel.prescription", "prescription"), ("docTypeLabel.payment", "payment"),
            ("docTypeLabel.dischargeSummary", "dischargeSummary"), ("docTypeLabel.diagnosisProof", "diagnosisProof"),
            ("docTypeLabel.vaccineRecord", "vaccineRecord"), ("docTypeLabel.checkupReport", "checkupReport"),
            ("docTypeLabel.pathologyReport", "pathologyReport"), ("docTypeLabel.surgeryRecord", "surgeryRecord"),
            ("docTypeLabel.allergyRecord", "allergyRecord"), ("docTypeLabel.other", "other"), ("docTypeLabel.custom", "custom"),
            // DocumentsState.docTypeLabel(forStableKey:) 曾用的七个非 docTypeLabel.* 键
            ("doc.type.prescription", "prescription"), ("doc.type.report", "lab_report"), ("doc.type.record", "outpatient_record"),
            ("claim.type.invoice", "invoice"), ("entityCard.kind.medication", "medication_label"),
        ]
        for lang in supportedLocalizations {
            guard let bundle = bundle(forLanguage: lang) else { continue }
            for (l10nKey, labelKey) in sources where bundle.localizedString(forKey: l10nKey, value: l10nKey, table: nil) == trimmed {
                return labelKey
            }
            for key in DocumentTypeKey.allCases {
                let l10nKey = "docType.\(key.rawValue)"
                let value = bundle.localizedString(forKey: l10nKey, value: l10nKey, table: nil)
                if value != l10nKey, value == trimmed { return key.rawValue }
            }
        }
        return nil
    }

    static var parentDraftTitle: String { t("parentDraft.title") }

    static var parentDraftHint: String { t("parentDraft.hint") }

    static var parentDraftNewEncounter: String { t("parentDraft.newEncounter") }

    static var parentDraftNewHealthExam: String { t("parentDraft.newHealthExam") }

    static var parentDraftUseExisting: String { t("parentDraft.useExisting") }

    static var parentDraftDateRequired: String { t("parentDraft.dateRequired") }

    static var parentDraftUnconfirmed: String { t("parentDraft.unconfirmed") }

    static var healthExamTitle: String { t("healthExam.title") }

    static var healthExamHeader: String { t("healthExam.header") }

    static var healthExamGeneral: String { t("healthExam.general") }

    static var healthExamReports: String { t("healthExam.reports") }

    static var healthExamConclusions: String { t("healthExam.conclusions") }

    static var healthExamGuidance: String { t("healthExam.guidance") }

    static var healthExamOverall: String { t("healthExam.overall") }

    static var healthExamNotFound: String { t("healthExam.notFound") }

    static var healthExamNoReports: String { t("healthExam.noReports") }

    static var healthExamNoConclusions: String { t("healthExam.noConclusions") }

    static var healthExamSource: String { t("healthExam.source") }

    static var healthExamSamples: String { t("healthExam.samples") }

    static var healthExamDisclaimer: String { t("healthExam.disclaimer") }
}
