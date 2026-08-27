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

    static var inventory_title: String { t("inventory.title") }
    static var inventory_empty: String { t("inventory.empty") }
    static var inventory_emptyHint: String { t("inventory.emptyHint") }
    static var inventory_approxDays: String { t("inventory.approxDays") }
    static var inventory_noPlanHint: String { t("inventory.noPlanHint") }
    static var inventory_fixCount: String { t("inventory.fixCount") }
    static var inventory_reconcileTitle: String { t("inventory.reconcileTitle") }
    static var inventory_reportTitle: String { t("inventory.reportTitle") }
    static var inventory_reportBlocked: String { t("inventory.reportBlocked") }
    static var inventory_reportFact: String { t("inventory.reportFact") }
    static var emergency_title: String { t("emergency.title") }
    static var emergency_bloodType: String { t("emergency.bloodType") }
    static var emergency_allergy: String { t("emergency.allergy") }
    static var emergency_meds: String { t("emergency.meds") }
    static var emergency_health: String { t("emergency.health") }
    static var emergency_contacts: String { t("emergency.contacts") }
    static var emergency_notSet: String { t("emergency.notSet") }
    static var emergency_sos_hold: String { t("emergency.sos.hold") }
    static var emergency_sos_confirmPrompt: String { t("emergency.sos.confirmPrompt") }
    static var emergency_sos_confirm: String { t("emergency.sos.confirm") }
    static var emergency_sos_cancel: String { t("emergency.sos.cancel") }
    static var care_title: String { t("care.title") }
    static var care_footer: String { t("care.footer") }
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
    static var deeplink_title: String { t("deeplink.title") }
    static var deeplink_jump: String { t("deeplink.jump") }
    static var deeplink_open: String { t("deeplink.open") }
    static var deeplink_notFound: String { t("deeplink.notFound") }
    static var deeplink_bookingNo: String { t("deeplink.bookingNo") }
    static var deeplink_saveNo: String { t("deeplink.saveNo") }
    static var helpcard_title: String { t("helpcard.title") }
    static var helpcard_selectHint: String { t("helpcard.selectHint") }
    static var helpcard_photoOptIn: String { t("helpcard.photoOptIn") }
    static var helpcard_contentNote: String { t("helpcard.contentNote") }
    static var helpcard_generate: String { t("helpcard.generate") }

    static var f19_sessionTitle: String { t("f19.sessionTitle") }
    static var f19_launch: String { t("f19.launch") }
    static var f19_listeningHint: String { t("f19.listeningHint") }
    static var f19_typeHint: String { t("f19.typeHint") }
    static var f19_end: String { t("f19.end") }
    static var f19_sayAgainHint: String { t("f19.sayAgainHint") }
    static var f19_confirm: String { t("f19.confirm") }
    static var f19_cancel: String { t("f19.cancel") }
    static var f19_rejectedTitle: String { t("f19.rejectedTitle") }
    static var f19_goTouch: String { t("f19.goTouch") }
    static var f19_stopped: String { t("f19.stopped") }
    static var f19_paused: String { t("f19.paused") }

        static var fr24_title: String { t("fr24.title") }
    static var fr24_empty: String { t("fr24.empty") }
    static var fr24_emptyHint: String { t("fr24.emptyHint") }
    static var fr24_recipient: String { t("fr24.recipient") }
    static var fr24_kindHelpCard: String { t("fr24.kindHelpCard") }
    static var fr24_kindSos: String { t("fr24.kindSos") }
    static var fr24_statusSent: String { t("fr24.statusSent") }
    static var fr24_statusAckPending: String { t("fr24.statusAckPending") }
    static var fr24_statusAcked: String { t("fr24.statusAcked") }
    static var fr24_statusTimeout: String { t("fr24.statusTimeout") }
    static var hub_healthRecords: String { t("hub.healthRecords") }
    static var hub_guidelines: String { t("hub.guidelines") }
    static var hub_helpCardOpen: String { t("hub.helpCardOpen") }

        static var settings_authTitle: String { t("settings.authTitle") }
    static var settings_habits: String { t("settings.habits") }
    static var settings_pro: String { t("settings.pro") }
    static var settings_privacy: String { t("settings.privacy") }
    static var settings_about: String { t("settings.about") }
    static var settings_remindAdvance: String { t("settings.remindAdvance") }
    static var settings_snooze: String { t("settings.snooze") }
    static var settings_quietHours: String { t("settings.quietHours") }
    static var settings_disclaimer: String { t("settings.disclaimer") }
    static var settings_proUpgrade: String { t("settings.proUpgrade") }
    static var settings_audit: String { t("settings.audit") }
    static var settings_restoreDefaults: String { t("settings.restoreDefaults") }
    static var settings_help: String { t("settings.help") }
    static var settings_careMode: String { t("settings.careMode") }
    static var settings_voiceEntry: String { t("settings.voiceEntry") }
    static var reminder_emptyAppt: String { t("reminder.emptyAppt") }
    static var reminder_takenCount: String { t("reminder.takenCount") }
    static var reminder_taken: String { t("reminder.taken") }
    static var reminder_later: String { t("reminder.later") }
    static var reminder_skip: String { t("reminder.skip") }
    static var ai_confirmImageText: String { t("ai.confirmImageText") }
    static var ai_emergencyAction: String { t("ai.emergencyAction") }
    static var ai_aiBadge: String { t("ai.aiBadge") }
    static var ai_citations: String { t("ai.citations") }
    static var ai_source: String { t("ai.source") }
    static var ai_uncertain: String { t("ai.uncertain") }
    static var ai_askDoctor: String { t("ai.askDoctor") }

    static func settingsRemindAdvance(_ v: String) -> String {
        t("settings.remindAdvance").replacingOccurrences(of: "%@", with: v)
    }
    static func settingsSnooze(_ v: String) -> String {
        t("settings.snooze").replacingOccurrences(of: "%@", with: v)
    }
    static func settingsQuietHours(_ a: String, _ b: String) -> String {
        String(format: t("settings.quietHours"), a, b)   // 位置参数 %1$@ / %2$@
    }
    static func reminderTakenCount(_ a: Int, _ b: Int) -> String {
        String(format: t("reminder.takenCount"), a, b)   // 位置参数 %1$d / %2$d
    }
    static func aiUncertain(_ v: String) -> String {
        t("ai.uncertain").replacingOccurrences(of: "%@", with: v)
    }
    static func aiAskDoctor(_ v: String) -> String {
        t("ai.askDoctor").replacingOccurrences(of: "%@", with: v)
    }

        static var onboard_pinProgress: String { t("onboard.pinProgress") }
    static var onboard_yourName: String { t("onboard.yourName") }
    static var onboard_saveEdit: String { t("onboard.saveEdit") }
    static var onboard_timelineTitle: String { t("onboard.timelineTitle") }
    static var onboard_confirmAllTimeline: String { t("onboard.confirmAllTimeline") }
    static var onboard_createContinue: String { t("onboard.createContinue") }
    static var onboard_cancel: String { t("onboard.cancel") }
    static var onboard_finishEnterApp: String { t("onboard.finishEnterApp") }
    static var onboard_aimPrescription: String { t("onboard.aimPrescription") }
    static var onboard_confirmed: String { t("onboard.confirmed") }
    static var onboard_buildProfile: String { t("onboard.buildProfile") }
    static var onboard_scanSample: String { t("onboard.scanSample") }
    static var onboard_capturePrescription: String { t("onboard.capturePrescription") }
    static var onboard_trendTitle: String { t("onboard.trendTitle") }
    static var onboard_newValue: String { t("onboard.newValue") }
    static var onboard_ocrDisclaimer: String { t("onboard.ocrDisclaimer") }
    static var onboard_pinPurpose: String { t("onboard.pinPurpose") }
    static var onboard_gotIt: String { t("onboard.gotIt") }
    static var onboard_confirm: String { t("onboard.confirm") }
    static var onboard_timelineHint: String { t("onboard.timelineHint") }
    static var onboard_confirmResult: String { t("onboard.confirmResult") }
    static var onboard_later: String { t("onboard.later") }
    static var onboard_observation: String { t("onboard.observation") }
    static var onboard_setPin: String { t("onboard.setPin") }
    static var onboard_voiceNote: String { t("onboard.voiceNote") }
    static var onboard_ownerNote: String { t("onboard.ownerNote") }
    static var onboard_enterPin: String { t("onboard.enterPin") }
    static var onboard_pinLockHint: String { t("onboard.pinLockHint") }
    static var onboard_unconfirmedBadge: String { t("onboard.unconfirmedBadge") }
    static var help_appName: String { t("help.appName") }
    static var help_tagline: String { t("help.tagline") }
    static var help_title: String { t("help.title") }
    static var help_faqPlaceholder: String { t("help.faqPlaceholder") }
    static var help_disclaimer: String { t("help.disclaimer") }
    static var help_version: String { t("help.version") }
    static var help_privacyPlaceholder: String { t("help.privacyPlaceholder") }
    static var pay_busy: String { t("pay.busy") }
    static var pay_restore: String { t("pay.restore") }
    static var pay_valueProp: String { t("pay.valueProp") }
    static var pay_buy: String { t("pay.buy") }

        static var member_title: String { t("member.title") }
    static var member_add: String { t("member.add") }
    static var member_current: String { t("member.current") }
    static var member_switch: String { t("member.switch") }
    static var member_namePlaceholder: String { t("member.namePlaceholder") }
    static var member_relation: String { t("member.relation") }
    static var member_birthDatePlaceholder: String { t("member.birthDatePlaceholder") }
    static var member_save: String { t("member.save") }
    static var member_quotaHint: String { t("member.quotaHint") }
    static var member_addedHint: String { t("member.addedHint") }

        /// 全部已键化的 key（SU-M15-L10N 遍历断言的输入）。
    /// 新增 key 必须同步登记到这里——否则门禁扫不到，又回到「缺证据当有证据」。
    /// 参数化文案（避免把格式串散落视图）
    static func inventoryApproxDays(_ days: Int) -> String {
        t("inventory.approxDays").replacingOccurrences(of: "%d", with: String(days))
    }
    static func inventoryReconcileTitle(_ name: String) -> String {
        t("inventory.reconcileTitle").replacingOccurrences(of: "%@", with: name)
    }
    static func deeplinkJump(_ hospital: String) -> String {
        t("deeplink.jump").replacingOccurrences(of: "%@", with: hospital)
    }
    static func f19RepeatObject(_ obj: String) -> String {
        t("f19.repeatObject").replacingOccurrences(of: "%@", with: obj)
    }
    static func f19Executed(_ command: String) -> String {
        t("f19.executed").replacingOccurrences(of: "%@", with: command)
    }
    static func deeplinkOpen(_ hospital: String) -> String {
        t("deeplink.open").replacingOccurrences(of: "%@", with: hospital)
    }

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
        "inventory.title",
        "inventory.empty",
        "inventory.emptyHint",
        "inventory.approxDays",
        "inventory.noPlanHint",
        "inventory.fixCount",
        "inventory.reconcileTitle",
        "inventory.reportTitle",
        "inventory.reportBlocked",
        "inventory.reportFact",
        "emergency.title",
        "emergency.bloodType",
        "emergency.allergy",
        "emergency.meds",
        "emergency.health",
        "emergency.contacts",
        "emergency.notSet",
        "emergency.sos.hold",
        "emergency.sos.confirmPrompt",
        "emergency.sos.confirm",
        "emergency.sos.cancel",
        "care.title",
        "care.footer",
        "claim.title",
        "claim.empty",
        "claim.emptyHint",
        "claim.add",
        "claim.type.invoice",
        "claim.type.fee",
        "claim.type.receipt",
        "immunization.title",
        "immunization.empty",
        "immunization.emptyHint",
        "immunization.confirmed",
        "immunization.pending",
        "immunization.note",
        "deeplink.title",
        "deeplink.jump",
        "deeplink.open",
        "deeplink.notFound",
        "deeplink.bookingNo",
        "deeplink.saveNo",
        "helpcard.title",
        "helpcard.selectHint",
        "helpcard.photoOptIn",
        "helpcard.contentNote",
        "helpcard.generate",
        "f19.sessionTitle",
        "f19.launch",
        "f19.listeningHint",
        "f19.typeHint",
        "f19.end",
        "f19.sayAgainHint",
        "f19.confirm",
        "f19.cancel",
        "f19.rejectedTitle",
        "f19.goTouch",
        "f19.stopped",
        "f19.paused"
    ]

    /// 支持的本地化（三文件纪律）
    static let supportedLocalizations = ["zh-Hans", "zh-Hant", "en"]

    private static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
