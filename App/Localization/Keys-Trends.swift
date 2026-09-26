// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var trendTitle: String { t("trend.title") }

    static var trendRangeUnavailable: String { t("trend.range.unavailable") }

    static var trendExcludedShowOnChart: String { t("trend.excluded.showOnChart") }

    static var trendExcludedHideFromChart: String { t("trend.excluded.hideFromChart") }

    static var trendExcludedAllExcluded: String { t("trend.excluded.allExcluded") }

    static var trendOpenSource: String { t("trend.openSource") }

    static var trendExcludePoint: String { t("trend.point.exclude") }

    static var trendRestorePoint: String { t("trend.point.restore") }

    static var trendSelfMeasured: String { t("trend.origin.self") }

    static var trendEmptyTitle: String { t("trend.empty.title") }

    static var trendLoadFailed: String { t("trend.loadFailed") }

    static var trendEmptyHint: String { t("trend.empty.hint") }

    static var trendAxisStart: String { t("trend.axis.start") }

    static var trendAxisEnd: String { t("trend.axis.end") }

    static var trendAxisLower: String { t("trend.axis.lower") }

    static var trendAxisUpper: String { t("trend.axis.upper") }

    static var trendAxisTime: String { t("trend.axis.time") }

    static var trendAxisValue: String { t("trend.axis.value") }

    static var trendAxisSelected: String { t("trend.axis.selected") }

    static func trendExcludedAccessibility(_ v: String) -> String {
        t("trend.excluded.accessibility").replacingOccurrences(of: "%@", with: v)
    }

    static var trendBandUnlabeled: String { t("trend.band.unlabeled") }

    static var trendOriginSelfDevice: String { t("trend.origin.selfDevice") }

    static var trendOriginDevice: String { t("trend.origin.device") }

    static var trendOriginLegend: String { t("trend.origin.legend") }

    static var trendNotConnectedHealth: String { t("trend.notConnected.health") }

    static var trendNotConnectedHint: String { t("trend.notConnected.hint") }

    static var trendGoConnect: String { t("trend.goConnect") }

    static var trendOriginHospital: String { t("trend.origin.hospital") }

    static var trendWindowLabel: String { t("trend.window.label") }

    static var trendPeriodPrevious: String { t("trend.period.prev") }

    static var trendPeriodNext: String { t("trend.period.next") }

    static var trendPeriodJumpToLatest: String { t("trend.period.jumpToLatest") }

    static var trendPeriodLocating: String { t("trend.period.locating") }

    static var trendSleepTitle: String { t("trend.sleep.title") }

    static var trendSleepLegend: String { t("trend.sleep.legend") }

    static var trendRowExcludedSuffix: String { t("trend.row.excludedSuffix") }

    static var trendOriginSelfShort: String { t("trend.origin.selfShort") }

    static var trendOriginHospitalShort: String { t("trend.origin.hospitalShort") }

    static func trendConvertedFrom(_ note: String) -> String {
        t("trend.convertedFrom").replacingOccurrences(of: "%@", with: note)
    }
}
