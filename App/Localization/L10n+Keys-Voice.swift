// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var voiceConfirmTitle: String { t("voice.confirm.title") }

    static var voiceConfirmPending: String { t("voice.confirm.pending") }

    static var voiceConfirmLowConfidence: String { t("voice.confirm.lowConfidence") }
    static var voiceConfirmFieldConfirmed: String { t("voice.confirm.fieldConfirmed") }
    static func voiceConfirmLowPending(_ count: Int) -> String { String(format: t("voice.confirm.lowPendingFmt"), count) }

    static var voiceConfirmSave: String { t("voice.confirm.save") }

    static var voiceConfirmRetry: String { t("voice.confirm.retry") }

    static var voiceConfirmCancel: String { t("voice.confirm.cancel") }

    static var voiceSpeakAloud: String { t("voice.speak.button") }

    static var voiceFallbackNotice: String { t("voice.fallbackNotice") }

    static var voiceScreenCheckHint: String { t("voice.speak.screenHint") }

    static var voiceRejectAction: String { t("voice.rejectAction") }

    static var voiceBystanderWarning: String { t("voice.speak.bystander") }

    static var voiceAskSpeak: String { t("voice.ask.speak") }

    static var voiceAskScreen: String { t("voice.ask.screen") }

    static var voiceRouteHeadphonesOn: String { t("voice.route.headphonesOn") }

    static var voiceRouteHeadphonesOff: String { t("voice.route.headphonesOff") }

    static var voiceReminderTimeUnclear: String { t("voice.reminder.timeUnclear") }

    static var voiceReminderTimeUnheard: String { t("voice.reminder.timeUnheard") }

    static var voiceReminderSaveFailed: String { t("voice.reminder.saveFailed") }

    static var voicePrivacyTitle: String { t("voice.privacy.title") }

    static var voicePrivacyPoint1: String { t("voice.privacy.p1") }

    static var voicePrivacyPoint2: String { t("voice.privacy.p2") }

    static var voicePrivacyPoint3: String { t("voice.privacy.p3") }

    static var voicePrivacyPoint4: String { t("voice.privacy.p4") }

    static var voicePrivacyAccept: String { t("voice.privacy.accept") }

    static var voicePrivacyUseTouch: String { t("voice.privacy.useTouch") }

    static var f19_sessionTitle: String { t("f19.sessionTitle") }

    static var f19_launch: String { t("f19.launch") }

    static var f19_listeningHint: String { t("f19.listeningHint") }

    static var f19_typeHint: String { t("f19.typeHint") }

    static var f19_end: String { t("f19.end") }

    static var f19_sayAgainHint: String { t("f19.sayAgainHint") }

    static var f19_confirm: String { t("f19.confirm") }

    static var f19_cancel: String { t("f19.cancel") }

    static var f19_rejectedTitle: String { t("f19.rejectedTitle") }

    static var f19_goTouch: String { t("f19.goTouch") }

    static var f19_stopped: String { t("f19.stopped") }

    static var f19_paused: String { t("f19.paused") }

    static var voiceguide_reminderTitle: String { t("voiceguide.reminderTitle") }

    static var voiceguide_reminderExample: String { t("voiceguide.reminderExample") }

    static var voiceguide_transcript: String { t("voiceguide.transcript") }

    static var voiceguide_buildDraft: String { t("voiceguide.buildDraft") }

    static var voiceguide_stepOf: String { t("voiceguide.stepOf") }

    static var voiceguide_skip: String { t("voiceguide.skip") }

    static var voiceguide_next: String { t("voiceguide.next") }

    static var voiceguide_answerHint: String { t("voiceguide.answerHint") }

    static var voiceguide_profileTitle: String { t("voiceguide.profileTitle") }

    static var voiceguide_micTitle: String { t("voiceguide.micTitle") }

    static var voiceguide_micPrompt: String { t("voiceguide.micPrompt") }

    static var voiceguide_micPhrase: String { t("voiceguide.micPhrase") }

    static var voiceguide_micTooLow: String { t("voiceguide.micTooLow") }

    static var voiceguide_micSkip: String { t("voiceguide.micSkip") }

    static var voiceguide_micPass: String { t("voiceguide.micPass") }

    static var voiceguide_noteAllergy: String { t("voiceguide.note.allergy") }

    static var voiceguide_noteHistory: String { t("voiceguide.note.history") }

    static var voiceguide_noteMeds: String { t("voiceguide.note.meds") }

    static var voiceguide_noteContact: String { t("voiceguide.note.contact") }

    static var voiceFieldDate: String { t("voice.field.date") }

    static var voiceFieldHour: String { t("voice.field.hour") }

    static var voiceFieldRepeat: String { t("voice.field.repeat") }

    static var voiceFieldContent: String { t("voice.field.content") }

    static var voiceConfirmFillHint: String { t("voice.confirm.fillHint") }

    static var voiceReadbackFmt: String { t("voice.readbackFmt") }

    static var voiceguide_saved: String { t("voiceguide.saved") }

    static var voiceguide_profileDoneHint: String { t("voiceguide.profileDoneHint") }

    static var voiceguide_profileDoneTitle: String { t("voiceguide.profileDoneTitle") }

    static var f19_sendA11y: String { t("f19.sendA11y") }

    static var voiceguide_promptAllergy: String { t("voiceguide.promptAllergy") }

    static var voiceguide_promptHistory: String { t("voiceguide.promptHistory") }

    static var voiceguide_promptMeds: String { t("voiceguide.promptMeds") }

    static var voiceguide_promptContact: String { t("voiceguide.promptContact") }

    static func f19RepeatObject(_ obj: String) -> String {
        t("f19.repeatObject").replacingOccurrences(of: "%@", with: obj)
    }

    static func f19Executed(_ command: String) -> String {
        t("f19.executed").replacingOccurrences(of: "%@", with: command)
    }

    static var voicenoteEmptyTitle: String { t("voicenote.empty.title") }

    static var voicenoteEmptyHint: String { t("voicenote.empty.hint") }

    static var voicenoteInTimeline: String { t("voicenote.inTimeline") }

    static var voicenoteDraftPlaceholder: String { t("voicenote.draft.placeholder") }

    static var voicenoteDraftAccessibility: String { t("voicenote.draft.accessibility") }

    static var voicenoteSaveAccessibility: String { t("voicenote.save.accessibility") }

    static var voicenoteTitle: String { t("voicenote.title") }

    static var voicenoteSaveFailed: String { t("voicenote.saveFailed") }

    static var voicenoteDictation: String { t("voicenote.dictation") }

    static var voicenoteDictating: String { t("voicenote.dictating") }

    static var voicenoteStop: String { t("voicenote.stop") }

    static var voicenoteDictationFailed: String { t("voicenote.dictationFailed") }

    static var voicenoteTapHint: String { t("voicenote.tapHint") }

    static var voicenoteDictationDenied: String { t("voicenote.dictationDenied") }
    static var voicenoteDictationEngineUnavailable: String { t("voicenote.dictationEngineUnavailable") }
    /// round5 Q3：模型加载前内存预算不足（`TranscriptionError.insufficientMemory`）——给可行动建议，不再表现为「闪退」。
    /// 参数：所需 / 可用（GB，一位小数）。
    static func voicenoteDictationInsufficientMemory(requiredGB: String, availableGB: String) -> String {
        t("voicenote.dictationInsufficientMemory")
            .replacingOccurrences(of: "%1$@", with: requiredGB)
            .replacingOccurrences(of: "%2$@", with: availableGB)
    }

    static var voicePrimaryLanguage: String { t("voice.primaryLanguage") }

    static var voicePrimaryLanguageHint: String { t("voice.primaryLanguageHint") }

    static var voiceBestEffortActive: String { t("voice.bestEffortActive") }

    static var voiceVersionNative: String { t("voice.version.native") }

    static var voiceVersionRefined: String { t("voice.version.refined") }

    static var voiceVersionRefinedHint: String { t("voice.version.refinedHint") }

    static var voiceVersionUnavailable: String { t("voice.version.unavailable") }

    static var voiceVersionRejected: String { t("voice.version.rejected") }

    static var voiceVersionPreviewOnly: String { t("voice.version.previewOnly") }

    static var voiceInputUnavailable: String { t("voice.inputUnavailable") }

    static var voiceDictationIncomplete: String { t("voice.dictationIncomplete") }

    static var voicenoteDetailBody: String { t("voicenote.detailBody") }

    static var voicenoteDetailTags: String { t("voicenote.detailTags") }

    static var voicenoteDetailTagsHint: String { t("voicenote.detailTagsHint") }

    static var voicenoteDetailTimeline: String { t("voicenote.detailTimeline") }

    static var voicenoteDetailTimelineHint: String { t("voicenote.detailTimelineHint") }

    static var voicenoteDetailDelete: String { t("voicenote.detailDelete") }

    static var voicenoteDetailDeleteConfirm: String { t("voicenote.detailDeleteConfirm") }

    static var voicePanelSaved: String { t("voicenote.saved") }

    static var voicenoteView: String { t("voicenote.view") }

    static var f19NoTodayMeds: String { t("f19.noTodayMeds") }

    static var f19GoTimeline: String { t("f19.goTimeline") }

    static var f19GoHome: String { t("f19.goHome") }

    static var f19NoAppointment: String { t("f19.noAppointment") }

    static var f19NoGlucose: String { t("f19.noGlucose") }

    static var f19NoStock: String { t("f19.noStock") }

    static var f19LocationUnknown: String { t("f19.locationUnknown") }

    static var f19NoExpiring: String { t("f19.noExpiring") }

    static var f19Taken: String { t("f19.taken") }

    static var f19NotTaken: String { t("f19.notTaken") }

    static var f19RecordFailed: String { t("f19.recordFailed") }

    static var f19MetricInvalidValue: String { t("f19.metricInvalidValue") }

    static var f19NextPage: String { t("f19.nextPage") }

    static func f19MedListMore(_ remaining: Int) -> String {
        t("f19.medListMore").replacingOccurrences(of: "%d", with: String(remaining))
    }

    static var voiceLabTitle: String { t("voiceLab.title") }

    static var voiceLabEngineSection: String { t("voiceLab.engine.section") }

    static var voiceLabEngineFooter: String { t("voiceLab.engine.footer") }

    static var voiceEngineAuto: String { t("voiceLab.engine.auto") }

    static var voiceEngineAutoHint: String { t("voiceLab.engine.auto.hint") }

    static var voiceEngineAdvanced: String { t("voiceLab.engine.advanced") }

    static var voiceEngineAdvancedHint: String { t("voiceLab.engine.advanced.hint") }

    static var voiceEngineDictation: String { t("voiceLab.engine.dictation") }

    static var voiceEngineDictationHint: String { t("voiceLab.engine.dictation.hint") }

    static var voiceEngineClassic: String { t("voiceLab.engine.classic") }

    static var voiceEngineClassicHint: String { t("voiceLab.engine.classic.hint") }

    static var voiceLabRequiresNewerOS: String { t("voiceLab.requiresNewerOS") }

    static var voiceLabUnsupported: String { t("voiceLab.unsupported") }

    static var voiceLabAssetSection: String { t("voiceLab.asset.section") }

    static var voiceLabLocaleLabel: String { t("voiceLab.asset.locale") }

    static var voiceLabAssetLabel: String { t("voiceLab.asset.label") }

    static var voiceLabAssetInstalled: String { t("voiceLab.asset.installed") }

    static var voiceLabAssetDownloadable: String { t("voiceLab.asset.downloadable") }

    static var voiceLabAssetUnavailable: String { t("voiceLab.asset.unavailable") }

    static var voiceLabInstall: String { t("voiceLab.asset.install") }

    static var voiceLabInstalling: String { t("voiceLab.asset.installing") }
    /// 2026-09-20 修复（业主第 6 项）：安装进行态文案（系统下载 API 无字节进度，如实呈现不确定进度）
    static var voiceLabInstallingHint: String { t("voiceLab.asset.installingHint") }

    static var voiceLabInstallDone: String { t("voiceLab.asset.installDone") }

    static var voiceLabInstallFailed: String { t("voiceLab.asset.installFailed") }

    static var voiceLabAssetFooter: String { t("voiceLab.asset.footer") }

    static var voiceLabTestSection: String { t("voiceLab.test.section") }

    static var voiceLabTestFooter: String { t("voiceLab.test.footer") }

    static var voiceLabFallbackAsset: String { t("voiceLab.fallback.asset") }

    static var voiceLabFallbackUnavailable: String { t("voiceLab.fallback.unavailable") }

    static var voiceLabFallbackMissing: String { t("voiceLab.fallback.missing") }

    static var voiceLabResultSection: String { t("voiceLab.result.section") }

    static var voiceLabNoResult: String { t("voiceLab.result.empty") }

    static var voiceLabResultMeta: String { t("voiceLab.result.meta") }

    static var voiceLabResultFooter: String { t("voiceLab.result.footer") }

    static var voiceLabEntryHint: String { t("voiceLab.entry.hint") }

    static var asrBundledOffline: String { t("asr.bundledOffline") }

    static var asrModelDownload: String { t("asr.model.download") }

    static var asrModelVariantTitle: String { t("asr.model.variantTitle") }

    static var asrModelVariantSmall: String { t("asr.model.variantSmall") }

    static var asrModelVariantMedium: String { t("asr.model.variantMedium") }

    static var asrModelVariantLarge: String { t("asr.model.variantLarge") }

    static var asrModelDownloading: String { t("asr.model.downloading") }

    /// 2026-09-19 审查修复：并发槽满（最多 2 个同时下载）排队等待态文案——
    /// 旧实现把槽满拒绝渲染成「下载失败/检查网络」，用户误判网络坏了。
    static var asrModelQueued: String { t("asr.model.queued") }

    static var asrModelDownloadFailed: String { t("asr.model.downloadFailed") }

    static var asrModelCheckUpdate: String { t("asr.model.checkUpdate") }

    static var asrModelChecking: String { t("asr.model.checking") }

    static var asrModelCheckUpToDate: String { t("asr.model.checkUpToDate") }

    static var asrModelModeSingle: String { t("asr.model.modeSingle") }

    static var asrModelPhaseVerifying: String { t("asr.model.phaseVerifying") }

    static var asrModelPhaseUnpacking: String { t("asr.model.phaseUnpacking") }

    static var asrModelPhaseActivating: String { t("asr.model.phaseActivating") }

    static var asrModelPhasePruning: String { t("asr.model.phasePruning") }

    static var asrModelBackgroundHint: String { t("asr.model.backgroundHint") }
    /// round5 Q2：iOS ≤25 下载期如实提示（`beginBackgroundTask` 仅约 30 秒宽限，切后台即暂停）；iOS 26 用 backgroundHint。
    static var asrModelForegroundHint: String { t("asr.model.foregroundHint") }

    static var asrIndexFetchFailed: String { t("asr.index.fetchFailed") }

    static var asrPreparing: String { t("asr.preparing") }

    static var asrSelectionHint: String { t("asr.selectionHint") }

    static var voiceReadAloudA11y: String { t("voice.readAloudA11y") }
}

