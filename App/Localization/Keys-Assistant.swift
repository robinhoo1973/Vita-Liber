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
    static var assistantVoiceTitle: String { t("assistant.voiceTitle") }
    static var assistantVoiceHint: String { t("assistant.voiceHint") }
    static var assistantVoiceUse: String { t("assistant.voiceUse") }

    // 2026-10-19 微信式输入栏：语音/键盘切换、附件面板（照片/拍照/PDF）
    static var assistantVoiceMode: String { t("assistant.modeVoice") }
    static var assistantKeyboardMode: String { t("assistant.modeText") }
    static var assistantVoiceTap: String { t("assistant.voiceTap") }
    static var assistantAttach: String { t("assistant.attach") }
    static var assistantAttachPhotos: String { t("assistant.attachPhotos") }
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
    static var assistantCaptureSaved: String { t("assistant.captureSaved") }
    static var assistantVoiceMessage: String { t("assistant.voiceMessage") }
    static var assistantVoiceReplay: String { t("assistant.voiceReplay") }
    static var assistantVoiceToText: String { t("assistant.voiceToText") }
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
    static var assistantHistoryDelete: String { t("assistant.historyDelete") }
    static var assistantHistoryDeleteBody: String { t("assistant.historyDeleteBody") }
    static func assistantHistoryMessages(_ count: Int) -> String {
        String(format: t("assistant.historyMessages"), count)
    }
    static var assistantHistoryNoPreview: String { t("assistant.historyNoPreview") }
    static var assistantNewConversation: String { t("assistant.newConversation") }

}
