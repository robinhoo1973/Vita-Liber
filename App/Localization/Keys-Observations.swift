// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var observationTrendImproved: String { t("observation.trend.improved") }

    static var observationTrendUnchanged: String { t("observation.trend.unchanged") }

    static var observationTrendWorsened: String { t("observation.trend.worsened") }

    static var observationTitle: String { t("observation.title") }

    static var observationSectionTitle: String { t("observation.listSection") }

    static var observationAllergySection: String { t("observation.allergySection") }

    static var observationCreateTitle: String { t("observation.createTitle") }

    static var observationKindSection: String { t("observation.kindSection") }

    static var observationDescription: String { t("observation.description") }

    static var observationSelfMark: String { t("observation.selfMark") }

    static var observationSaveFailed: String { t("observation.saveFailed") }

    static var observationSaveFailedHint: String { t("observation.saveFailedHint") }

    static func observationKindName(forKey key: String) -> String {
        ObservationKind(rawValue: key).map(observationKindName) ?? t("observation.kind.unknown")
    }

    static var observationMediaSection: String { t("observation.media.section") }

    static var observationMediaAddAlbum: String { t("observation.media.addAlbum") }

    static var observationMediaAddCamera: String { t("observation.media.addCamera") }

    static var observationMediaUnlockHint: String { t("observation.media.unlockHint") }

    static var observationColorDisclaimer: String { t("observation.colorDisclaimer") }

    static var observationFollowUpSet: String { t("observation.followUp.set") }

    static var obsDetailCapturedAt: String { t("observation.detail.capturedAt") }

    static var obsDetailMember: String { t("observation.detail.member") }

    static var obsDetailBodyPart: String { t("observation.detail.bodyPart") }

    static var obsDetailDuration: String { t("observation.detail.duration") }

    static var obsDetailDurationFmt: String { t("observation.detail.durationFmt") }

    static var obsDetailFrequency: String { t("observation.detail.frequency") }

    static var obsDetailIsFirst: String { t("observation.detail.isFirst") }

    static var obsDetailTrigger: String { t("observation.detail.trigger") }

    static var obsDetailAccompanying: String { t("observation.detail.accompanying") }

    static var obsDetailPainScore: String { t("observation.detail.painScore") }

    static var obsDetailPainUnset: String { t("observation.detail.painUnset") }

    static var obsDetailMedsDiet: String { t("observation.detail.medsDiet") }

    static var obsDetailConsulted: String { t("observation.detail.consulted") }

    static var obsDetailEncounter: String { t("observation.detail.encounter") }

    static var obsDetailHealthProblem: String { t("observation.detail.healthProblem") }

    static var obsDetailGroup: String { t("observation.detail.group") }

    static var obsDetailEdit: String { t("observation.detail.edit") }

    static var obsDetailEditSave: String { t("observation.detail.editSave") }

    static var obsDetailEditSaved: String { t("observation.detail.editSaved") }

    static var obsDetailDelete: String { t("observation.detail.delete") }

    static var obsDetailDeleteTitle: String { t("observation.detail.deleteTitle") }

    static var obsDetailDeleteBody: String { t("observation.detail.deleteBody") }

    static var obsDetailDeleteDone: String { t("observation.detail.deleteDone") }

    static var obsDetailDeleteFailed: String { t("observation.detail.deleteFailed") }

    static var obsDetailFollowUpTitle: String { t("observation.detail.followUpTitle") }

    static var obsDetailFollowUpDays: String { t("observation.detail.followUpDays") }

    static var obsDetailFollowUpDone: String { t("observation.detail.followUpDone") }

    static var obsDetailLoadFailed: String { t("observation.detail.loadFailed") }

    static var obsDetailRetry: String { t("observation.detail.retry") }

    static var obsDetailEmpty: String { t("observation.detail.empty") }

    static var obsDetailViewGroup: String { t("observation.detail.viewGroup") }

    static var observationListEmpty: String { t("observation.listEmpty") }

    static var observationListEmptyHint: String { t("observation.listEmptyHint") }

    static var observationListError: String { t("observation.listError") }

    static var observationListRetry: String { t("observation.listRetry") }
}
