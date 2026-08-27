import Foundation

/// **文案唯一出口**（tech-spec §3 / CLAUDE.md「Strings are zh-Hans + zh-Hant via L10n」）。
///
/// 纪律：视图里不得出现面向用户的中文字面量，一律经 `L10n.xxx`。
/// 每个 key 必须同时存在于 zh-Hans / zh-Hant / en 三个 .strings 文件——
/// 由 SU-M15-L10N 套件断言三文件键集一致（缺一即红）。
///
/// **当前范围（M1.5）**：nav 五项 + M1.5 新增文案已键化；M1a–M1c 的历史文案
/// 仍是内联字面量，属 §11 清偿项「L10n 硬编码」，按 dev-pm §8.6 归属 M1c 全量走查，
/// 实际滞留至今——本批建立机制与门禁，存量迁移随 M2 分批清偿。
/// 机制先于存量：没有单出口和键集门禁，边补边漏，永远收不了口。
enum L10n {

    // MARK: - 导航（ui-ux §9）
    static var navHome: String { t("nav.home") }
    static var navRecords: String { t("nav.records") }
    static var navReminders: String { t("nav.reminders") }
    static var navAI: String { t("nav.ai") }
    static var navMe: String { t("nav.me") }

    // MARK: - F7 趋势（SP-13 / FR7.2）
    static var trendTitle: String { t("trend.title") }
    static var trendRangeUnavailable: String { t("trend.range.unavailable") }
    static var trendShowExcluded: String { t("trend.excluded.toggle") }
    static var trendExcludedHeader: String { t("trend.excluded.header") }
    static var trendOpenSource: String { t("trend.openSource") }
    static var trendExcludePoint: String { t("trend.point.exclude") }
    static var trendRestorePoint: String { t("trend.point.restore") }
    static var trendSelfMeasured: String { t("trend.origin.self") }

    // MARK: - FR17.13 标准语音输入模板
    static var voiceConfirmTitle: String { t("voice.confirm.title") }
    static var voiceConfirmPending: String { t("voice.confirm.pending") }
    static var voiceConfirmLowConfidence: String { t("voice.confirm.lowConfidence") }
    static var voiceConfirmSave: String { t("voice.confirm.save") }
    static var voiceConfirmRetry: String { t("voice.confirm.retry") }
    static var voiceConfirmCancel: String { t("voice.confirm.cancel") }
    static var voiceSpeakAloud: String { t("voice.speak.button") }
    static var voiceScreenCheckHint: String { t("voice.speak.screenHint") }
    static var voiceBystanderWarning: String { t("voice.speak.bystander") }
    static var voiceAskSpeak: String { t("voice.ask.speak") }
    static var voiceAskScreen: String { t("voice.ask.screen") }
    static var voiceRouteHeadphonesOn: String { t("voice.route.headphonesOn") }
    static var voiceRouteHeadphonesOff: String { t("voice.route.headphonesOff") }

    // MARK: - FR17.12 隐私与耳机须知
    static var voicePrivacyTitle: String { t("voice.privacy.title") }
    static var voicePrivacyPoint1: String { t("voice.privacy.p1") }
    static var voicePrivacyPoint2: String { t("voice.privacy.p2") }
    static var voicePrivacyPoint3: String { t("voice.privacy.p3") }
    static var voicePrivacyPoint4: String { t("voice.privacy.p4") }
    static var voicePrivacyAccept: String { t("voice.privacy.accept") }
    static var voicePrivacyUseTouch: String { t("voice.privacy.useTouch") }

    // MARK: - FR13.11 iCloud 备份
    static var backupTitle: String { t("backup.title") }
    static var backupCreate: String { t("backup.create") }
    static var backupRestore: String { t("backup.restore") }
    static var backupNotSignedIn: String { t("backup.degrade.notSignedIn") }
    static var backupNoSpace: String { t("backup.degrade.noSpace") }
    static var backupChecksumFailed: String { t("backup.degrade.checksum") }

    /// 全部已键化的 key（SU-M15-L10N 遍历断言的输入）。
    /// 新增 key 必须同步登记到这里——否则门禁扫不到，又回到「缺证据当有证据」。
    static let registeredKeys: [String] = [
        "nav.home", "nav.records", "nav.reminders", "nav.ai", "nav.me",
        "trend.title", "trend.range.unavailable", "trend.excluded.toggle",
        "trend.excluded.header", "trend.openSource", "trend.point.exclude",
        "trend.point.restore", "trend.origin.self",
        "voice.confirm.title", "voice.confirm.pending", "voice.confirm.lowConfidence",
        "voice.confirm.save", "voice.confirm.retry", "voice.confirm.cancel",
        "voice.speak.button", "voice.speak.screenHint", "voice.speak.bystander",
        "voice.ask.speak", "voice.ask.screen",
        "voice.route.headphonesOn", "voice.route.headphonesOff",
        "voice.privacy.title", "voice.privacy.p1", "voice.privacy.p2",
        "voice.privacy.p3", "voice.privacy.p4",
        "voice.privacy.accept", "voice.privacy.useTouch",
        "backup.title", "backup.create", "backup.restore",
        "backup.degrade.notSignedIn", "backup.degrade.noSpace", "backup.degrade.checksum",
    ]

    /// 支持的本地化（三文件纪律）
    static let supportedLocalizations = ["zh-Hans", "zh-Hant", "en"]

    private static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
