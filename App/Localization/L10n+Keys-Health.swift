// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var healthSearchPrompt: String { t("health.searchPrompt") }

    static var healthConnectDevice: String { t("health.connectDevice") }

    static var healthConnectButton: String { t("health.connectButton") }

    static var alertEmptyTitle: String { t("alert.empty.title") }

    static var alertEmptyHint: String { t("alert.empty.hint") }

    static func alertOpenSource(_ ref: String) -> String {
        t("alert.openSource").replacingOccurrences(of: "%@", with: ref)
    }

    static func alertSeverity(_ level: String) -> String {
        t("alert.severity").replacingOccurrences(of: "%@", with: level)
    }

    static var alertOpenOriginal: String { t("alert.openOriginal") }

    static var alertEvidencePathRetest: String { t("alert.evidencePath.retest") }

    static var alertEvidencePathVisit: String { t("alert.evidencePath.visit") }

    static var alertEvidencePathObserve: String { t("alert.evidencePath.observe") }

    static var alertEvidenceDisclaimer: String { t("alert.evidenceDisclaimer") }

    static func alertLinkChecked(_ date: String) -> String {
        t("alert.linkChecked").replacingOccurrences(of: "%@", with: date)
    }

    static var alertSourceTitle: String { t("alert.sourceTitle") }

    static var healthImportSettingsTitle: String { t("health.settingsTitle") }

    static var healthAutoImport: String { t("health.autoImport") }

    static var healthReadPermissionHint: String { t("health.readPermissionHint") }

    static var healthImportedData: String { t("health.importedData") }

    static var healthImportedDataHint: String { t("health.importedDataHint") }

    static var healthAppleSource: String { t("health.appleSource") }

    static var healthViewTrendChart: String { t("health.viewTrendChart") }

    static var healthViewTrendChartHint: String { t("health.viewTrendChartHint") }

    static var healthImportedRecordsSection: String { t("health.importedRecordsSection") }

    static var healthCandidateSection: String { t("health.candidate.section") }

    static var healthCandidateHint: String { t("health.candidate.hint") }

    static var healthCandidateAdopt: String { t("health.candidate.adopt") }

    static var healthCandidateBirthDate: String { t("health.candidate.birthDate") }

    static var healthCandidateGender: String { t("health.candidate.gender") }

    static var healthWriteBackLabel: String { t("health.writeBack.label") }

    static var healthWriteBackSection: String { t("health.writeBack.section") }

    static var healthWriteBackHint: String { t("health.writeBack.hint") }

    static var healthWriteBackGranted: String { t("health.writeBack.granted") }

    static var healthWriteBackDenied: String { t("health.writeBack.denied") }

    static var healthWriteBackNeedAuth: String { t("health.writeBack.needAuth") }

    static var healthWriteBackRetryAuth: String { t("health.writeBack.retryAuth") }

    static var healthWriteBackFailed: String { t("health.writeBack.failed") }

    static var healthUnavailable: String { t("health.unavailable") }

    static var healthOwnerMissing: String { t("health.ownerMissing") }

    static var healthRequestIncomplete: String { t("health.requestIncomplete") }

    static var healthImportedEmpty: String { t("health.importedEmpty") }

    static var metricOverviewTitle: String { t("metric.overview.title") }

    static var metricOverviewEmpty: String { t("metric.overview.empty") }

    static var metricOverviewEmptyHint: String { t("metric.overview.emptyHint") }

    static var metricEntryTitle: String { t("metric.entry.title") }

    static var metricStep1: String { t("metric.step1") }

    static var metricStep2: String { t("metric.step2") }

    static func metricName(_ m: MetricType) -> String { t("metric.name.\(m.rawValue)") }

    static var metricSelfMeasureNote: String { t("metric.selfMeasureNote") }

    static var metricSys: String { t("metric.sys") }

    static var metricDia: String { t("metric.dia") }

    static var metricValue: String { t("metric.value") }

    static var metricUnit: String { t("metric.unit") }

    static var metricMeasuredAt: String { t("metric.measuredAt") }

    static var metricSaved: String { t("metric.saved") }

    static var metricEntryErrorTitle: String { t("metric.entryError.title") }

    static var metricInvalidValue: String { t("metric.entryError.invalid") }

    static var metricOutOfRange: String { t("metric.entryError.range") }

    static var metricSaveFailed: String { t("metric.entryError.saveFailed") }

    static var metricViewTrend: String { t("metric.viewTrend") }

    static var f16Title: String { t("f16.title") }

    static var f16AuthSection: String { t("f16.authSection") }

    static var f16AuthHint: String { t("f16.authHint") }

    static var f16RequestAuth: String { t("f16.requestAuth") }

    static var f16AuthGranted: String { t("f16.authGranted") }

    static var f16AuthDisabled: String { t("f16.authDisabled") }

    static var f16AuthFailed: String { t("f16.authFailed") }

    static var f16AuthDenied: String { t("f16.authDenied") }

    static var f16SyncSection: String { t("f16.syncSection") }

    static var f16SyncHint: String { t("f16.syncHint") }

    static var f16SyncNow: String { t("f16.syncNow") }

    static var f16Syncing: String { t("f16.syncing") }

    static var f16SyncFailed: String { t("f16.syncFailed") }

    static var healthNoReadableData: String { t("health.noReadableData") }

    static var healthImportMore: String { t("health.importMore") }

    static var healthNotificationRetry: String { t("health.notificationRetry") }

    static var healthMedicalReviewPending: String { t("health.medicalReviewPending") }

    static func healthAggregation(_ aggregation: MetricAggregation) -> String {
        t("health.aggregation.\(aggregation.rawValue)")
    }

    static var healthShowLegacy: String { t("health.showLegacy") }

    static var healthHistoricalEvaluation: String { t("health.historicalEvaluation") }

    static var healthLoadMore: String { t("health.loadMore") }

    static func healthMetricName(_ key: String) -> String {
        guard let metric = MetricType(grammarKey: key) else { return t("health.metric.unknown") }
        return metricName(metric)
    }

    static var healthOpenHelp: String { t("health.openHelp") }

    static var alertFilterAll: String { t("alert.filter.all") }

    static var alertShowL0: String { t("alert.showL0") }

    static var alert_historyEntry: String { t("alert.historyEntry") }
}
