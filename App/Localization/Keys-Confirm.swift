// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var docConfirmTitle: String { t("docConfirm.title") }

    static var docConfirmViewRegion: String { t("docConfirm.viewRegion") }

    static var docConfirmSaveAll: String { t("docConfirm.saveAll") }

    static var docConfirmHint: String { t("docConfirm.hint") }

    static var docConfirmSkipLater: String { t("docConfirm.skipLater") }

    static var docConfirmSkipTitle: String { t("docConfirm.skipTitle") }

    static var docConfirmSkipConfirm: String { t("docConfirm.skipConfirm") }

    static var docConfirmSkipCancel: String { t("docConfirm.skipCancel") }

    static var docConfirmSkipSaved: String { t("docConfirm.skipSaved") }

    static var docConfirmDocType: String { t("docConfirm.docType") }

    static var docConfirmDocTypeHint: String { t("docConfirm.docTypeHint") }

    static var docConfirmDocTypeUnresolved: String { t("docConfirm.docTypeUnresolved") }

    static var docConfirmDocTypeLowConfidence: String { t("docConfirm.docTypeLowConfidence") }

    static var entityCardConfirmSave: String { t("entityCard.confirmSave") }

    static var entityCardLater: String { t("entityCard.later") }

    static var entityCardDiscard: String { t("entityCard.discard") }

    static var entityCardDeferRemaining: String { t("entityCard.deferRemaining") }

    static var entityCardReviewSource: String { t("entityCard.reviewSource") }

    static var entityCardReviewChoose: String { t("entityCard.reviewChoose") }

    static var entityCardSourceLineTitle: String { t("entityCard.sourceLineTitle") }

    static var entityCardSourceLineHint: String { t("entityCard.sourceLineHint") }

    /// 点行引用（业主 2026-09-19 第 1 项：原文行点选回填字段；2026-09-20 升级多行选择）
    static var entityCardSourceLineQuoteHint: String { t("entityCard.sourceLineQuoteHint") }

    /// 多行引用确认（业主 2026-09-20 第 1 项：已选行按行序连接后回填）
    static func entityCardSourceLineQuoteConfirm(_ count: Int) -> String {
        String(format: t("entityCard.sourceLineQuoteConfirmFmt"), count)
    }

    static var entityCardSourceLineSelected: String { t("entityCard.sourceLineSelected") }

    static var entityCardSourceLineSelect: String { t("entityCard.sourceLineSelect") }

    /// 字段旁 [看图] 入口（业主 2026-09-19 第 1 项：查看扫描原件核对证据）
    static var entityCardFieldViewScan: String { t("entityCard.fieldViewScan") }

    /// 字段旁 [选文] 入口（业主 2026-09-20 第 2 项：无锚定的新增字段从识别文本选填）
    static var entityCardFieldViewSourceText: String { t("entityCard.fieldViewSourceText") }

    static var entityCardRowSkipped: String { t("entityCard.rowSkipped") }

    static var entityCardSharedSection: String { t("entityCard.sharedSection") }

    static var entityCardRowsSection: String { t("entityCard.rowsSection") }

    static var entityCardLaterHint: String { t("entityCard.laterHint") }

    static var entityCardSaveFailed: String { t("entityCard.saveFailed") }

    static var docConfirmConfidenceHigh: String { t("docConfirm.confidenceHigh") }

    static var docConfirmConfidenceMid: String { t("docConfirm.confidenceMid") }

    static var docConfirmConfidenceLow: String { t("docConfirm.confidenceLow") }

    static var docConfirmReject: String { t("docConfirm.reject") }

    static var docConfirmReenable: String { t("docConfirm.reenable") }

    static var docConfirmAllConfirmBlocked: String { t("docConfirm.allConfirmBlocked") }

    static var docConfirmSaveFailedTitle: String { t("docConfirm.saveFailedTitle") }

    static var entityCardAddField: String { t("entityCard.addField") }

    static var entityCardPickValue: String { t("entityCard.pickValue") }

    static var entityCardConfirmAllHint: String { t("entityCard.confirmAllHint") }
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
    static var parentDraftTitle: String { t("parentDraft.title") }
    static var parentDraftHint: String { t("parentDraft.hint") }
    static var parentDraftNewEncounter: String { t("parentDraft.newEncounter") }
    static var parentDraftNewHealthExam: String { t("parentDraft.newHealthExam") }
    static var parentDraftUseExisting: String { t("parentDraft.useExisting") }
    static var parentDraftDateRequired: String { t("parentDraft.dateRequired") }
    static var parentDraftUnconfirmed: String { t("parentDraft.unconfirmed") }
    static var cardEditTitle: String { t("cardEdit.title") }
    static var cardEditFieldsSection: String { t("cardEdit.fieldsSection") }
    static var cardEditHint: String { t("cardEdit.hint") }
    static var cardEditSave: String { t("cardEdit.save") }
    static var cardEditSaved: String { t("cardEdit.saved") }
    static var cardEditSavedHint: String { t("cardEdit.savedHint") }
    static var cardEditFailed: String { t("cardEdit.failed") }
    static func cardEditInvalidDate(_ label: String) -> String {
        t("cardEdit.invalidDate").replacingOccurrences(of: "%@", with: label)
    }
    /// round5 Q1（F1.4）：已确认卡编辑面「添加字段」菜单标题。
    static var cardEditAddField: String { t("cardEdit.addField") }
    static func cardEditInvalidNumber(_ label: String) -> String {
        t("cardEdit.invalidNumber").replacingOccurrences(of: "%@", with: label)
    }
    static func cardEditLineTitle(_ name: String) -> String {
        t("cardEdit.lineTitle").replacingOccurrences(of: "%@", with: name)
    }
    static var ocConfirmCardAll: String { t("oc.confirm.cardAll") }
    static var ocFieldDept: String { t("oc.field.dept") }
    static var ocFieldReportDate: String { t("oc.field.reportDate") }
    static var ocFieldLabItem: String { t("oc.field.labItem") }
    static var ocFieldReferenceRange: String { t("oc.field.referenceRange") }
    static var ocFieldChiefComplaint: String { t("oc.field.chiefComplaint") }
    static var ocFieldDiagnosis: String { t("oc.field.diagnosis") }
    static var ocFieldTreatment: String { t("oc.field.treatment") }
}
