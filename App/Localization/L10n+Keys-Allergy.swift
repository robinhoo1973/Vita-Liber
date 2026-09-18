// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static var allergyTitle: String { t("allergy.title") }

    static var allergyEmpty: String { t("allergy.empty") }

    static var allergyEmptyHint: String { t("allergy.emptyHint") }

    static var allergySelfReportBadge: String { t("allergy.selfReportBadge") }

    static func allergySeverity(_ s: String) -> String {
        t("allergy.severity.\(SevereReactionRules.displaySeverity(s))")
    }

    static func allergyKindName(_ v: String) -> String { t("allergy.kind.\(v)") }

    static func allergyTagName(_ v: String) -> String { t("allergy.tag.\(v)") }

    static var allergyDelete: String { t("allergy.delete") }

    static var allergySaveFailed: String { t("allergy.saveFailed") }

    static var allergySaveFailedHint: String { t("allergy.saveFailedHint") }

    static var allergyDeleteConfirmTitle: String { t("allergy.deleteConfirmTitle") }

    static var allergyDeleteConfirmHint: String { t("allergy.deleteConfirmHint") }

    static var allergyCreateTitle: String { t("allergy.createTitle") }

    static var allergyStep1: String { t("allergy.step1") }

    static var allergyStep2: String { t("allergy.step2") }

    static var allergyStep3: String { t("allergy.step3") }

    static var allergyKind: String { t("allergy.kind") }

    static var allergySubstancePlaceholder: String { t("allergy.substancePlaceholder") }

    static var allergyCustomTag: String { t("allergy.customTag") }

    static var allergySeverityLabel: String { t("allergy.severityLabel") }

    static var allergyOccurredAt: String { t("allergy.occurredAt") }

    static var allergyNote: String { t("allergy.note") }

    static var allergyNext: String { t("allergy.next") }

    static var allergyEmergencyTitle: String { t("allergy.emergency.title") }

    static var allergyEmergencyBody: String { t("allergy.emergency.body") }

    static var allergyEmergencyGoHospital: String { t("allergy.emergency.goHospital") }

    static var allergyAdd: String { t("allergy.add") }
}
