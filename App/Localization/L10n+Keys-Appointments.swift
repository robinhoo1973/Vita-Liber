// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var apptListTitle: String { t("appt.listTitle") }

    static var apptEmpty: String { t("appt.empty") }

    static var apptEmptyHint: String { t("appt.emptyHint") }

    static func apptStatusName(_ s: String) -> String { t("appt.status.\(s)") }

    static var apptReschedule: String { t("appt.reschedule") }

    static var apptCancel: String { t("appt.cancel") }

    static var apptComplete: String { t("appt.complete") }

    static var apptFollowUpHint: String { t("appt.followUpHint") }

    static var apptMarkMissed: String { t("appt.markMissed") }

    static var apptMarkMissedHint: String { t("appt.markMissedHint") }

    static var apptCompleteHint: String { t("appt.completeHint") }

    static var apptNewDate: String { t("appt.newDate") }

    static var apptCancelReasonNone: String { t("appt.cancelReason.none") }

    static var apptCancelReasonDoctor: String { t("appt.cancelReason.doctor") }

    static var apptCancelReasonSelf: String { t("appt.cancelReason.self") }

    static var apptCancelReasonOther: String { t("appt.cancelReason.other") }

    static var apptFormTitle: String { t("appt.form.title") }

    static var apptFormBasic: String { t("appt.form.basic") }

    static var apptFormAddress: String { t("appt.form.address") }

    static var apptFormDate: String { t("appt.form.date") }

    static var apptFormPrep: String { t("appt.form.prep") }

    static var apptFormItems: String { t("appt.form.items") }

    static var apptFormNotes: String { t("appt.form.notes") }

    static var apptFormFollowUpRule: String { t("appt.form.followUpRule") }

    static func apptFollowUpRuleName(_ r: Int) -> String { t("appt.followUpRule.\(r)") }

    static var apptFollowUpConcreteDate: String { t("appt.followUpConcreteDate") }

    static var apptFollowUpDraftOnly: String { t("appt.followUpDraftOnly") }
}
