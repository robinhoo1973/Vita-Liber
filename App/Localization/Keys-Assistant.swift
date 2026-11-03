// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var ai_confirmImageText: String { t("ai.confirmImageText") }

    static var ai_aiBadge: String { t("ai.aiBadge") }

    static var ai_citations: String { t("ai.citations") }

    static var aiUncertaintiesFixed: String { t("ai.uncertaintiesFixed") }

    static var aiQuestionsFixed: String { t("ai.questionsFixed") }

    static var aiDisclaimerFixed: String { t("ai.disclaimerFixed") }

    static var ai_source: String { t("ai.source") }

    static var ai_uncertain: String { t("ai.uncertain") }

    static var ai_askDoctor: String { t("ai.askDoctor") }

    static func aiUncertain(_ v: String) -> String {
        t("ai.uncertain").replacingOccurrences(of: "%@", with: v)
    }

    static func aiAskDoctor(_ v: String) -> String {
        t("ai.askDoctor").replacingOccurrences(of: "%@", with: v)
    }

    static var ai_refusedNoEvidence: String { t("ai.refusedNoEvidence") }

    static var ai_refusedHighRisk: String { t("ai.refusedHighRisk") }

    static var ai_failedRetry: String { t("ai.failedRetry") }

    static var ai_emergencyCall: String { t("ai.emergencyCall") }

    static var aiQuickGlucose: String { t("ai.quickGlucose") }

    static var aiQuickNext: String { t("ai.quickNext") }

    // 2026-10-18 任务型 AI 聊天入口（首页 OCR/ASR 图标旁）
    static var assistantChatTitle: String { t("assistant.chatTitle") }
    static var assistantClose: String { t("assistant.close") }
    static var assistantChatEmptyTitle: String { t("assistant.emptyTitle") }
    static var assistantChatEmptyBody: String { t("assistant.emptyBody") }
    static var assistantChatPlaceholder: String { t("assistant.placeholder") }
    static var assistantSend: String { t("assistant.send") }
    static func assistantClarify(_ slot: String) -> String {
        String(format: t("assistant.clarifyFmt"), slot)
    }
    static var assistantSavedNote: String { t("assistant.savedNote") }
    static var assistantSavedQuestion: String { t("assistant.savedQuestion") }
    static var assistantSaveFailed: String { t("assistant.saveFailed") }
    static var assistantMedDraftDeferred: String { t("assistant.medDraftDeferred") }
    static var assistantQuickMetric: String { t("assistant.quickMetric") }
    static var assistantQuickReminder: String { t("assistant.quickReminder") }
    static var assistantQuickQuestion: String { t("assistant.quickQuestion") }
    static var assistantDisabled: String { t("assistant.disabled") }
    static var assistantEmergencyHandoff: String { t("assistant.emergencyHandoff") }
    static var assistantMissingFields: String { t("assistant.missingFields") }

    // 2026-10-19 微信式输入栏：语音/键盘切换、附件面板（照片/拍照/PDF）
    static var assistantVoiceMode: String { t("assistant.modeVoice") }
    static var assistantKeyboardMode: String { t("assistant.modeText") }
    static var assistantVoiceTap: String { t("assistant.voiceTap") }
    static var assistantVoiceStop: String { t("assistant.voiceStop") }
    static var assistantMediaOpen: String { t("assistant.mediaOpen") }
    static var assistantVoiceReplayFailed: String { t("assistant.voiceReplayFailed") }
    static var assistantVoiceRecording: String { t("assistant.voiceRecording") }
    static var assistantVoiceRecognizing: String { t("assistant.voiceRecognizing") }
    static var assistantAttach: String { t("assistant.attach") }
    static var assistantAttachPhotos: String { t("assistant.attachPhotos") }
    static var assistantAttachmentBatchFmt: String { t("assistant.attachmentBatchFmt") }
    // 2026-10-30 业主：多附件不再显示「N 份附件」；合并件用固定名称。
    static var assistantMergedPhotosFilename: String { t("assistant.mergedPhotosFilename") }
    static var assistantMergedFilesFilename: String { t("assistant.mergedFilesFilename") }
    static var assistantMergedMixedFilename: String { t("assistant.mergedMixedFilename") }
    static var assistantAttachmentTruncated: String { t("assistant.attachmentTruncated") }
    static var assistantAttachCamera: String { t("assistant.attachCamera") }
    static var assistantAttachPDF: String { t("assistant.attachPDF") }
    static var assistantCaptureQueued: String { t("assistant.captureQueued") }
    // 2026-10-19 聊天内媒体 → 信息卡
    static var assistantCardDone: String { t("assistant.cardDone") }
    static var assistantCardDeferred: String { t("assistant.cardDeferred") }
    static var assistantCardLocked: String { t("assistant.cardLocked") }
    static var assistantCardEdit: String { t("assistant.cardEdit") }
    static var assistantCardUnavailable: String { t("assistant.cardUnavailable") }
    static var assistantMediaProcessing: String { t("assistant.mediaProcessing") }
    static var assistantMediaReady: String { t("assistant.mediaReady") }
    static var assistantMediaFailed: String { t("assistant.mediaFailed") }
    static var assistantMediaDuplicate: String { t("assistant.mediaDuplicate") }
    static var assistantImportBusy: String { t("assistant.importBusy") }
    static var assistantDocTypeUnresolved: String { t("assistant.docTypeUnresolved") }
    /// 聊天内资料类型补选被取消（原图未落库）；不再提示「去拍摄入口」。
    static var assistantDocTypePickCancelled: String { t("assistant.docTypePickCancelled") }
    static var assistantFailedMediaTitle: String { t("assistant.failedMediaTitle") }
    static var assistantFailedMediaBody: String { t("assistant.failedMediaBody") }
    static var assistantFailedMediaRetry: String { t("assistant.failedMediaRetry") }
    static var assistantCaptureSaved: String { t("assistant.captureSaved") }
    static var assistantVoiceMessage: String { t("assistant.voiceMessage") }
    static var assistantVoiceReplay: String { t("assistant.voiceReplay") }
    static var assistantVoiceToText: String { t("assistant.voiceToText") }
    // 2026-10-29 批三（mock v4 对照）：OCR/ASR 卡片化回复 + 媒体详情双 tab。
    // 回复模板只陈述识别事实与边界，不含任何内容解读（BR-006 措辞负清单）。
    static func assistantOcrReply(_ fields: Int) -> String {
        String(format: t("assistant.ocrReplyFmt"), fields)
    }
    static var assistantVoiceReply: String { t("assistant.voiceReply") }
    static var assistantOcrReplyPlain: String { t("assistant.ocrReplyPlain") }
    static var assistantMediaDetailHint: String { t("assistant.mediaDetailHint") }
    static var assistantMediaLoadFailed: String { t("assistant.mediaLoadFailed") }
    static var assistantMediaLegacyNote: String { t("assistant.mediaLegacyNote") }
    static var assistantMediaDetailTitle: String { t("assistant.mediaDetailTitle") }
    static var assistantMediaTextEmpty: String { t("assistant.mediaTextEmpty") }
    static var assistantMediaCardsEmpty: String { t("assistant.mediaCardsEmpty") }
    static var assistantMediaOpenOriginal: String { t("assistant.mediaOpenOriginal") }
    static var assistantMediaPageFailed: String { t("assistant.mediaPageFailed") }
    static var assistantMediaPageNoText: String { t("assistant.mediaPageNoText") }
    /// 页级状态三值：failed / no_text / skipped（未授权、超页数上限或被取消）。
    static var assistantMediaPageSkipped: String { t("assistant.mediaPageSkipped") }
    static var assistantMediaEgressNote: String { t("assistant.mediaEgressNote") }
    // 2026-10-29 六点收口批（审查席重写版消费）：详情双区标题与 D/C 状态词。
    // CI 40870743625 红修复：访问器在小批覆盖中丢失（键与三语字符串均在）。
    static var assistantMediaCardsPendingSection: String { t("assistant.mediaCardsPendingSection") }
    static var assistantMediaCardsCommittedSection: String { t("assistant.mediaCardsCommittedSection") }
    static var assistantMediaNeedsConfirm: String { t("assistant.mediaNeedsConfirm") }
    static var assistantMediaConfirmed: String { t("assistant.mediaConfirmed") }
    /// 归档卡补办（业主裁决 A，2026-10-30）。
    static var assistantMediaArchivedRestore: String { t("assistant.mediaArchivedRestore") }
    static var assistantMediaEgressNoteMirror: String { t("assistant.mediaEgressNoteMirror") }
    // 2026-10-30 业主（mock v4 第 4/5/6/8 帧）：缩略图直入原图、更多操作、
    // 待核对卡字段摘要、语音详情、导入前图片检查。
    static var chatMediaMoreActions: String { t("chat.mediaMoreActions") }
    static var chatMediaExportCopyNote: String { t("chat.mediaExportCopyNote") }
    static var chatMediaReRecognize: String { t("chat.mediaReRecognize") }
    static var chatMediaStorageLocation: String { t("chat.mediaStorageLocation") }
    static var chatMediaStorageOnDevice: String { t("chat.mediaStorageOnDevice") }
    static var chatMediaStorageLoading: String { t("chat.mediaStorageLoading") }
    static var chatMediaStorageExportedFmt: String { t("chat.mediaStorageExportedFmt") }
    static var chatMediaPageCount: String { t("chat.mediaPageCount") }
    static var chatMediaPageCountFmt: String { t("chat.mediaPageCountFmt") }
    /// 原图页点数超过 12 时的溢出徽标（"+N"，2026-10-30 复审走 L10n 单一出口）。
    static var chatMediaPageMoreFmt: String { t("chat.mediaPageMoreFmt") }
    static func chatMediaPageCountText(_ count: Int) -> String {
        count == 1 ? t("chat.mediaPageCountOne")
                   : String(format: t("chat.mediaPageCountFmt"), count)
    }
    static var chatMediaExportDone: String { t("chat.mediaExportDone") }
    static var chatMediaCardsFootnote: String { t("chat.mediaCardsFootnote") }
    static func chatMediaPageAccessibility(_ page: Int, _ total: Int) -> String {
        String(format: t("chat.mediaPageAccessibilityFmt"), page, total)
    }
    static var chatVoiceDetailTitle: String { t("chat.voiceDetailTitle") }
    static var chatVoiceTabTranscript: String { t("chat.voiceTabTranscript") }
    static var chatVoiceTabSummary: String { t("chat.voiceTabSummary") }
    static var chatVoiceTranscriptEmpty: String { t("chat.voiceTranscriptEmpty") }
    static var chatVoiceSummaryEmpty: String { t("chat.voiceSummaryEmpty") }
    static var chatVoiceSummaryNote: String { t("chat.voiceSummaryNote") }
    static var chatVoiceUnavailable: String { t("chat.voiceUnavailable") }
    static var chatVoicePlay: String { t("chat.voicePlay") }
    static var chatVoicePause: String { t("chat.voicePause") }
    static var chatVoiceBack15: String { t("chat.voiceBack15") }
    static var chatVoiceForward15: String { t("chat.voiceForward15") }
    static var chatVoiceRate: String { t("chat.voiceRate") }
    /// 倍速徽标（"1X"/"1.5X"/"2X"）——含用户可见字符，必须经 L10n。
    static var chatVoiceRateFmt: String { t("chat.voiceRateFmt") }
    static var chatVoiceOpenHint: String { t("chat.voiceOpenHint") }
    static var chatImagePreviewTitle: String { t("chat.imagePreviewTitle") }
    static var chatImagePreviewImage: String { t("chat.imagePreviewImage") }
    static var chatImagePreviewPageFmt: String { t("chat.imagePreviewPageFmt") }
    static var chatImagePreviewRotate: String { t("chat.imagePreviewRotate") }
    static var chatImagePreviewConfirm: String { t("chat.imagePreviewConfirm") }
    static var chatImagePreviewHint: String { t("chat.imagePreviewHint") }
    static var chatImagePreviewPrevious: String { t("chat.imagePreviewPrevious") }
    static var chatImagePreviewNext: String { t("chat.imagePreviewNext") }
    // 2026-10-19 对话历史
    static var assistantHistoryTitle: String { t("assistant.historyTitle") }
    static var assistantHistoryNew: String { t("assistant.historyNew") }
    static var assistantHistorySearch: String { t("assistant.historySearch") }
    static var assistantHistoryEmpty: String { t("assistant.historyEmpty") }
    static var assistantHistoryToday: String { t("assistant.historyToday") }
    static var assistantHistoryYesterday: String { t("assistant.historyYesterday") }
    static var assistantHistoryEarlier: String { t("assistant.historyEarlier") }
    static var assistantHistoryRename: String { t("assistant.historyRename") }
    static var assistantHistoryRenamePrompt: String { t("assistant.historyRenamePrompt") }
    static var assistantHistoryPin: String { t("assistant.historyPin") }
    static var assistantHistoryUnpin: String { t("assistant.historyUnpin") }
    static var assistantExportCopyFailed: String { t("assistant.exportCopyFailed") }
    static var assistantHistoryDelete: String { t("assistant.historyDelete") }
    static var assistantHistoryDeleteBody: String { t("assistant.historyDeleteBody") }
    static func assistantHistoryMessages(_ count: Int) -> String {
        // 审查席 P2：en 下 "1 messages" 语法错——单条走已注册的 One 键。
        count == 1 ? t("assistant.historyMessageOne")
                   : String(format: t("assistant.historyMessages"), count)
    }
    static var assistantHistoryNoPreview: String { t("assistant.historyNoPreview") }
    static var assistantHistoryLoadFailed: String { t("assistant.historyLoadFailed") }
    static var assistantNewConversation: String { t("assistant.newConversation") }

    // 2026-11-01 业主（mock chat-import-staging.html）：聊天导入待提交区 +
    // 媒体详情三页（文件 / 识别结果 / 信息卡片）。所有用户可见文案单出口。
    static var chatImportStagingTitle: String { t("chat.importStaging.title") }
    static func chatImportStagingHint(_ count: Int, _ pages: Int) -> String {
        String(format: t("chat.importStaging.hintFmt"), count, pages)
    }
    static var chatImportStagingImageBadge: String { t("chat.importStaging.imageBadge") }
    static func chatImportStagingPDFPages(_ pages: Int) -> String {
        String(format: t("chat.importStaging.pdfPagesFmt"), pages)
    }
    static func chatImportStagingPageOrdinal(_ page: Int) -> String {
        String(format: t("chat.importStaging.pageOrdinalFmt"), page)
    }
    static func chatImportStagingPreview(_ name: String) -> String {
        String(format: t("chat.importStaging.previewFmt"), name)
    }
    static var chatImportStagingReorder: String { t("chat.importStaging.reorder") }
    static var chatImportStagingMoveEarlier: String { t("chat.importStaging.moveEarlier") }
    static var chatImportStagingMoveLater: String { t("chat.importStaging.moveLater") }
    static var chatImportStagingAddCamera: String { t("chat.importStaging.addCamera") }
    static var chatImportStagingAddPhotos: String { t("chat.importStaging.addPhotos") }
    static var chatImportStagingAddFiles: String { t("chat.importStaging.addFiles") }
    static var chatImportStagingReading: String { t("chat.importStaging.reading") }
    static var chatImportStagingPrivacy: String { t("chat.importStaging.privacy") }
    static func chatImportStagingSubmit(_ count: Int) -> String {
        String(format: t("chat.importStaging.submitFmt"), count)
    }
    static var chatImportStagingEmpty: String { t("chat.importStaging.empty") }
    static var chatImportStagingNoticeTitle: String { t("chat.importStaging.noticeTitle") }
    static var chatImportStagingReadFailed: String { t("chat.importStaging.readFailed") }
    static var chatImportStagingTooManyItems: String { t("chat.importStaging.tooManyItems") }
    static var chatImportStagingTooManyPages: String { t("chat.importStaging.tooManyPages") }
    static var chatImportStagingTooLarge: String { t("chat.importStaging.tooLarge") }

    static var chatMediaResultTitle: String { t("chat.mediaResultTitle") }
    static var chatMediaTabElements: String { t("chat.mediaTabElements") }
    static var chatMediaTabCards: String { t("chat.mediaTabCards") }
    static var chatMediaViewSourceImage: String { t("chat.mediaViewSourceImage") }
    static var chatMediaElementSave: String { t("chat.mediaElementSave") }
    static var chatMediaElementSaveAll: String { t("chat.mediaElementSaveAll") }
    static var chatMediaElementExpand: String { t("chat.mediaElementExpand") }
    static var chatMediaElementCollapse: String { t("chat.mediaElementCollapse") }
    static var chatMediaElementSaving: String { t("chat.mediaElementSaving") }
    static var chatMediaElementSaved: String { t("chat.mediaElementSaved") }
    static var chatMediaElementSaveFailed: String { t("chat.mediaElementSaveFailed") }
    static var chatMediaElementSaveFailedOpenCard: String { t("chat.mediaElementSaveFailedOpenCard") }
    static var chatMediaElementSharedLocked: String { t("chat.mediaElementSharedLocked") }
    static var chatMediaPreviousPage: String { t("chat.mediaPreviousPage") }
    static var chatMediaNextPage: String { t("chat.mediaNextPage") }
    static var chatMediaDiscardEditsTitle: String { t("chat.mediaDiscardEditsTitle") }
    static var chatMediaDiscardEditsAction: String { t("chat.mediaDiscardEditsAction") }
    static var chatMediaCropTitle: String { t("chat.mediaCropTitle") }
    static var chatMediaCropLoading: String { t("chat.mediaCropLoading") }
    static var chatMediaCropFailed: String { t("chat.mediaCropFailed") }
    static var chatMediaCropFullPageNote: String { t("chat.mediaCropFullPageNote") }
    static func chatMediaSummary(_ attachments: Int, _ pages: Int) -> String {
        String(format: t("chat.mediaSummaryFmt"), attachments, pages)
    }
    static var chatMediaElementsP1Note: String { t("chat.mediaElementsP1Note") }
    static var chatMediaElementsGroupHeader: String { t("chat.mediaElementsGroupHeader") }
    static var chatMediaElementsEmpty: String { t("chat.mediaElementsEmpty") }
    static func chatMediaElementRowTitle(_ kind: String, _ row: Int) -> String {
        String(format: t("chat.mediaElementRowTitleFmt"), kind, row)
    }
    static func chatMediaElementSubtitle(_ page: Int, _ count: Int) -> String {
        String(format: t("chat.mediaElementSubtitleFmt"), page, count)
    }
    static var chatMediaGoConfirm: String { t("chat.mediaGoConfirm") }
    static var chatMediaSourceText: String { t("chat.mediaSourceText") }
    static var chatMediaElementsToCards: String { t("chat.mediaElementsToCards") }
    static var chatMediaElementsFooter: String { t("chat.mediaElementsFooter") }
    static var chatMediaCardsAssemblyNote: String { t("chat.mediaCardsAssemblyNote") }

}
