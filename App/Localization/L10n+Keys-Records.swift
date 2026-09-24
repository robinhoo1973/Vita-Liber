// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var claim_title: String { t("claim.title") }

    static var claim_empty: String { t("claim.empty") }

    static var claim_emptyHint: String { t("claim.emptyHint") }

    static var claim_add: String { t("claim.add") }

    static var claim_type_invoice: String { t("claim.type.invoice") }

    static var claim_type_fee: String { t("claim.type.fee") }

    static var claim_type_receipt: String { t("claim.type.receipt") }

    static var immunization_title: String { t("immunization.title") }

    static var immunization_empty: String { t("immunization.empty") }

    static var immunization_emptyHint: String { t("immunization.emptyHint") }

    static var immunization_confirmed: String { t("immunization.confirmed") }

    static var immunization_pending: String { t("immunization.pending") }

    static var immunization_note: String { t("immunization.note") }

    static var claim_type: String { t("claim.type") }

    static var claim_amount: String { t("claim.amount") }

    static var claim_date: String { t("claim.date") }

    static var claim_merchant: String { t("claim.merchant") }

    static var claim_summary: String { t("claim.summary") }

    static var claim_createTitle: String { t("claim.createTitle") }

    static var claim_save: String { t("claim.save") }

    static var immunizationVaccineName: String { t("immunization.vaccineName") }

    static var immunizationDate: String { t("immunization.date") }

    static var immunizationProvider: String { t("immunization.provider") }

    static var immunizationLotField: String { t("immunization.lotField") }

    static var immunizationCreateTitle: String { t("immunization.createTitle") }

    static func immunizationLot(_ lot: String) -> String {
        t("immunization.lot").replacingOccurrences(of: "%@", with: lot)
    }

    static var timelineEmptyTitle: String { t("timeline.empty.title") }

    static var timelineQuickEntry: String { t("timeline.quickEntry") }

    static func encounterKindName(_ kind: EncounterKind) -> String { t("encounter.kind.\(kind.rawValue)") }

    static var encounterListTitle: String { t("encounter.listTitle") }

    static var encounterEmpty: String { t("encounter.empty") }

    static var encounterEmptyHint: String { t("encounter.emptyHint") }

    static var encounterUntitled: String { t("encounter.untitled") }

    static var encounterSaveFailed: String { t("encounter.saveFailed") }

    static var encounterSaveFailedHint: String { t("encounter.saveFailedHint") }

    static var encounterDetailTitle: String { t("encounter.detailTitle") }

    static var encounterDiagnosisAdvice: String { t("encounter.diagnosisAdvice") }

    static var encounterDiagnosisBadge: String { t("encounter.diagnosisBadge") }

    static var encounterAdviceBadge: String { t("encounter.adviceBadge") }

    static var encounterFollowUp: String { t("encounter.followUp") }

    static var encounterLinkedDocs: String { t("encounter.linkedDocs") }

    static var encounterNoDocs: String { t("encounter.noDocs") }

    static var encounterRecommendSection: String { t("encounter.recommend.section") }

    static var encounterRecommendPending: String { t("encounter.recommend.pending") }

    static var encounterLink: String { t("encounter.link") }

    static var encounterGenerateSummary: String { t("encounter.generateSummary") }

    static var encounterSummaryTitle: String { t("encounter.summary.title") }

    static var encounterSummaryHeader: String { t("encounter.summary.header") }

    static var encounterSummaryUnconfirmed: String { t("encounter.summary.unconfirmed") }

    static var encounterSummaryAllConfirmed: String { t("encounter.summary.allConfirmed") }

    static var encounterSummaryNote: String { t("encounter.summary.note") }

    static var encounterSummaryNoteText: String { t("encounter.summary.noteText") }

    static var encounterFormTitle: String { t("encounter.form.title") }

    static var encounterFormBasic: String { t("encounter.form.basic") }

    static var encounterFormKind: String { t("encounter.form.kind") }

    static var encounterFormDate: String { t("encounter.form.date") }

    static var encounterFormHospital: String { t("encounter.form.hospital") }

    static var encounterFormDepartment: String { t("encounter.form.department") }

    static var encounterFormDoctor: String { t("encounter.form.doctor") }

    static var encounterFormClinical: String { t("encounter.form.clinical") }

    static var encounterFormComplaint: String { t("encounter.form.complaint") }

    static var encounterFormDiagnosis: String { t("encounter.form.diagnosis") }

    static var encounterFormAdvice: String { t("encounter.form.advice") }

    static var encounterFormFollowUp: String { t("encounter.form.followUp") }

    static var encounterFormFee: String { t("encounter.form.fee") }

    static var timelineTitle: String { t("timeline.title") }

    static var timelineEmptyHint: String { t("timeline.emptyHint") }

    static var timelineFilterAll: String { t("timeline.filter.all") }

    static func timelineKindName(_ kind: TimelineEntryKind) -> String { t("timeline.kind.\(kind.rawValue)") }

    static var timelineProblemsFilter: String { t("timeline.problemsFilter") }

    static var encounterNarrative: String { t("encounter.narrative") }

    static var encounterSectionHospitalization: String { t("encounter.section.hospitalization") }

    static var encounterSectionDiagnoses: String { t("encounter.section.diagnoses") }

    static var encounterSectionExamReports: String { t("encounter.section.examReports") }

    static var encounterSectionLabReports: String { t("encounter.section.labReports") }

    static func immunizationDoseCount(_ n: Int) -> String { t("immunization.doseCount").replacingOccurrences(of: "%d", with: String(n)) }

    static var immunization_childPlanComing: String { t("immunization.childPlanComing") }

    static var encounterLinkedCards: String { t("encounter.linkedCards") }

    static var encounterLinkedCardsEmpty: String { t("encounter.linkedCards.empty") }

    static var encounterAdd: String { t("encounter.add") }

    static var timelineHubOpen: String { t("timeline.hub.open") }

    static var timelineHubExpand: String { t("timeline.hub.expand") }

    static var timelineHubCollapse: String { t("timeline.hub.collapse") }

    static var timelineHubNoChildren: String { t("timeline.hub.noChildren") }

    static var timelineLoadingMore: String { t("timeline.loadingMore") }

    static var timelineLoadMoreFailed: String { t("timeline.loadMoreFailed") }

    static var encounterSectionSurgeries: String { t("encounter.section.surgeries") }

    static var encounterSectionTreatments: String { t("encounter.section.treatments") }

    static var encounterSectionFollowUpAppointments: String { t("encounter.section.followUpAppointments") }

    static var encounterSectionFollowUpReminders: String { t("encounter.section.followUpReminders") }

    static var encounterLinkAppointment: String { t("encounter.linkAppointment") }

    static var encounterLinkAppointmentHint: String { t("encounter.linkAppointment.hint") }

    static var encounterLinkAppointmentNone: String { t("encounter.linkAppointment.none") }

    static var encounterLinkAppointmentConfirm: String { t("encounter.linkAppointment.confirm") }

    static var encounterLinkAppointmentFailed: String { t("encounter.linkAppointment.failed") }

    static var catalogSuggestTitle: String { t("catalog.suggest.title") }
}
