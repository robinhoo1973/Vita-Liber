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
}
