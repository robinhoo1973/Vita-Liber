// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var inventory_title: String { t("inventory.title") }

    static var inventory_empty: String { t("inventory.empty") }

    static var inventory_emptyHint: String { t("inventory.emptyHint") }

    static var inventory_approxDays: String { t("inventory.approxDays") }

    static var inventory_noPlanHint: String { t("inventory.noPlanHint") }

    static var inventory_fixCount: String { t("inventory.fixCount") }

    static var lotDetailLoadFailed: String { t("lot.detail.loadFailed") }

    static var lotDiscardTitle: String { t("lot.discard.title") }

    static var lotDiscard: String { t("lot.discard") }

    static var lotDiscardDone: String { t("lot.discard.done") }

    static var lotArchiveTitle: String { t("lot.archive.title") }

    static var lotTotalUnits: String { t("lot.totalUnits") }

    static var lotOpenedAt: String { t("lot.openedAt") }

    static var lotExpireAt: String { t("lot.expireAt") }

    static var lotExpireUnknown: String { t("lot.expireUnknown") }

    static var lotStorage: String { t("lot.storage") }

    static var lotLastReconciled: String { t("lot.lastReconciled") }

    static var lotExpiredBadge: String { t("lot.expiredBadge") }

    static var lotEdit: String { t("lot.edit") }

    static var lotEditTitle: String { t("lot.edit.title") }

    static var lotEditFailed: String { t("lot.edit.failed") }

    static var lotUnitKind: String { t("lot.unitKind") }

    static var lotStatusActive: String { t("lot.status.active") }

    static var lotStatusDepleted: String { t("lot.status.depleted") }

    static var lotStatusExpired: String { t("lot.status.expired") }

    static var lotStatusDiscarded: String { t("lot.status.discarded") }

    static var lotStorageFridge: String { t("lot.storage.fridge") }

    static var lotStorageNightstand: String { t("lot.storage.nightstand") }

    static var lotStorageCabinet: String { t("lot.storage.cabinet") }

    static var lotStorageOther: String { t("lot.storage.other") }

    static func lotUnitName(_ kind: String) -> String { t("lot.unit.\(kind)") }

    static var inventory_reconcileTitle: String { t("inventory.reconcileTitle") }

    static var inventory_reportTitle: String { t("inventory.reportTitle") }

    static var inventory_reportBlocked: String { t("inventory.reportBlocked") }

    static var inventory_reportFact: String { t("inventory.reportFact") }

    static var planUnreadable: String { t("plan.unreadable") }

    static func inventoryApproxDays(_ days: Int) -> String {
        t("inventory.approxDays").replacingOccurrences(of: "%d", with: String(days))
    }

    static func inventoryReconcileTitle(_ name: String) -> String {
        t("inventory.reconcileTitle").replacingOccurrences(of: "%@", with: name)
    }

    static var inventoryDualLineTitle: String { t("inventory.dualLineTitle") }

    static func inventoryExpiry(_ date: String) -> String {
        t("inventory.expiry").replacingOccurrences(of: "%@", with: date)
    }

    static var inventoryTier0: String { t("inventory.tier0") }

    static var inventoryTier7: String { t("inventory.tier7") }

    static var inventoryTier3: String { t("inventory.tier3") }

    static var inventoryReconcileEqual: String { t("inventory.reconcileEqual") }

    static func inventoryReconcileMore(_ d: String) -> String {
        t("inventory.reconcileMore").replacingOccurrences(of: "%@", with: d)
    }

    static func inventoryReconcileLess(_ d: String) -> String {
        t("inventory.reconcileLess").replacingOccurrences(of: "%@", with: d)
    }

    static var inventoryConfirmWrite: String { t("inventory.confirmWrite") }

    static func inventoryMonthlySuffix(_ period: String) -> String {
        t("inventory.monthlySuffix").replacingOccurrences(of: "%@", with: period)
    }

    static var planListTitle: String { t("plan.listTitle") }

    static var planDetailTitle: String { t("plan.detailTitle") }

    static var planNotFound: String { t("plan.notFound") }

    static var planLoadFailed: String { t("plan.loadFailed") }

    static var planWeekStrip: String { t("plan.weekStrip") }

    static var planTodayDoses: String { t("plan.todayDoses") }

    static var planNoTodayDose: String { t("plan.noTodayDose") }

    static var planAdviceText: String { t("plan.adviceText") }

    static var planAdviceSource: String { t("plan.adviceSource") }

    static var planPause: String { t("plan.pause") }

    static var planResume: String { t("plan.resume") }

    static var planEnd: String { t("plan.end") }

    static var planEndedNote: String { t("plan.endedNote") }

    static var planHistory: String { t("plan.history") }

    static var planEndConfirmTitle: String { t("plan.endConfirm.title") }

    static var planEndConfirmBody: String { t("plan.endConfirm.body") }

    static var planEndDoctor: String { t("plan.endReason.doctor") }

    static var planEndCourse: String { t("plan.endReason.course") }

    static var planEndAdverse: String { t("plan.endReason.adverse") }

    static var planEndNoLonger: String { t("plan.endReason.noLonger") }

    static var planEndOther: String { t("plan.endReason.other") }

    static var planEventStarted: String { t("plan.event.started") }

    static var planEventEdited: String { t("plan.event.edited") }

    static var planEventPaused: String { t("plan.event.paused") }

    static var planEventResumed: String { t("plan.event.resumed") }

    static var planActionTaken: String { t("plan.action.taken") }

    static var planActionSkipped: String { t("plan.action.skipped") }

    static var planActionMissed: String { t("plan.action.missed") }

    static var planActionDiscomfort: String { t("plan.action.discomfort") }

    static var planActionSnoozed: String { t("plan.action.snoozed") }

    static var planActionPending: String { t("plan.action.pending") }

    static var planStatusActive: String { t("plan.status.active") }

    static var planStatusPaused: String { t("plan.status.paused") }

    static var planStatusEnded: String { t("plan.status.ended") }

    static var planBackfillTitle: String { t("plan.backfill.title") }

    static var planBackfillActualTime: String { t("plan.backfill.actualTime") }

    static var planBackfillNoBaseline: String { t("plan.backfill.noBaseline") }

    static var planFormSaveFailed: String { t("plan.form.saveFailed") }

    static var planFormSaveFailedHint: String { t("plan.form.saveFailedHint") }

    static var planFormTitle: String { t("plan.form.title") }

    static var planFormMedication: String { t("plan.form.medication") }

    static var planFormGenericName: String { t("plan.form.genericName") }

    static var planFormBrandName: String { t("plan.form.brandName") }

    static var planFormSpec: String { t("plan.form.spec") }

    static var planFormDosePerTake: String { t("plan.form.dosePerTake") }

    static var planFormDoseParseError: String { t("plan.form.doseParseError") }

    static var planFormTimesPerDay: String { t("plan.form.timesPerDay") }

    static var planFormRoute: String { t("plan.form.route") }

    static var planFormMeal: String { t("plan.form.meal") }

    static var planFormSchedule: String { t("plan.form.schedule") }

    static var planFormFixedTimes: String { t("plan.form.fixedTimes") }

    static var planFormAsNeeded: String { t("plan.form.asNeeded") }

    static var planFormStartDate: String { t("plan.form.startDate") }

    static var planFormHasEndDate: String { t("plan.form.hasEndDate") }

    static var planFormEndDate: String { t("plan.form.endDate") }

    static var planFormLongTerm: String { t("plan.form.longTerm") }

    static var planFormSource: String { t("plan.form.source") }

    static var planFormHospital: String { t("plan.form.hospital") }

    static var planFormDoctor: String { t("plan.form.doctor") }

    static var planFormAdvice: String { t("plan.form.advice") }

    static var planFormLotSection: String { t("plan.form.lot.section") }

    static var planFormLotUnit: String { t("plan.form.lot.unit") }

    static var planFormExpireUnknown: String { t("plan.form.lot.expireUnknown") }

    static var planFormExpireDate: String { t("plan.form.lot.expireDate") }

    static var planFormStorageNote: String { t("plan.form.lot.storageNote") }

    static var planFormLotHint: String { t("plan.form.lot.hint") }

    static var lotUnitTablet: String { t("lot.unit.tablet") }

    static var lotUnitCapsule: String { t("lot.unit.capsule") }

    static var lotUnitPatch: String { t("lot.unit.patch") }

    static var lotUnitVial: String { t("lot.unit.vial") }

    static var planAdd: String { t("plan.add") }
}
