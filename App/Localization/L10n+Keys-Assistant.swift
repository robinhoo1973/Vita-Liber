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
}
