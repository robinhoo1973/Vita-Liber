// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var backupTitle: String { t("backup.title") }

    static var backupCreate: String { t("backup.create") }

    static var backupRestore: String { t("backup.restore") }

    static var backupNotSignedIn: String { t("backup.degrade.notSignedIn") }

    static var backupNoSpace: String { t("backup.degrade.noSpace") }

    static var backupCreateFailed: String { t("backup.degrade.createFailed") }

    static var backupChecksumFailed: String { t("backup.degrade.checksum") }

    static var backupRestoreFailed: String { t("backup.degrade.restoreFailed") }

    static var backupConflictDetected: String { t("backup.degrade.conflict") }

    static var backupConflictTitle: String { t("backup.conflict.title") }

    static var backupConflictChoice: String { t("backup.conflict.choice") }

    static var backupConflictKeep: String { t("backup.conflict.keep") }

    static var backupConflictAdopt: String { t("backup.conflict.adopt") }

    static var backupConflictCoexist: String { t("backup.conflict.coexist") }

    static var backupConflictApply: String { t("backup.conflict.apply") }

    static var backupConflictHint: String { t("backup.conflict.hint") }

    static var backupConflictKindProfile: String { t("backup.conflict.kind.profile") }

    static var backupConflictKindConsent: String { t("backup.conflict.kind.consent") }

    static var backupConflictKindDocument: String { t("backup.conflict.kind.document") }

    static var backupConflictKindRecord: String { t("backup.conflict.kind.record") }

    static var backupUnlockReason: String { t("backup.unlockReason") }

    static var backupExportConfirmTitle: String { t("backup.exportConfirm.title") }

    static var backupExportConfirmBody: String { t("backup.exportConfirm.body") }

    static var backupRestoreConfirmTitle: String { t("backup.restoreConfirm.title") }

    static var backupRestoreConfirmBody: String { t("backup.restoreConfirm.body") }

    static var helpcard_title: String { t("helpcard.title") }

    static var helpcard_selectHint: String { t("helpcard.selectHint") }

    static var helpcard_photoOptIn: String { t("helpcard.photoOptIn") }

    static var helpcard_contentNote: String { t("helpcard.contentNote") }

    static var helpcard_generate: String { t("helpcard.generate") }

        static var settings_authTitle: String { t("settings.authTitle") }

    static var settings_habits: String { t("settings.habits") }

    static var settings_pro: String { t("settings.pro") }

    static var settings_privacy: String { t("settings.privacy") }

    static var privacyAuthTitle: String { t("privacyAuth.title") }

    static var privacyAuthFooter: String { t("privacyAuth.footer") }

    static var privacyAuthExplainers: String { t("privacyAuth.explainers") }

    static var privacyAuthStorageNote: String { t("privacyAuth.storageNote") }

    static var privacyAuthAnonymizedNote: String { t("privacyAuth.anonymizedNote") }

    static var privacyAuthLocationNote: String { t("privacyAuth.locationNote") }

    static var privacyAuthOcrTitle: String { t("privacyAuth.ocr.title") }

    static var privacyAuthOcrSub: String { t("privacyAuth.ocr.sub") }

    static var privacyAuthAITitle: String { t("privacyAuth.ai.title") }

    static var privacyAuthAISub: String { t("privacyAuth.ai.sub") }

    static var privacyAuthFamilyTitle: String { t("privacyAuth.family.title") }

    static var privacyAuthFamilySub: String { t("privacyAuth.family.sub") }

    static var privacyAuthSharingTitle: String { t("privacyAuth.sharing.title") }

    static var privacyAuthSharingSub: String { t("privacyAuth.sharing.sub") }

    static var privacyAuthBackupTitle: String { t("privacyAuth.backup.title") }

    static var privacyAuthBackupSub: String { t("privacyAuth.backup.sub") }

    static var privacyAuthHealthTitle: String { t("privacyAuth.health.title") }

    static var privacyAuthHealthSub: String { t("privacyAuth.health.sub") }

    static var privacyAuthVoiceTitle: String { t("privacyAuth.voice.title") }

    static var privacyAuthVoiceSub: String { t("privacyAuth.voice.sub") }

    static var privacyAuthWriteBackTitle: String { t("privacyAuth.writeBack.title") }

    static var privacyAuthWriteBackSub: String { t("privacyAuth.writeBack.sub") }

    static var privacyAuthAIDisabledTitle: String { t("privacyAuth.ai.disabledTitle") }

    static var privacyAuthAIDisabledBody: String { t("privacyAuth.ai.disabledBody") }

    static var privacyAuthOpen: String { t("privacyAuth.open") }

    static var privacyAuthSharingDisabled: String { t("privacyAuth.sharing.disabled") }

    static var privacyAuthFamilyDisabled: String { t("privacyAuth.family.disabled") }

    static var privacyAuthFamilyDisabledBody: String { t("privacyAuth.family.disabledBody") }

    static var privacyAuthVoiceDisabled: String { t("privacyAuth.voice.disabled") }

    static var privacyAuthBackupDisabled: String { t("privacyAuth.backup.disabled") }

    static var settings_about: String { t("settings.about") }

    static var settings_remindAdvance: String { t("settings.remindAdvance") }

    static var settings_snooze: String { t("settings.snooze") }

    static var settings_quietHours: String { t("settings.quietHours") }

    static var settings_disclaimer: String { t("settings.disclaimer") }

    static var settings_proUpgrade: String { t("settings.proUpgrade") }

    static var settings_audit: String { t("settings.audit") }

    static var settings_restoreDefaults: String { t("settings.restoreDefaults") }

    static var settings_help: String { t("settings.help") }

    static var settings_careMode: String { t("settings.careMode") }

    static var settings_voiceEntry: String { t("settings.voiceEntry") }

    static var settings_appearance: String { t("settings.appearance") }

    static var settings_themeLight: String { t("settings.themeLight") }

    static var settings_themeDark: String { t("settings.themeDark") }

    static var settings_themeSystem: String { t("settings.themeSystem") }

    static var settings_highContrast: String { t("settings.highContrast") }

    static var settings_highContrastFooter: String { t("settings.highContrastFooter") }

    static var settings_highContrastForced: String { t("settings.highContrastForced") }

    static func settingsRemindAdvance(_ v: String) -> String {
        t("settings.remindAdvance").replacingOccurrences(of: "%@", with: v)
    }

    static func settingsSnooze(_ v: String) -> String {
        t("settings.snooze").replacingOccurrences(of: "%@", with: v)
    }

    static var help_appName: String { t("help.appName") }

    static var help_tagline: String { t("help.tagline") }

    static var help_title: String { t("help.title") }

    static var help_faqPlaceholder: String { t("help.faqPlaceholder") }

    static var help_disclaimer: String { t("help.disclaimer") }

    static var help_version: String { t("help.version") }

    static var help_privacyPlaceholder: String { t("help.privacyPlaceholder") }

    static var pay_busy: String { t("pay.busy") }

    static var pay_restore: String { t("pay.restore") }

    static var pay_valueProp: String { t("pay.valueProp") }

    static var payTrustCopy: String { t("pay.trustCopy") }

    static var pay_buy: String { t("pay.buy") }

    static var payProYearly: String { t("pay.proYearly") }

    static var payProYearlyPrice: String { t("pay.proYearlyPrice") }

    static var payProYearlyDetail: String { t("pay.proYearlyDetail") }

    static var payProMonthly: String { t("pay.proMonthly") }

    static var payProMonthlyPrice: String { t("pay.proMonthlyPrice") }

    static var payProMonthlyDetail: String { t("pay.proMonthlyDetail") }

    static var payAddonPack: String { t("pay.addonPack") }

    static var payAddonPrice: String { t("pay.addonPrice") }

    static var payAddonDetail: String { t("pay.addonDetail") }

    static var proOutputTitle: String { t("pro.outputTitle") }

    static var proOutputPreview: String { t("pro.outputPreview") }

    static var proFeatureDoctorSummary: String { t("pro.featureDoctorSummary") }

    static var proFeatureDoctorSummaryDesc: String { t("pro.featureDoctorSummaryDesc") }

    static var proFeatureClaimExport: String { t("pro.featureClaimExport") }

    static var proFeatureClaimExportDesc: String { t("pro.featureClaimExportDesc") }

    static var proFeatureFamilyCabinet: String { t("pro.featureFamilyCabinet") }

    static var proFeatureFamilyCabinetDesc: String { t("pro.featureFamilyCabinetDesc") }

    static var proFeatureInsurancePack: String { t("pro.featureInsurancePack") }

    static var proFeatureInsurancePackDesc: String { t("pro.featureInsurancePackDesc") }

    static var proFeatureCustomThreshold: String { t("pro.featureCustomThreshold") }

    static var proFeatureCustomThresholdDesc: String { t("pro.featureCustomThresholdDesc") }

    static var proFeatureDispenseTemplate: String { t("pro.featureDispenseTemplate") }

    static var proFeatureDispenseTemplateDesc: String { t("pro.featureDispenseTemplateDesc") }

    static var searchSensitive: String { t("search.sensitiveBadge") }

    static var helpcard_defaultFilename: String { t("helpcard.defaultFilename") }

    static var backupScopeNote: String { t("backup.scopeNote") }

    static func backupExportedName(_ name: String) -> String {
        t("backup.exportedName").replacingOccurrences(of: "%@", with: name)
    }

    static func backupChecksum(_ digest: String) -> String {
        t("backup.checksum").replacingOccurrences(of: "%@", with: digest)
    }

    static var backupRestored: String { t("backup.restored") }

    static func proPreviewNote(_ product: String) -> String {
        t("pro.previewNote").replacingOccurrences(of: "%@", with: product)
    }

    static var helpcardCardRemainingPrefix: String { t("helpcard.cardRemainingPrefix") }

    static var helpcardCardStoragePrefix: String { t("helpcard.cardStoragePrefix") }

    static var helpcardCardExpiryPrefix: String { t("helpcard.cardExpiryPrefix") }

    static var helpcardPhotoSection: String { t("helpcard.photoSection") }

    static var helpStatusChecking: String { t("help.status.checking") }

    static var helpStatusAuthorized: String { t("help.status.authorized") }

    static var helpStatusDenied: String { t("help.status.denied") }

    static var helpStatusNotRequested: String { t("help.status.notRequested") }

    static var helpStatusUnknown: String { t("help.status.unknown") }

    static var helpStatusProvisional: String { t("help.status.provisional") }

    static var helpCenterTitle: String { t("help.center.title") }

    static var helpDiagPermission: String { t("help.diag.permission") }

    static var helpDiagReminder: String { t("help.diag.reminder") }

    static var helpDiagDataHealth: String { t("help.diag.dataHealth") }

    static var helpDiagSystem: String { t("help.diag.system") }

    static var helpDiagSystemHint: String { t("help.diag.systemHint") }

    static var helpAboutLegal: String { t("help.about.legal") }

    static var helpPermSection: String { t("help.perm.section") }

    static var helpPermCamera: String { t("help.perm.camera") }

    static var helpPermMic: String { t("help.perm.mic") }

    static var helpPermNotification: String { t("help.perm.notification") }

    static var helpPermOpenSettings: String { t("help.perm.openSettings") }

    static var helpPermDeniedHint: String { t("help.perm.deniedHint") }

    static var helpFaceIDRequiresDevice: String { t("help.faceID.requiresDevice") }

    static var helpReminderSection: String { t("help.reminder.section") }

    static var helpReminderPermission: String { t("help.reminder.permission") }

    static var helpReminderTodaySection: String { t("help.reminder.todaySection") }

    static var helpReminderPendingDoses: String { t("help.reminder.pendingDoses") }

    static var helpReminderTodaySlots: String { t("help.reminder.todaySlots") }

    static var helpReminderDeniedHint: String { t("help.reminder.deniedHint") }

    static var helpDataDbSection: String { t("help.data.dbSection") }

    static var helpDataIntegrity: String { t("help.data.integrity") }

    static var helpDataNormal: String { t("help.data.normal") }

    static var helpDataCorrupt: String { t("help.data.corrupt") }

    static var helpDataStorageSection: String { t("help.data.storageSection") }

    static var helpDataDbSize: String { t("help.data.dbSize") }

    static var helpDataCalculating: String { t("help.data.calculating") }

    static var helpDataBackupSection: String { t("help.data.backupSection") }

    static var helpDataLastBackup: String { t("help.data.lastBackup") }

    static var helpDataNoBackup: String { t("help.data.noBackup") }

    static var helpDataTitle: String { t("help.data.title") }

    static var helpAboutLicenses: String { t("help.about.licenses") }

    static var helpAboutSection: String { t("help.about.section") }

    static var helpLegalSection: String { t("help.legal.section") }

    static var helpTermsTitle: String { t("help.terms.title") }

    static var helpSection: String { t("help.section") }

    static var settings_offlineNote: String { t("settings.offlineNote") }

    static var searchTitle: String { t("search.title") }

    static var searchPlaceholder: String { t("search.placeholder") }

    static var searchPlaceholderHint: String { t("search.placeholderHint") }

    static var searchLoosenHint: String { t("search.loosenHint") }

    static var searchClear: String { t("search.clear") }

    static var searchLoadFailed: String { t("search.failed") }

    static var searchRetry: String { t("search.retry") }

    static var searchGroupDocs: String { t("search.group.docs") }

    static var searchGroupHealthData: String { t("search.group.healthData") }

    static var searchHealthDataHint: String { t("search.healthData.hint") }

    static var searchGroupObservations: String { t("search.group.observations") }

    static var searchGroupMeds: String { t("search.group.meds") }

    static var searchObsLocked: String { t("search.obsLocked") }

    static var settings_gateGrace: String { t("settings.gateGrace") }

    static var settings_autoLock: String { t("settings.autoLock") }

    static var settings_grace0: String { t("settings.grace0") }

    static var settings_grace15: String { t("settings.grace15") }

    static var settings_grace60: String { t("settings.grace60") }

    static var helpcardPreviewTitle: String { t("helpcard.previewTitle") }

    static var helpcardPreviewContinue: String { t("helpcard.previewContinue") }

    static var helpcardPreviewHint: String { t("helpcard.previewHint") }

    static var prefDateFormat: String { t("pref.dateFormat") }

    static var prefDateFormatPending: String { t("pref.dateFormatPending") }

    static var prefDateFormatYMD: String { t("pref.dateFormatYMD") }

    static var prefDateFormatMD: String { t("pref.dateFormatMD") }

    static var prefDateFormatISO: String { t("pref.dateFormatISO") }

    static var prefSpeechRate: String { t("pref.speechRate") }

    static var prefSpeechRateSlow: String { t("pref.speechRate.slow") }

    static var prefSpeechRateNormal: String { t("pref.speechRate.normal") }

    static var prefSpeechRateFast: String { t("pref.speechRate.fast") }

    static var prefSpeechRateHint: String { t("pref.speechRate.hint") }

    static var helpTutorialTitle: String { t("help.tutorialTitle") }

    static var helpTopicGettingStarted: String { t("help.topicGettingStarted") }

    static var helpTopicImportOcr: String { t("help.topicImportOcr") }

    static var helpTopicReminders: String { t("help.topicReminders") }

    static var helpTopicPrivacy: String { t("help.topicPrivacy") }

    static var helpTopicCare: String { t("help.topicCare") }

    static var helpTopicBackup: String { t("help.topicBackup") }

    static var helpTopicVoice: String { t("help.topicVoice") }

    static var helpGettingStarted1: String { t("help.gettingStarted1") }

    static var helpGettingStarted2: String { t("help.gettingStarted2") }

    static var helpImportOcr1: String { t("help.importOcr1") }

    static var helpImportOcr2: String { t("help.importOcr2") }

    static var helpReminders1: String { t("help.reminders1") }

    static var helpReminders2: String { t("help.reminders2") }

    static var helpPrivacy1: String { t("help.privacy1") }

    static var helpPrivacy2: String { t("help.privacy2") }

    static var helpCare1: String { t("help.care1") }

    static var helpCare2: String { t("help.care2") }

    static var helpBackup1: String { t("help.backup1") }

    static var helpBackup2: String { t("help.backup2") }

    static var helpVoice1: String { t("help.voice1") }

    static var helpVoice2: String { t("help.voice2") }

    static var helpVoiceSpeak: String { t("help.voiceSpeak") }

    static var exportWizardTitle: String { t("export.wizard.title") }

    static var exportScope: String { t("export.scope") }

    static var exportScopeAll: String { t("export.scope.all") }

    static var exportScopeDateRange: String { t("export.scope.dateRange") }

    static var exportScopeDoctorSummary: String { t("export.scope.doctorSummary") }

    static var exportDateFrom: String { t("export.dateFrom") }

    static var exportDateTo: String { t("export.dateTo") }

    static var exportContent: String { t("export.content") }

    static var exportIncludeNotes: String { t("export.includeNotes") }

    static var exportWatermark: String { t("export.watermark") }

    static var exportPrivacyHint: String { t("export.privacyHint") }

    static var exportStart: String { t("export.start") }

    static var exportUnlockReason: String { t("export.unlockReason") }

    static var exportCancel: String { t("export.cancel") }

    static var exportCancelled: String { t("export.cancelled") }

    static var exportFailed: String { t("export.failed") }

    static var exportRetry: String { t("export.retry") }

    static var exportShare: String { t("export.share") }

    static var backupReminderTitle: String { t("backup.reminder.title") }

    static var backupReminderBody: String { t("backup.reminder.body") }

    static var settings_dataLifecycle: String { t("settings.dataLifecycle") }

    static var settings_themeHint: String { t("settings.themeHint") }

    static var prefGroupReminders: String { t("pref.group.reminders") }

    static var prefGroupDisplay: String { t("pref.group.display") }

    static var prefGroupVoice: String { t("pref.group.voice") }

    static var prefTagGlobal: String { t("pref.tag.global") }

    static var prefTagNewOnly: String { t("pref.tag.newOnly") }

    static var prefRemindAdvance: String { t("pref.remindAdvance") }

    static var prefSnooze: String { t("pref.snooze") }

    static var prefQuietStart: String { t("pref.quietStart") }

    static var prefQuietEnd: String { t("pref.quietEnd") }

    static var prefTo: String { t("pref.to") }

    static var prefChannel: String { t("pref.channel") }

    static var prefChannelNotifyOnly: String { t("pref.channel.notifyOnly") }

    static var prefChannelRingUntilConfirm: String { t("pref.channel.ringUntilConfirm") }

    static var prefChannelSilentBanner: String { t("pref.channel.silentBanner") }

    static var prefNotifPreviewMed: String { t("pref.notifPreviewMed") }

    static var prefRemindScopeNote: String { t("pref.remindScopeNote") }

    static var prefWeekStart: String { t("pref.weekStart") }

    static var prefUnitSystem: String { t("pref.unitSystem") }

    static var prefUnitMetric: String { t("pref.unit.metric") }

    static var prefUnitImperial: String { t("pref.unit.imperial") }

    static var prefReduceMotion: String { t("pref.reduceMotion") }

    static var prefHomeSort: String { t("pref.homeSort") }

    static var prefHomeSortTime: String { t("pref.homeSort.time") }

    static var prefHomeSortType: String { t("pref.homeSort.type") }

    static var prefReadback: String { t("pref.readback") }

    static var prefReadbackNever: String { t("pref.readback.never") }

    static var prefReadbackAsk: String { t("pref.readback.ask") }

    static var prefReadbackAlways: String { t("pref.readback.always") }

    static var prefReadbackHint: String { t("pref.readbackHint") }

    static var prefRestoreAll: String { t("pref.restoreAll") }

    static var helpcardRecipient: String { t("helpcard.recipient") }

    static var helpcardRecipientOther: String { t("helpcard.recipientOther") }

    static var helpcardRecipientPlaceholder: String { t("helpcard.recipientPlaceholder") }

    static var helpcard_photoPending: String { t("helpcard.photoPending") }
}
