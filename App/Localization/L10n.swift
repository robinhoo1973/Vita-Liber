import Foundation
import Domain   // ObservationKind 等枚举名映射（Domain 类型不上 UI，名称走本单出口）

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
    // FR17.10/FR10.2 语音提醒澄清提示（两处调用共用，禁止各写一份字面量）
    static var voiceReminderTimeUnclear: String { t("voice.reminder.timeUnclear") }
    static var voiceReminderTimeUnheard: String { t("voice.reminder.timeUnheard") }

    // FR1.1 · V3.22 生物识别门禁（SP-01 锁屏遮罩）
    static var security_unlockTitle: String { t("security.unlockTitle") }
    static var security_unlockSubtitle: String { t("security.unlockSubtitle") }
    static var security_unlockButton: String { t("security.unlockButton") }
    static var security_unlockReason: String { t("security.unlockReason") }
    static var security_unlockFailed: String { t("security.unlockFailed") }
    // BR-007/FR1.9 敏感媒体解锁理由（LocalAuthentication localizedReason）
    static var sensitive_unlockReason: String { t("sensitive.unlockReason") }

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
    // FR13.4 导出前身份验证 + 隐私提醒 / FR13.5 恢复前确认 + 恢复后校验报告
    static var backupUnlockReason: String { t("backup.unlockReason") }
    static var backupExportConfirmTitle: String { t("backup.exportConfirm.title") }
    static var backupExportConfirmBody: String { t("backup.exportConfirm.body") }
    static var backupRestoreConfirmTitle: String { t("backup.restoreConfirm.title") }
    static var backupRestoreConfirmBody: String { t("backup.restoreConfirm.body") }
    static func backupRestoredCount(_ n: Int) -> String { String(format: t("backup.restoredCountFmt"), n) }

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
    // 关怀模式「生效参数」摘要区（M2 设置页；评审补——此前为视图内联中文字面量，
    // L0 [10/10] L10n 门禁真违规；迁入三文件后 zh-Hant/en 平价交付）
    static var care_parameters_section: String { t("care.parameters.section") }
    static var care_parameters_touchTarget: String { t("care.parameters.touchTarget") }
    static var care_parameters_speechRate: String { t("care.parameters.speechRate") }
    static var care_parameters_readback: String { t("care.parameters.readback") }
    static var care_parameters_voiceInput: String { t("care.parameters.voiceInput") }
    static var care_parameters_sos: String { t("care.parameters.sos") }
    static var care_parameters_valueSlow: String { t("care.parameters.valueSlow") }
    static var care_parameters_valueAskEachTime: String { t("care.parameters.valueAskEachTime") }
    static var care_parameters_valueDefaultOn: String { t("care.parameters.valueDefaultOn") }
    /// 插值串（String(format:) 取 %ld；zh-Hans/Hant 的「长按 N 秒」骨架一致）
    static func care_parameters_sosValue(seconds: Int) -> String {
        String(format: t("care.parameters.sosValue"), seconds)
    }
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
    // FR14.4 外观与主题（§5.12.1 / tech-spec §5.28.1）
    static var settings_appearance: String { t("settings.appearance") }
    static var settings_themeLight: String { t("settings.themeLight") }
    static var settings_themeDark: String { t("settings.themeDark") }
    static var settings_themeSystem: String { t("settings.themeSystem") }
    static var settings_highContrast: String { t("settings.highContrast") }
    static var settings_highContrastFooter: String { t("settings.highContrastFooter") }
    static var reminder_emptyAppt: String { t("reminder.emptyAppt") }
    static var reminder_takenCount: String { t("reminder.takenCount") }
    static var reminder_taken: String { t("reminder.taken") }
    static var reminder_later: String { t("reminder.later") }
    static var reminder_skip: String { t("reminder.skip") }
    // 药名缺省词与动态 accessibilityLabel（评审补——此前为行内插值 + 中文字面量，
    // L0 [10/10] 门禁新判定器命中；模板用 %@，药名由调用方保证不含未转义 %）
    static var reminder_medicationFallback: String { t("reminder.medicationFallback") }
    static func reminder_a11yTaken(name: String) -> String { String(format: t("reminder.a11yTaken"), name) }
    static func reminder_a11ySnoozed(name: String) -> String { String(format: t("reminder.a11ySnoozed"), name) }
    static func reminder_a11ySkipped(name: String) -> String { String(format: t("reminder.a11ySkipped"), name) }
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
    static var onboard_gotIt: String { t("onboard.gotIt") }
    static var onboard_confirm: String { t("onboard.confirm") }
    static var onboard_timelineHint: String { t("onboard.timelineHint") }
    static var onboard_confirmResult: String { t("onboard.confirmResult") }
    static var onboard_later: String { t("onboard.later") }
    static var onboard_voiceNote: String { t("onboard.voiceNote") }
    static var onboard_ownerNote: String { t("onboard.ownerNote") }
    static var onboard_unconfirmedBadge: String { t("onboard.unconfirmedBadge") }
    static var help_appName: String { t("help.appName") }
    static var help_tagline: String { t("help.tagline") }
    static var help_title: String { t("help.title") }
    static var help_faqPlaceholder: String { t("help.faqPlaceholder") }
    static var help_disclaimer: String { t("help.disclaimer") }
    static var help_version: String { t("help.version") }
    /// 三部件版本：Version <Release> Build <CI序号> Code Hash <提交哈希>（FR22.8 / dev-pm §9.3）
    static func helpVersion(_ version: String, _ build: String, _ hash: String) -> String {
        String(format: t("help.versionFormat"), version, build, hash)   // %1$@ %2$@ %3$@
    }
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

        static var proOutput_title: String { t("proOutput.title") }

        static func doseNumber(_ n: Int) -> String { String(format: t("dose.number"), n) }
    static func onboardReviseTitle(_ label: String) -> String {
        t("onboard.reviseTitle").replacingOccurrences(of: "%@", with: label)
    }
    static func onboardOcrRaw(_ text: String) -> String {
        t("onboard.ocrRaw").replacingOccurrences(of: "%@", with: text)
    }
    static func onboardTierUnconfirmed(_ tier: String) -> String {
        t("onboard.tierUnconfirmed").replacingOccurrences(of: "%@", with: tier)
    }
    static func onboardConfirmedCount(_ a: Int, _ b: Int) -> String {
        String(format: t("onboard.confirmedCount"), a, b)
    }
    static func onboardRevisionHistory(_ history: String) -> String {
        t("onboard.revisionHistory").replacingOccurrences(of: "%@", with: history)
    }
    static var onboard_sourceConfirmed: String { t("onboard.sourceConfirmed") }
    static var onboard_unconfirmed2: String { t("onboard.unconfirmed2") }

        static var reminder_today: String { t("reminder.today") }
    static var reminder_loading: String { t("reminder.loading") }
    static var reminder_todayEmpty: String { t("reminder.todayEmpty") }
    static var reminder_addPlan: String { t("reminder.addPlan") }
    static var reminder_appointments: String { t("reminder.appointments") }
    static var reminder_addAppt: String { t("reminder.addAppt") }
    static var reminder_completeAppt: String { t("reminder.completeAppt") }
    static var reminder_statusScheduled: String { t("reminder.statusScheduled") }
    static var reminder_statusCompleted: String { t("reminder.statusCompleted") }
    static var reminder_statusCancelled: String { t("reminder.statusCancelled") }
    static var reminder_statusMissed: String { t("reminder.statusMissed") }
    static var reminder_planName: String { t("reminder.planName") }
    static var reminder_planSpec: String { t("reminder.planSpec") }
    static var reminder_planTime: String { t("reminder.planTime") }
    static var reminder_save: String { t("reminder.save") }
    static var voiceguide_reminderTitle: String { t("voiceguide.reminderTitle") }
    static var voiceguide_reminderExample: String { t("voiceguide.reminderExample") }
    static var voiceguide_transcript: String { t("voiceguide.transcript") }
    static var voiceguide_buildDraft: String { t("voiceguide.buildDraft") }
    static var voiceguide_stepOf: String { t("voiceguide.stepOf") }
    static var voiceguide_skip: String { t("voiceguide.skip") }
    static var voiceguide_next: String { t("voiceguide.next") }
    static var voiceguide_answerHint: String { t("voiceguide.answerHint") }
    static var voiceguide_profileTitle: String { t("voiceguide.profileTitle") }
    static var voiceguide_micTitle: String { t("voiceguide.micTitle") }
    static var voiceguide_micPrompt: String { t("voiceguide.micPrompt") }
    static var voiceguide_micPhrase: String { t("voiceguide.micPhrase") }
    static var voiceguide_micTooLow: String { t("voiceguide.micTooLow") }
    static var voiceguide_micSkip: String { t("voiceguide.micSkip") }
    static var voiceguide_micPass: String { t("voiceguide.micPass") }
    static var voiceguide_noteAllergy: String { t("voiceguide.note.allergy") }
    static var voiceguide_noteHistory: String { t("voiceguide.note.history") }
    static var voiceguide_noteMeds: String { t("voiceguide.note.meds") }
    static var voiceguide_noteContact: String { t("voiceguide.note.contact") }
    static var voiceFieldDate: String { t("voice.field.date") }
    static var voiceFieldHour: String { t("voice.field.hour") }
    static var voiceFieldRepeat: String { t("voice.field.repeat") }
    static var voiceFieldContent: String { t("voice.field.content") }
    static var voiceConfirmFillHint: String { t("voice.confirm.fillHint") }
    static var voiceguide_saved: String { t("voiceguide.saved") }
    static var voiceguide_promptAllergy: String { t("voiceguide.promptAllergy") }
    static var voiceguide_promptHistory: String { t("voiceguide.promptHistory") }
    static var voiceguide_promptMeds: String { t("voiceguide.promptMeds") }
    static var voiceguide_promptContact: String { t("voiceguide.promptContact") }
    static func voiceguideStep(_ a: Int, _ b: Int) -> String {
        String(format: t("voiceguide.stepOf"), a, b)
    }

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

    // MARK: - L10n 清偿批五 · SP-24 备份（FR13.2）
    static var backupScopeNote: String { t("backup.scopeNote") }
    static func backupExportedName(_ name: String) -> String {
        t("backup.exportedName").replacingOccurrences(of: "%@", with: name)
    }
    static func backupChecksum(_ digest: String) -> String {
        t("backup.checksum").replacingOccurrences(of: "%@", with: digest)
    }
    static var backupRestored: String { t("backup.restored") }

    // MARK: - L10n 清偿批五 · F7 趋势图轴与图例（SP-13 / FR7.2）
    static var trendEmptyTitle: String { t("trend.empty.title") }
    static var trendEmptyHint: String { t("trend.empty.hint") }
    static var trendAxisStart: String { t("trend.axis.start") }
    static var trendAxisEnd: String { t("trend.axis.end") }
    static var trendAxisLower: String { t("trend.axis.lower") }
    static var trendAxisUpper: String { t("trend.axis.upper") }
    static var trendAxisTime: String { t("trend.axis.time") }
    static var trendAxisValue: String { t("trend.axis.value") }
    static var trendAxisSelected: String { t("trend.axis.selected") }
    static func trendBandAccessibility(_ source: String, _ lo: String, _ hi: String) -> String {
        String(format: t("trend.band.accessibility"), source, lo, hi)   // %1$@ %2$@ %3$@
    }
    static func trendExcludedAccessibility(_ v: String) -> String {
        t("trend.excluded.accessibility").replacingOccurrences(of: "%@", with: v)
    }
    static func trendChartAccessibility(_ metric: String, _ points: Int, _ bands: Int) -> String {
        String(format: t("trend.chart.accessibility"), metric, points, bands)
    }
    static func trendBandLegend(_ source: String, _ lo: String, _ hi: String) -> String {
        String(format: t("trend.band.legend"), source, lo, hi)   // %1$@ %2$@ %3$@
    }
    static var trendOriginSelfDevice: String { t("trend.origin.selfDevice") }
    static var trendOriginHospital: String { t("trend.origin.hospital") }
    static func trendRefRange(_ lo: String, _ hi: String) -> String {
        String(format: t("trend.refRange"), lo, hi)   // %1$@ %2$@
    }
    static func trendRowAccessibility(_ v: String, _ unit: String, _ source: String, _ time: String) -> String {
        String(format: t("trend.row.accessibility"), v, unit, source, time)
    }
    static var trendRowExcludedSuffix: String { t("trend.row.excludedSuffix") }
    static var trendOriginSelfShort: String { t("trend.origin.selfShort") }
    static var trendOriginHospitalShort: String { t("trend.origin.hospitalShort") }
    static func trendConvertedFrom(_ note: String) -> String {
        t("trend.convertedFrom").replacingOccurrences(of: "%@", with: note)
    }
    static var trendShowExcludedAccessibility: String { t("trend.showExcluded.accessibility") }

    // MARK: - L10n 清偿批五 · 语音速记（SP-59 / FR17.14）
    static var voicenoteEmptyTitle: String { t("voicenote.empty.title") }
    static var voicenoteEmptyHint: String { t("voicenote.empty.hint") }
    static var voicenoteInTimeline: String { t("voicenote.inTimeline") }
    static var voicenoteDraftPlaceholder: String { t("voicenote.draft.placeholder") }
    static var voicenoteDraftAccessibility: String { t("voicenote.draft.accessibility") }
    static var voicenoteSaveAccessibility: String { t("voicenote.save.accessibility") }
    static var voicenoteTitle: String { t("voicenote.title") }

    // MARK: - L10n 清偿批五 · 观察（SP-14 / F8）
    static func observationGroupSummary(_ count: Int, _ mark: String) -> String {
        String(format: t("observation.groupSummary"), count, mark)   // %1$d %2$@
    }
    static var observationTrendImproved: String { t("observation.trend.improved") }
    static var observationTrendUnchanged: String { t("observation.trend.unchanged") }
    static var observationTrendWorsened: String { t("observation.trend.worsened") }
    // MARK: - 评审批 · F8 观察页与创建页（SP-14 硬编码中文字面量清偿）
    static var observationTitle: String { t("observation.title") }
    static var observationSectionTitle: String { t("observation.listSection") }
    static var observationAllergySection: String { t("observation.allergySection") }
    static var observationCreateTitle: String { t("observation.createTitle") }
    static var observationKindSection: String { t("observation.kindSection") }
    static var observationDescription: String { t("observation.description") }
    static var observationSelfMark: String { t("observation.selfMark") }
    static func observationMediaBadge(_ n: Int) -> String {
        String(format: t("observation.mediaBadge"), n)   // %1$d
    }
    // MARK: - 评审批 · F8 八类观察类型（FR8.1：Domain ObservationKind 枚举 → 名称映射；
    // 未知 key 兜底「其他」本地化串，rawValue 一律不上屏）
    static func observationKindName(_ kind: ObservationKind) -> String {
        switch kind {
        case .stool: return t("observation.kind.stool")
        case .urine: return t("observation.kind.urine")
        case .skin: return t("observation.kind.skin")
        case .eye: return t("observation.kind.eye")
        case .secretion: return t("observation.kind.secretion")
        case .swelling: return t("observation.kind.swelling")
        case .generic: return t("observation.kind.generic")
        case .custom: return t("observation.kind.custom")
        }
    }
    static func observationKindName(forKey key: String) -> String {
        ObservationKind(rawValue: key).map(observationKindName) ?? t("observation.kind.unknown")
    }
    // MARK: - 评审批 · F8.4 敏感媒体（SP-14 步骤2）
    static var observationMediaSection: String { t("observation.media.section") }
    static var observationMediaAddAlbum: String { t("observation.media.addAlbum") }
    static var observationMediaAddCamera: String { t("observation.media.addCamera") }
    static func observationMediaCount(_ n: Int) -> String {
        String(format: t("observation.media.count"), n)   // %1$d
    }
    // MARK: - 评审批 · FR8.9/FR17.14 语音速记纯转写入口（共用听写按钮）
    static var voicenoteDictation: String { t("voicenote.dictation") }
    static var voicenoteDictating: String { t("voicenote.dictating") }
    static var voicenoteDictationFailed: String { t("voicenote.dictationFailed") }
    // MARK: - 评审批 · 文档详情与导出（SP-10 / 5.6）
    static var docDetailTitle: String { t("doc.detailTitle") }
    static var docFieldsSection: String { t("doc.fieldsSection") }
    static var docExport: String { t("doc.export") }
    static var docTitleSection: String { t("doc.titleSection") }
    static var docDate: String { t("doc.date") }
    static var docHistorySection: String { t("doc.historySection") }
    static var onboard_observationAdd: String { t("onboard.observationAdd") }

    // MARK: - L10n 清偿批五 · Pro 产出预览（F23）
    static func proPreviewNote(_ product: String) -> String {
        t("pro.previewNote").replacingOccurrences(of: "%@", with: product)
    }

    // MARK: - L10n 清偿批五 · 预警与信源（F16）
    static var alertEmptyTitle: String { t("alert.empty.title") }
    static var alertEmptyHint: String { t("alert.empty.hint") }
    static func alertOpenSource(_ ref: String) -> String {
        t("alert.openSource").replacingOccurrences(of: "%@", with: ref)
    }
    static func alertSeverity(_ level: String) -> String {
        t("alert.severity").replacingOccurrences(of: "%@", with: level)
    }
    static var alertOpenOriginal: String { t("alert.openOriginal") }
    static func alertLinkChecked(_ date: String) -> String {
        t("alert.linkChecked").replacingOccurrences(of: "%@", with: date)
    }
    static var alertSourceTitle: String { t("alert.sourceTitle") }

    // MARK: - L10n 清偿批五 · 急救卡（F15）
    static var emergencyWriteTitle: String { t("emergency.write.title") }
    static var emergencyWriteSubtitle: String { t("emergency.write.subtitle") }
    static var emergencyViewGuide: String { t("emergency.viewGuide") }
    static var emergencySectionAllergy: String { t("emergency.section.allergy") }
    static var emergencySectionMeds: String { t("emergency.section.meds") }
    static var emergencySectionHealth: String { t("emergency.section.health") }
    static var emergencySectionContacts: String { t("emergency.section.contacts") }
    static var emergencySelectTitle: String { t("emergency.select.title") }
    static var emergencyNoCandidates: String { t("emergency.noCandidates") }
    static var emergencySelected: String { t("emergency.selected") }
    static var emergencyUnselected: String { t("emergency.unselected") }

    // MARK: - L10n 清偿批五 · 疫苗接种（FR4.5 / SP-54）
    static var immunizationVaccineName: String { t("immunization.vaccineName") }
    static var immunizationDate: String { t("immunization.date") }
    static var immunizationProvider: String { t("immunization.provider") }
    static var immunizationLotField: String { t("immunization.lotField") }
    static var immunizationCreateTitle: String { t("immunization.createTitle") }
    static func immunizationLot(_ lot: String) -> String {
        t("immunization.lot").replacingOccurrences(of: "%@", with: lot)
    }

    // MARK: - L10n 清偿批五 · 通用动作
    static var commonSave: String { t("common.save") }
    static var commonCancel: String { t("common.cancel") }

    // MARK: - L10n 清偿批五 · 双轨库存（FR9.8）
    static func inventoryDualLine(_ plan: String, _ unit: String, _ confirmed: String) -> String {
        String(format: t("inventory.dualLine"), plan, unit, confirmed)   // %1$@ %2$@ · %3$@ %2$@
    }
    static func inventoryExpiry(_ date: String) -> String {
        t("inventory.expiry").replacingOccurrences(of: "%@", with: date)
    }
    static var inventoryTier14: String { t("inventory.tier14") }
    static var inventoryTier7: String { t("inventory.tier7") }
    static var inventoryTier3: String { t("inventory.tier3") }
    static func inventoryBookValue(_ v: String, _ unit: String) -> String {
        String(format: t("inventory.bookValue"), v, unit)   // %1$@ %2$@
    }
    static func inventoryPhysical(_ v: String, _ unit: String) -> String {
        String(format: t("inventory.physical"), v, unit)   // %1$@ %2$@
    }
    static var inventoryReconcileEqual: String { t("inventory.reconcileEqual") }
    static func inventoryReconcileMore(_ d: String) -> String {
        t("inventory.reconcileMore").replacingOccurrences(of: "%@", with: d)
    }
    static func inventoryReconcileLess(_ d: String) -> String {
        t("inventory.reconcileLess").replacingOccurrences(of: "%@", with: d)
    }
    static func inventoryReconcileConfirm(_ v: String, _ unit: String) -> String {
        String(format: t("inventory.reconcileConfirm"), v, unit)   // %1$@ %2$@
    }
    static var inventoryConfirmWrite: String { t("inventory.confirmWrite") }
    static func inventoryMonthlySuffix(_ period: String) -> String {
        t("inventory.monthlySuffix").replacingOccurrences(of: "%@", with: period)
    }

    // MARK: - L10n 清偿批五 · 用药求助卡（FR24.5）
    static func helpcardRemaining(_ v: String, _ unit: String) -> String {
        String(format: t("helpcard.remaining"), v, unit)   // %1$@ %2$@
    }
    static var helpcardPhotoSection: String { t("helpcard.photoSection") }

    // MARK: - L10n 清偿批五 · AI 助手（F12）
    static var ai_refusedNoEvidence: String { t("ai.refusedNoEvidence") }
    static var ai_refusedHighRisk: String { t("ai.refusedHighRisk") }
    static var ai_failedRetry: String { t("ai.failedRetry") }
    static var ai_emergencyCardText: String { t("ai.emergencyCardText") }
    static var ai_emergencyTitle: String { t("ai.emergencyTitle") }
    static var ai_emergencyCall: String { t("ai.emergencyCall") }
    static var timelineEmptyTitle: String { t("timeline.empty.title") }
    static var paywallPreviewTitle: String { t("paywall.previewTitle") }

    static let registeredKeys: [String] = [
        "help.versionFormat",
        "ai.aiBadge", "ai.askDoctor", "ai.citations", "ai.confirmImageText",
        "ai.emergencyAction", "ai.emergencyCall", "ai.emergencyTitle", "paywall.previewTitle", "timeline.empty.title",
        "ai.emergencyCardText", "ai.failedRetry", "ai.refusedHighRisk",
        "ai.refusedNoEvidence",
        "ai.source", "ai.uncertain", "alert.empty.hint", "alert.empty.title",
        "alert.linkChecked", "alert.openOriginal", "alert.openSource", "alert.severity",
        "alert.sourceTitle", "backup.checksum", "backup.create", "backup.degrade.checksum",
        "backup.degrade.noSpace", "backup.degrade.notSignedIn", "backup.exportedName", "backup.restore",
        "backup.restored", "backup.scopeNote", "backup.title", "care.footer",
        "care.parameters.readback", "care.parameters.section", "care.parameters.sos",
        "care.parameters.sosValue", "care.parameters.speechRate", "care.parameters.touchTarget",
        "care.parameters.valueAskEachTime", "care.parameters.valueDefaultOn", "care.parameters.valueSlow",
        "care.parameters.voiceInput",
        "care.title", "claim.add", "claim.empty", "claim.emptyHint",
        "claim.title", "claim.type.fee", "claim.type.invoice", "claim.type.receipt",
        "common.cancel", "common.save", "deeplink.bookingNo", "deeplink.jump",
        "deeplink.notFound", "deeplink.open", "deeplink.saveNo", "deeplink.title",
        "dose.number", "emergency.allergy", "emergency.bloodType", "emergency.contacts",
        "emergency.health", "emergency.meds", "emergency.noCandidates", "emergency.notSet",
        "emergency.section.allergy", "emergency.section.contacts", "emergency.section.health", "emergency.section.meds",
        "emergency.select.title", "emergency.selected", "emergency.sos.cancel", "emergency.sos.confirm",
        "emergency.sos.confirmPrompt", "emergency.sos.hold", "emergency.title", "emergency.unselected",
        "emergency.viewGuide", "emergency.write.subtitle", "emergency.write.title", "f19.cancel",
        "f19.confirm", "f19.end", "f19.executed", "f19.goTouch",
        "f19.launch", "f19.listeningHint", "f19.paused", "f19.rejectedTitle",
        "f19.repeatObject", "f19.sayAgainHint", "f19.sessionTitle", "f19.stopped",
        "f19.typeHint", "fr24.empty", "fr24.emptyHint", "fr24.kindHelpCard",
        "fr24.kindSos", "fr24.recipient", "fr24.statusAckPending", "fr24.statusAcked",
        "fr24.statusSent", "fr24.statusTimeout", "fr24.title", "help.appName",
        "help.disclaimer", "help.faqPlaceholder", "help.privacyPlaceholder", "help.tagline",
        "help.title", "help.version", "helpcard.contentNote", "helpcard.generate",
        "helpcard.photoOptIn", "helpcard.photoSection", "helpcard.remaining", "helpcard.selectHint",
        "helpcard.title", "hub.guidelines", "hub.healthRecords", "hub.helpCardOpen",
        "immunization.confirmed", "immunization.createTitle", "immunization.date", "immunization.empty",
        "immunization.emptyHint", "immunization.lot", "immunization.lotField", "immunization.note",
        "immunization.pending", "immunization.provider", "immunization.title", "immunization.vaccineName",
        "inventory.approxDays", "inventory.bookValue", "inventory.confirmWrite", "inventory.dualLine",
        "inventory.empty", "inventory.emptyHint", "inventory.expiry", "inventory.fixCount",
        "inventory.monthlySuffix", "inventory.noPlanHint", "inventory.physical", "inventory.reconcileConfirm",
        "inventory.reconcileEqual", "inventory.reconcileLess", "inventory.reconcileMore", "inventory.reconcileTitle",
        "inventory.reportBlocked", "inventory.reportFact", "inventory.reportTitle", "inventory.tier14",
        "inventory.tier3", "inventory.tier7", "inventory.title", "member.add",
        "member.addedHint", "member.birthDatePlaceholder", "member.current", "member.namePlaceholder",
        "member.quotaHint", "member.relation", "member.save", "member.switch",
        "member.title", "nav.ai", "nav.home", "nav.me",
        "nav.records", "nav.reminders", "observation.allergySection",
        "observation.createTitle", "observation.description", "observation.groupSummary", "observation.kind.custom",
        "observation.kind.eye", "observation.kind.generic", "observation.kind.secretion", "observation.kind.skin",
        "observation.kind.stool", "observation.kind.swelling", "observation.kind.unknown", "observation.kind.urine", "observation.kindSection",
        "observation.listSection",
        "observation.media.addAlbum", "observation.media.addCamera", "observation.media.count", "observation.media.section",
        "observation.mediaBadge", "observation.selfMark", "observation.title",
        "observation.trend.improved", "observation.trend.unchanged", "observation.trend.worsened",
        "onboard.aimPrescription", "onboard.buildProfile", "onboard.cancel",
        "onboard.capturePrescription", "onboard.confirm", "onboard.confirmAllTimeline", "onboard.confirmResult",
        "onboard.confirmed", "onboard.confirmedCount", "onboard.createContinue",
        "onboard.finishEnterApp", "onboard.gotIt", "onboard.later", "onboard.newValue",
        "onboard.observationAdd", "onboard.ocrDisclaimer", "onboard.ocrRaw", "onboard.ownerNote",
        "onboard.reviseTitle",
        "onboard.revisionHistory", "onboard.saveEdit", "onboard.scanSample",
        "onboard.sourceConfirmed", "onboard.tierUnconfirmed", "onboard.timelineHint", "onboard.timelineTitle",
        "onboard.trendTitle", "onboard.unconfirmed2", "onboard.unconfirmedBadge", "onboard.voiceNote",
        "onboard.yourName", "pay.busy", "pay.buy", "pay.restore",
        "pay.valueProp", "pro.previewNote", "proOutput.title",
        "reminder.a11ySkipped", "reminder.a11ySnoozed", "reminder.a11yTaken", "reminder.medicationFallback",
        "reminder.addAppt",
        "reminder.addPlan", "reminder.appointments", "reminder.completeAppt", "reminder.emptyAppt",
        "reminder.later", "reminder.loading", "reminder.planName", "reminder.planSpec",
        "reminder.planTime", "reminder.save", "reminder.skip", "reminder.statusCancelled",
        "reminder.statusCompleted", "reminder.statusMissed", "reminder.statusScheduled", "reminder.taken",
        "reminder.takenCount", "reminder.today", "reminder.todayEmpty",
        "security.unlockTitle", "security.unlockSubtitle", "security.unlockButton",
        "security.unlockReason", "security.unlockFailed", "sensitive.unlockReason",
        "settings.about",
        "settings.audit", "settings.authTitle", "settings.careMode", "settings.disclaimer",
        "settings.habits", "settings.help", "settings.privacy", "settings.pro",
        "settings.proUpgrade", "settings.quietHours", "settings.remindAdvance", "settings.restoreDefaults",
        "settings.snooze", "settings.voiceEntry",
        "settings.appearance", "settings.themeLight", "settings.themeDark", "settings.themeSystem",
        "settings.highContrast", "settings.highContrastFooter", "trend.axis.end", "trend.axis.lower",
        "trend.axis.selected", "trend.axis.start", "trend.axis.time", "trend.axis.upper",
        "trend.axis.value", "trend.band.accessibility", "trend.band.legend", "trend.chart.accessibility",
        "trend.convertedFrom", "trend.empty.hint", "trend.empty.title", "trend.excluded.accessibility",
        "trend.excluded.header", "trend.excluded.toggle", "trend.openSource", "trend.origin.hospital",
        "trend.origin.hospitalShort", "trend.origin.self", "trend.origin.selfDevice", "trend.origin.selfShort",
        "trend.point.exclude", "trend.point.restore", "trend.range.unavailable", "trend.refRange",
        "trend.row.accessibility", "trend.row.excludedSuffix", "trend.showExcluded.accessibility", "trend.title",
        "voice.ask.screen", "voice.ask.speak", "voice.confirm.cancel", "voice.confirm.lowConfidence",
        "voice.confirm.pending", "voice.confirm.retry", "voice.confirm.save", "voice.confirm.title",
        "voice.privacy.accept", "voice.privacy.p1", "voice.privacy.p2", "voice.privacy.p3",
        "voice.privacy.p4", "voice.privacy.title", "voice.privacy.useTouch", "voice.reminder.timeUnclear", "voice.reminder.timeUnheard",
        "voice.route.headphonesOff",
        "voice.route.headphonesOn", "voice.speak.button", "voice.speak.bystander", "voice.speak.screenHint",
        "voiceguide.answerHint", "voiceguide.buildDraft", "voiceguide.next", "voiceguide.profileTitle",
        "voiceguide.promptAllergy", "voiceguide.promptContact", "voiceguide.promptHistory", "voiceguide.promptMeds",
        "voiceguide.reminderExample", "voiceguide.reminderTitle", "voiceguide.skip", "voiceguide.stepOf",
        "voiceguide.transcript", "voicenote.draft.accessibility", "voicenote.draft.placeholder", "voicenote.empty.hint",
        "voicenote.empty.title", "voicenote.inTimeline", "voicenote.save.accessibility", "voicenote.title",
        "voicenote.dictation", "voicenote.dictating", "voicenote.dictationFailed",
        "doc.date", "doc.detailTitle", "doc.export", "doc.fieldsSection", "doc.historySection", "doc.titleSection",
        "help.status.checking", "help.status.authorized", "help.status.denied", "help.status.notRequested",
        "help.status.unknown", "help.status.provisional", "help.center.title", "help.diag.permission",
        "help.diag.reminder", "help.diag.dataHealth", "help.diag.system", "help.diag.systemHint",
        "help.about.legal", "help.perm.section", "help.perm.camera", "help.perm.mic", "help.perm.notification",
        "help.perm.openSettings", "help.perm.deniedHint", "help.faceID.requiresDevice", "help.reminder.section",
        "help.reminder.permission", "help.reminder.todaySection", "help.reminder.pendingDoses",
        "help.reminder.todaySlots", "help.reminder.deniedHint", "help.data.dbSection", "help.data.integrity",
        "help.data.normal", "help.data.storageSection", "help.data.dbSize", "help.data.calculating",
        "help.data.backupSection", "help.data.lastBackup", "help.data.noBackup", "help.data.title",
        "help.about.licenses", "help.about.section", "help.legal.section", "help.terms.title", "help.section",
        "caregiver.title", "caregiver.empty", "caregiver.emptyHint", "caregiver.pendingFmt",
        "caregiver.alertTitle", "caregiver.alertConfirm", "caregiver.alertBodyFmt",
        "disclosure.title", "disclosure.acknowledge",
        "backup.unlockReason", "backup.exportConfirm.title", "backup.exportConfirm.body",
        "backup.restoreConfirm.title", "backup.restoreConfirm.body", "backup.restoredCountFmt",
        "sos.help.title", "sos.call120", "sos.noContacts", "sos.viewCard", "sos.sendLocationP1",
        "home.greeting", "home.todayTodos", "home.pendingOcrCountFmt", "home.expiringSoon",
        "home.refill", "home.alertSummary", "home.recentObs", "home.quickCapture",
        "home.capture.record", "home.capture.report", "home.capture.prescription", "home.capture.symptom",
        "home.guide1", "home.guide2", "home.guide3", "home.memberSwitch",
        "home.notifDenied", "home.notifOpen", "home.care.meds", "home.care.refill",
        "home.care.capture", "home.care.sos", "home.doseSlot", "home.stockBacklogFmt",
        "nc.title", "nc.section.pending", "nc.section.appointment", "nc.section.expiry",
        "nc.section.alert", "nc.section.ocr", "nc.nextAction.dose", "nc.confirmDose",
        "nc.expireDateFmt", "nc.ocrCountFmt", "nc.empty", "nc.emptyHint",
        "search.title", "search.placeholder", "search.placeholderHint", "search.noResultFmt",
        "search.loosenHint", "search.clear", "search.group.docs", "search.group.observations",
        "search.group.meds", "search.obsLocked",
        "language.title", "language.footer", "voiceLang.title", "voiceLang.inputSection",
        "voiceLang.inputHint", "voiceLang.outputSection", "voiceLang.outputHint",
        "voiceLang.bestEffort", "voiceLang.fallback", "voiceLang.mix", "voiceLang.mixHint",
        "reminder.allTaken", "reminder.allTakenConfirm", "reminder.allTakenYes",
        "reminder.snooze15", "reminder.snooze30", "reminder.snooze60",
        "reminder.forgot", "reminder.discomfort", "reminder.discomfortPlaceholder",
        "reminder.skipReason.none", "reminder.skipReason.forgot", "reminder.skipReason.doctor",
        "reminder.skipReason.other", "reminder.moreActions",
        "plan.listTitle", "plan.detailTitle", "plan.notFound", "plan.weekStrip",
        "plan.todayDoses", "plan.noTodayDose", "plan.adviceText", "plan.adviceSource",
        "plan.pause", "plan.resume", "plan.end", "plan.endedNote", "plan.history",
        "plan.endConfirm.title", "plan.endConfirm.body",
        "plan.endReason.doctor", "plan.endReason.course", "plan.endReason.adverse",
        "plan.endReason.noLonger", "plan.endReason.other",
        "plan.event.started", "plan.event.edited", "plan.event.paused", "plan.event.resumed",
        "plan.event.ended", "plan.event.endedReasonFmt",
        "plan.action.taken", "plan.action.skipped", "plan.action.missed",
        "plan.action.discomfort", "plan.action.snoozed", "plan.action.pending",
        "plan.status.active", "plan.status.paused", "plan.status.ended",
        "plan.backfill.title", "plan.backfill.actualTime",
        "plan.form.title", "plan.form.medication", "plan.form.genericName", "plan.form.brandName",
        "plan.form.spec", "plan.form.dosePerTake", "plan.form.timesPerDay", "plan.form.route",
        "plan.form.meal", "plan.form.schedule", "plan.form.fixedTimes", "plan.form.asNeeded",
        "plan.form.startDate", "plan.form.hasEndDate", "plan.form.endDate", "plan.form.longTerm",
        "plan.form.source", "plan.form.hospital", "plan.form.doctor", "plan.form.advice",
        "plan.form.lot.section", "plan.form.lot.unitsFmt", "plan.form.lot.unit",
        "plan.form.lot.expireUnknown", "plan.form.lot.expireDate", "plan.form.lot.storageNote",
        "plan.form.lot.hint",
        "lot.unit.tablet", "lot.unit.capsule", "lot.unit.patch", "lot.unit.vial",
        "knowledge.title", "knowledge.advice", "knowledge.adviceBadge", "knowledge.noAdvice",
        "knowledge.storage", "knowledge.storageHint", "knowledge.caution", "knowledge.cautionText",
        "encounter.kind.outpatient", "encounter.kind.emergency", "encounter.kind.inpatient",
        "encounter.kind.checkup", "encounter.kind.telemedicine", "encounter.kind.followup",
        "encounter.listTitle", "encounter.empty", "encounter.emptyHint", "encounter.untitled",
        "encounter.docCountFmt", "encounter.detailTitle", "encounter.diagnosisAdvice",
        "encounter.diagnosisBadge", "encounter.adviceBadge", "encounter.followUp",
        "encounter.linkedDocs", "encounter.noDocs", "encounter.docTitleFmt",
        "encounter.recommend.section", "encounter.recommend.pending", "encounter.link",
        "encounter.generateSummary", "encounter.summary.title", "encounter.summary.header",
        "encounter.summary.unconfirmed", "encounter.summary.allConfirmed",
        "encounter.summary.docFieldsFmt", "encounter.summary.note", "encounter.summary.noteText",
        "encounter.form.title", "encounter.form.basic", "encounter.form.kind", "encounter.form.date",
        "encounter.form.hospital", "encounter.form.department", "encounter.form.doctor",
        "encounter.form.clinical", "encounter.form.complaint", "encounter.form.diagnosis",
        "encounter.form.advice", "encounter.form.followUp", "encounter.form.fee",
        "timeline.title", "timeline.emptyTitle", "timeline.emptyHint", "timeline.filter.all",
        "timeline.kind.encounter", "timeline.kind.medication", "timeline.kind.observation",
        "timeline.kind.lab", "timeline.kind.selfMeasured", "timeline.kind.vaccination",
        "timeline.kind.allergy", "timeline.kind.voiceNote", "timeline.kind.healthProblem",
        "timeline.problemsFilter",
        "problem.title", "problem.empty", "problem.emptyHint", "problem.createTitle",
        "problem.namePlaceholder", "problem.merge", "problem.mergeTitle", "problem.mergeIntoFmt",
        "problem.mergeHint", "problem.archive", "problem.unarchive",
        "prep.title", "prep.patient", "prep.bloodType", "prep.meds", "prep.observations",
        "prep.questions", "prep.noData", "prep.noQuestions", "prep.daysLeftFmt", "prep.disclaimer",
        "question.title", "question.placeholder", "question.markAsked",
        "appt.listTitle", "appt.empty", "appt.emptyHint",
        "appt.status.scheduled", "appt.status.completed", "appt.status.cancelled", "appt.status.missed",
        "appt.reschedule", "appt.cancel", "appt.complete", "appt.followUpHint", "appt.newDate",
        "appt.cancelReason.none", "appt.cancelReason.doctor", "appt.cancelReason.self",
        "appt.cancelReason.other",
        "appt.form.title", "appt.form.basic", "appt.form.address", "appt.form.date",
        "appt.form.prep", "appt.form.items", "appt.form.notes", "appt.form.followUpRule",
        "appt.followUpRule.0", "appt.followUpRule.1", "appt.followUpRule.2",
        "appt.followUpRule.3", "appt.followUpRule.4", "appt.followUpDaysFmt",
        "appt.followUpConcreteDate", "appt.followUpDraftOnly",
        "member.detail.basic", "member.detail.more", "member.bloodType", "member.idNo",
        "member.insuranceNo", "member.note", "member.delete", "member.selfNoDelete",
        "member.delete.impact", "member.delete.impactDocs", "member.delete.impactObs",
        "member.delete.impactPlans", "member.delete.impactAppts", "member.delete.keepDocs",
        "member.delete.planChoice", "member.delete.plans", "member.archivePlans",
        "member.delete.confirm", "member.delete.confirmPlaceholderFmt", "member.delete.confirmButton",
        "member.confirm.belongsTo", "member.confirm.switch", "member.relation.self",
        "docLibrary.title", "docLibrary.empty", "docLibrary.emptyHint", "docLibrary.untitled",
        "doc.archive", "doc.unarchive", "doc.favorite", "doc.unfavorite",
        "doc.importSource.title", "doc.importSource.camera", "doc.importSource.file",
        "doc.importSource.photos", "doc.importSource.manual",
        "doc.duplicate.title", "doc.duplicate.keepBoth", "doc.duplicate.discard",
        "doc.duplicate.hintFmt", "doc.importFailed.title", "doc.importFailed",
        "doc.pdfImportFailed", "doc.type.report", "doc.type.record",
        "doc.manual.createTitle", "doc.manual.title", "doc.manual.type", "doc.manual.note",
        "onboard.rejected", "onboard.rejectLabelFmt", "onboard.revise", "onboard.reject",
        "ocrQueue.title", "ocrQueue.empty", "ocrQueue.emptyHint", "ocrQueue.countFmt",
        "ocrQueue.allConfirm", "ocrQueue.allConfirmBlocked", "ocrQueue.72h",
        "ocrQueue.jumpSource", "ocrQueue.lowConfidenceFmt", "doc.reportIssue",
        "allergy.title", "allergy.empty", "allergy.emptyHint", "allergy.selfReportBadge",
        "allergy.severity.轻", "allergy.severity.中", "allergy.severity.重",
        "allergy.severity.severe", "allergy.severity.moderate", "allergy.delete",
        "allergy.createTitle", "allergy.step1", "allergy.step2", "allergy.step3",
        "allergy.kind", "allergy.substancePlaceholder", "allergy.customTag",
        "allergy.severityLabel", "allergy.occurredAt", "allergy.note", "allergy.next",
        "allergy.emergency.title", "allergy.emergency.body", "allergy.emergency.goHospital",
        "aiHistory.title", "aiHistory.empty", "aiHistory.countFmt", "aiHistory.delete",
        "aiHistory.clearAll", "aiHistory.clearNote",
        "aiFeedback.useful", "aiFeedback.useless", "aiFeedback.citationError",
        "aiFeedback.danger", "aiFeedback.more",
        "export.wizard.title", "export.scope", "export.scope.all", "export.scope.dateRange",
        "export.scope.doctorSummary", "export.dateFrom", "export.dateTo", "export.content",
        "export.includeNotes", "export.watermark", "export.privacyHint", "export.start",
        "export.unlockReason", "export.progressFmt", "export.cancel", "export.cancelled",
        "export.failed", "export.retry", "export.finishedFmt", "export.share", "export.titleFmt",
        "backup.reminder.title", "backup.reminder.body",
        "auth.ocr", "auth.ai", "auth.family", "auth.sharing", "auth.cloudBackup",
        "auth.anonymized", "auth.health", "auth.voiceDictation", "settings.dataLifecycle",
        "pref.group.reminders", "pref.group.display", "pref.group.voice",
        "pref.tag.global", "pref.tag.newOnly", "pref.remindAdvance", "pref.snooze",
        "pref.quietStart", "pref.quietEnd", "pref.to", "pref.channel",
        "pref.channel.notifyOnly", "pref.channel.ringUntilConfirm", "pref.channel.silentBanner",
        "pref.notifPreviewMed", "pref.remindScopeNote", "pref.dateFormat", "pref.weekStart",
        "pref.unitSystem", "pref.unit.metric", "pref.unit.imperial", "pref.reduceMotion",
        "pref.homeSort", "pref.homeSort.time", "pref.homeSort.type",
        "pref.readback", "pref.readback.never", "pref.readback.ask", "pref.readback.always",
        "pref.readbackHint", "pref.restoreAll",
        "lifecycle.single", "lifecycle.singleHint", "lifecycle.member", "lifecycle.memberHint",
        "lifecycle.clearAll", "lifecycle.clearHint", "lifecycle.clearButton",
        "lifecycle.clearImpact", "lifecycle.logout", "lifecycle.logoutHint",
        "onboard.addFamily.title", "onboard.addFamily.hint", "onboard.addFamily.manual",
        "onboard.addFamily.voiceP1", "onboard.addFamily.contactsP1", "onboard.addFamily.skip",
        "onboard.addFamily.completeHint",
        "onboard.firstDay.title", "onboard.firstDay.hint", "onboard.firstDay.capture",
        "onboard.firstDay.reminder", "onboard.firstDay.ai",
        "feedback.title", "feedback.category",
        "feedback.category.0", "feedback.category.1", "feedback.category.2",
        "feedback.category.3", "feedback.category.4", "feedback.category.5",
        "feedback.detail", "feedback.detailPlaceholder", "feedback.attachments",
        "feedback.attachScreenshot", "feedback.attachOriginal", "feedback.attachMedia",
        "feedback.attachmentHint", "feedback.submit", "feedback.submitted",
        "fr24.markDelivered", "fr24.offlineNote",
        "helpcard.recipient", "helpcard.recipientOther", "helpcard.recipientPlaceholder",
        "metric.entry.title", "metric.step1", "metric.step2",
        "metric.name.bloodPressureSys", "metric.name.glucose", "metric.name.weight",
        "metric.name.heartRate", "metric.name.bloodOxygen",
        "metric.selfMeasureNote", "metric.sys", "metric.dia", "metric.value",
        "metric.unit", "metric.measuredAt", "metric.saved", "metric.viewTrend",
        "voicePanel.title", "voicePanel.hint", "voicePanel.start",
        "voiceTarget.metric", "voiceTarget.observation", "voiceTarget.question",
        "voiceTarget.ai", "voiceTarget.reminder", "voiceTarget.profile", "voiceTarget.anyText",
        "observation.followUp.set",
        "f16.title", "f16.authSection", "f16.authHint", "f16.requestAuth", "f16.authGranted",
        "f16.authDisabled", "f16.authFailed", "f16.syncSection", "f16.syncHint",
        "f16.syncNow", "f16.syncing", "f16.syncDoneFmt", "f16.syncFailed",
        "alert.filter.all", "alert.showL0", "alert.historyEntry",
        "f19.noTodayMeds", "f19.nextAppointmentFmt", "f19.noAppointment", "f19.recentGlucoseFmt",
        "f19.noGlucose", "f19.stockRemainingFmt", "f19.stockNoPlanFmt", "f19.noStock",
        "f19.stockLocationFmt", "f19.locationUnknown", "f19.noExpiring", "f19.expiringFmt",
        "f19.taken", "f19.notTaken", "f19.slotMedStateFmt", "f19.markTakenNoMatchFmt",
        "f19.markTakenDoneFmt", "f19.metricRecordedFmt", "f19.questionRecordedFmt",
        "medicalID.title", "medicalID.step1", "medicalID.step1Hint", "medicalID.step2",
        "medicalID.step2Hint", "medicalID.step3", "medicalID.step3Hint",
        "medicalID.openHealth", "medicalID.note", "settings.themeHint",
        "reminder.notification.title", "reminder.notification.body"
    ]

    // MARK: - FR14.8 Tab badge
    static var tabRemindersBadge: String { t("tab.reminders.badge") }

    // MARK: - §5.10 敏感媒体原始视图
    static var sensitiveMedia_originalTitle: String { t("sensitiveMedia.original.title") }
    static var sensitiveMedia_unlockToView: String { t("sensitiveMedia.unlockToView") }

    // MARK: - F22 帮助与诊断（FR22.1-22.4 · SP-42/43/44/45/48）
    static var helpStatusChecking: String { t("help.status.checking") }
    static var helpStatusAuthorized: String { t("help.status.authorized") }
    static var helpStatusDenied: String { t("help.status.denied") }
    static var helpStatusNotRequested: String { t("help.status.notRequested") }
    static var helpStatusUnknown: String { t("help.status.unknown") }
    static var helpStatusProvisional: String { t("help.status.provisional") }
    static var helpCenterTitle: String { t("help.center.title") }
    static var helpDiagPermission: String { t("help.diag.permission") }
    static var helpDiagReminder: String { t("help.diag.reminder") }
    static var helpDiagDataHealth: String { t("help.diag.dataHealth") }
    static var helpDiagSystem: String { t("help.diag.system") }
    static var helpDiagSystemHint: String { t("help.diag.systemHint") }
    static var helpAboutLegal: String { t("help.about.legal") }
    static var helpPermSection: String { t("help.perm.section") }
    static var helpPermCamera: String { t("help.perm.camera") }
    static var helpPermMic: String { t("help.perm.mic") }
    static var helpPermNotification: String { t("help.perm.notification") }
    static var helpPermOpenSettings: String { t("help.perm.openSettings") }
    static var helpPermDeniedHint: String { t("help.perm.deniedHint") }
    static var helpFaceIDRequiresDevice: String { t("help.faceID.requiresDevice") }
    static var helpReminderSection: String { t("help.reminder.section") }
    static var helpReminderPermission: String { t("help.reminder.permission") }
    static var helpReminderTodaySection: String { t("help.reminder.todaySection") }
    static var helpReminderPendingDoses: String { t("help.reminder.pendingDoses") }
    static var helpReminderTodaySlots: String { t("help.reminder.todaySlots") }
    static var helpReminderDeniedHint: String { t("help.reminder.deniedHint") }
    static var helpDataDbSection: String { t("help.data.dbSection") }
    static var helpDataIntegrity: String { t("help.data.integrity") }
    static var helpDataNormal: String { t("help.data.normal") }
    static var helpDataStorageSection: String { t("help.data.storageSection") }
    static var helpDataDbSize: String { t("help.data.dbSize") }
    static var helpDataCalculating: String { t("help.data.calculating") }
    static var helpDataBackupSection: String { t("help.data.backupSection") }
    static var helpDataLastBackup: String { t("help.data.lastBackup") }
    static var helpDataNoBackup: String { t("help.data.noBackup") }
    static var helpDataTitle: String { t("help.data.title") }
    static var helpAboutLicenses: String { t("help.about.licenses") }
    static var helpAboutSection: String { t("help.about.section") }
    static var helpLegalSection: String { t("help.legal.section") }
    static var helpTermsTitle: String { t("help.terms.title") }
    static var helpSection: String { t("help.section") }

    // MARK: - F24 同机照护者视图（FR24.5 · SP-57）
    static var caregiverTitle: String { t("caregiver.title") }
    static var caregiverEmpty: String { t("caregiver.empty") }
    static var caregiverEmptyHint: String { t("caregiver.emptyHint") }
    static func caregiverPending(_ time: String) -> String { String(format: t("caregiver.pendingFmt"), time) }
    static var caregiverAlertTitle: String { t("caregiver.alertTitle") }
    static var caregiverAlertConfirm: String { t("caregiver.alertConfirm") }
    static func caregiverAlertBody(patient: String, medication: String) -> String {
        String(format: t("caregiver.alertBodyFmt"), patient, medication)
    }

    // MARK: - F20 L2-L4 场景须知（SP-37）
    static var disclosureTitle: String { t("disclosure.title") }
    static var disclosureAcknowledge: String { t("disclosure.acknowledge") }

    // MARK: - FR18.6 SOS 全屏求助页（SP-33，唯一免门禁路径）
    static var sosHelpTitle: String { t("sos.help.title") }
    static var sosCall120: String { t("sos.call120") }
    static var sosNoContacts: String { t("sos.noContacts") }
    static var sosViewCard: String { t("sos.viewCard") }
    static var sosSendLocationP1: String { t("sos.sendLocationP1") }

    // MARK: - F2 首页（SP-04 · FR2.1 八卡）
    static func homeGreeting(_ name: String) -> String { String(format: t("home.greeting"), name) }
    static var homeTodayTodos: String { t("home.todayTodos") }
    static func homePendingOcrCount(_ n: Int) -> String { String(format: t("home.pendingOcrCountFmt"), n) }
    static var homeExpiringSoon: String { t("home.expiringSoon") }
    static var homeRefill: String { t("home.refill") }
    static var homeAlertSummary: String { t("home.alertSummary") }
    static var homeRecentObs: String { t("home.recentObs") }
    static var homeQuickCapture: String { t("home.quickCapture") }
    static var homeCaptureRecord: String { t("home.capture.record") }
    static var homeCaptureReport: String { t("home.capture.report") }
    static var homeCapturePrescription: String { t("home.capture.prescription") }
    static var homeCaptureSymptom: String { t("home.capture.symptom") }
    static var homeCaptureHint: String { t("home.capture.hint") }
    static var homeCaptureShoot: String { t("home.capture.shoot") }
    static var homeCaptureLibrary: String { t("home.capture.library") }
    static var homeCaptureFile: String { t("home.capture.file") }
    static var homeCaptureNoCamera: String { t("home.capture.noCamera") }
    static var homeCaptureSaved: String { t("home.capture.saved") }
    static var docTypePrescription: String { t("doc.type.prescription") }
    static var homeProfileProgressTitle: String { t("home.profileProgress") }
    static func homeProfileProgressFmt(_ done: Int, _ total: Int) -> String {
        String(format: t("home.profileProgressFmt"), done, total)   // 位置参数 %1$d / %2$d
    }
    static var homeProfileContinue: String { t("home.profileContinue") }
    static var homeDisclaimer: String { t("home.disclaimer") }
    static var timelineQuickEntry: String { t("timeline.quickEntry") }
    static var settings_offlineNote: String { t("settings.offlineNote") }
    static var homeGuide1: String { t("home.guide1") }
    static var homeGuide2: String { t("home.guide2") }
    static var homeGuide3: String { t("home.guide3") }
    static var homeMemberSwitch: String { t("home.memberSwitch") }
    static var homeNotifDenied: String { t("home.notifDenied") }
    static var homeNotifOpen: String { t("home.notifOpen") }
    static var homeCareMeds: String { t("home.care.meds") }
    static var homeCareRefill: String { t("home.care.refill") }
    static var homeCareCapture: String { t("home.care.capture") }
    static var homeCareSOS: String { t("home.care.sos") }
    static var homeDoseSlot: String { t("home.doseSlot") }
    static func homeStockBacklog(_ name: String) -> String { String(format: t("home.stockBacklogFmt"), name) }

    // MARK: - FR14.8 通知中心（SP-27）
    static var ncTitle: String { t("nc.title") }
    static var ncSectionPending: String { t("nc.section.pending") }
    static var ncSectionAppointment: String { t("nc.section.appointment") }
    static var ncSectionExpiry: String { t("nc.section.expiry") }
    static var ncSectionAlert: String { t("nc.section.alert") }
    static var ncSectionOcr: String { t("nc.section.ocr") }
    static var ncNextActionDose: String { t("nc.nextAction.dose") }
    static var ncConfirmDose: String { t("nc.confirmDose") }
    static func ncExpireDate(_ d: String) -> String { String(format: t("nc.expireDateFmt"), d) }
    static func ncOcrCount(_ n: Int) -> String { String(format: t("nc.ocrCountFmt"), n) }
    static var ncEmpty: String { t("nc.empty") }
    static var ncEmptyHint: String { t("nc.emptyHint") }

    // MARK: - F12 全局搜索（SP-20）
    static var searchTitle: String { t("search.title") }
    static var searchPlaceholder: String { t("search.placeholder") }
    static var searchPlaceholderHint: String { t("search.placeholderHint") }
    static func searchNoResult(_ q: String) -> String { String(format: t("search.noResultFmt"), q) }
    static var searchLoosenHint: String { t("search.loosenHint") }
    static var searchClear: String { t("search.clear") }
    static var searchGroupDocs: String { t("search.group.docs") }
    static var searchGroupObservations: String { t("search.group.observations") }
    static var searchGroupMeds: String { t("search.group.meds") }
    static var searchObsLocked: String { t("search.obsLocked") }

    // MARK: - FR14.5/FR17.15/FR17.16 语言选择器
    static var languageTitle: String { t("language.title") }
    static var languageFooter: String { t("language.footer") }
    /// FR14.5 可显示语言（以该语言原文显示）；en 为 P2 评估项不列
    static var supportedDisplayLanguages: [(code: String, nativeName: String)] {
        [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文")]
    }
    static var voiceLangTitle: String { t("voiceLang.title") }
    static var voiceLangInputSection: String { t("voiceLang.inputSection") }
    static var voiceLangInputHint: String { t("voiceLang.inputHint") }
    static var voiceLangOutputSection: String { t("voiceLang.outputSection") }
    static var voiceLangOutputHint: String { t("voiceLang.outputHint") }
    static var voiceLangBestEffort: String { t("voiceLang.bestEffort") }
    static var voiceLangFallback: String { t("voiceLang.fallback") }
    static var voiceLangMix: String { t("voiceLang.mix") }
    static var voiceLangMixHint: String { t("voiceLang.mixHint") }

    // MARK: - FR9.5/FR9.17 动作集与时段确认
    static var reminder_allTaken: String { t("reminder.allTaken") }
    static var reminder_allTakenConfirm: String { t("reminder.allTakenConfirm") }
    static var reminder_allTakenYes: String { t("reminder.allTakenYes") }
    static var reminder_snooze15: String { t("reminder.snooze15") }
    static var reminder_snooze30: String { t("reminder.snooze30") }
    static var reminder_snooze60: String { t("reminder.snooze60") }
    static var reminder_forgot: String { t("reminder.forgot") }
    static var reminder_discomfort: String { t("reminder.discomfort") }
    static var reminder_discomfortPlaceholder: String { t("reminder.discomfortPlaceholder") }
    static var reminder_skipReasonNone: String { t("reminder.skipReason.none") }
    static var reminder_skipReasonForgot: String { t("reminder.skipReason.forgot") }
    static var reminder_skipReasonDoctor: String { t("reminder.skipReason.doctor") }
    static var reminder_skipReasonOther: String { t("reminder.skipReason.other") }
    static var reminder_moreActions: String { t("reminder.moreActions") }

    // MARK: - FR9.15/FR9.16 计划生命周期与补录（SP-15）
    static var planListTitle: String { t("plan.listTitle") }
    static var planDetailTitle: String { t("plan.detailTitle") }
    static var planNotFound: String { t("plan.notFound") }
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
    static func planEventEnded(_ reason: String) -> String {
        reason.isEmpty ? t("plan.event.ended") : String(format: t("plan.event.endedReasonFmt"), reason)
    }
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
    // FR9.1-9.3 计划创建表单
    static var planFormTitle: String { t("plan.form.title") }
    static var planFormMedication: String { t("plan.form.medication") }
    static var planFormGenericName: String { t("plan.form.genericName") }
    static var planFormBrandName: String { t("plan.form.brandName") }
    static var planFormSpec: String { t("plan.form.spec") }
    static var planFormDosePerTake: String { t("plan.form.dosePerTake") }
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
    static func planFormLotUnits(_ n: Double) -> String { String(format: t("plan.form.lot.unitsFmt"), Int(n)) }
    static var planFormLotUnit: String { t("plan.form.lot.unit") }
    static var planFormExpireUnknown: String { t("plan.form.lot.expireUnknown") }
    static var planFormExpireDate: String { t("plan.form.lot.expireDate") }
    static var planFormStorageNote: String { t("plan.form.lot.storageNote") }
    static var planFormLotHint: String { t("plan.form.lot.hint") }
    static var lotUnitTablet: String { t("lot.unit.tablet") }
    static var lotUnitCapsule: String { t("lot.unit.capsule") }
    static var lotUnitPatch: String { t("lot.unit.patch") }
    static var lotUnitVial: String { t("lot.unit.vial") }

    // MARK: - FR9.9 药品知识卡（§5.40）
    static var knowledgeTitle: String { t("knowledge.title") }
    static var knowledgeAdvice: String { t("knowledge.advice") }
    static var knowledgeAdviceBadge: String { t("knowledge.adviceBadge") }
    static var knowledgeNoAdvice: String { t("knowledge.noAdvice") }
    static var knowledgeStorage: String { t("knowledge.storage") }
    static var knowledgeStorageHint: String { t("knowledge.storageHint") }
    static var knowledgeCaution: String { t("knowledge.caution") }
    static var knowledgeCautionText: String { t("knowledge.cautionText") }

    // MARK: - F4 就诊事件（SP-08 · FR4.1-4.4）
    static func encounterKindName(_ kind: EncounterKind) -> String { t("encounter.kind.\(kind.rawValue)") }
    static var encounterListTitle: String { t("encounter.listTitle") }
    static var encounterEmpty: String { t("encounter.empty") }
    static var encounterEmptyHint: String { t("encounter.emptyHint") }
    static var encounterUntitled: String { t("encounter.untitled") }
    static func encounterDocCount(_ n: Int) -> String { String(format: t("encounter.docCountFmt"), n) }
    static var encounterDetailTitle: String { t("encounter.detailTitle") }
    static var encounterDiagnosisAdvice: String { t("encounter.diagnosisAdvice") }
    static var encounterDiagnosisBadge: String { t("encounter.diagnosisBadge") }
    static var encounterAdviceBadge: String { t("encounter.adviceBadge") }
    static var encounterFollowUp: String { t("encounter.followUp") }
    static var encounterLinkedDocs: String { t("encounter.linkedDocs") }
    static var encounterNoDocs: String { t("encounter.noDocs") }
    static func encounterDocTitle(_ s: String.SubSequence) -> String {
        String(format: t("encounter.docTitleFmt"), String(s))
    }
    static var encounterRecommendSection: String { t("encounter.recommend.section") }
    static var encounterRecommendPending: String { t("encounter.recommend.pending") }
    static var encounterLink: String { t("encounter.link") }
    static var encounterGenerateSummary: String { t("encounter.generateSummary") }
    static var encounterSummaryTitle: String { t("encounter.summary.title") }
    static var encounterSummaryHeader: String { t("encounter.summary.header") }
    static var encounterSummaryUnconfirmed: String { t("encounter.summary.unconfirmed") }
    static var encounterSummaryAllConfirmed: String { t("encounter.summary.allConfirmed") }
    static func encounterSummaryDocFields(_ id: String, _ n: Int) -> String {
        String(format: t("encounter.summary.docFieldsFmt"), id, n)
    }
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

    // MARK: - F11 时间轴 + FR11.4 健康问题（SP-19/SP-49）
    static var timelineTitle: String { t("timeline.title") }
    static var timelineEmptyHint: String { t("timeline.emptyHint") }
    static var timelineFilterAll: String { t("timeline.filter.all") }
    static func timelineKindName(_ kind: TimelineEntryKind) -> String { t("timeline.kind.\(kind.rawValue)") }
    static var timelineProblemsFilter: String { t("timeline.problemsFilter") }
    static var problemTitle: String { t("problem.title") }
    static var problemEmpty: String { t("problem.empty") }
    static var problemEmptyHint: String { t("problem.emptyHint") }
    static var problemCreateTitle: String { t("problem.createTitle") }
    static var problemNamePlaceholder: String { t("problem.namePlaceholder") }
    static var problemMerge: String { t("problem.merge") }
    static var problemMergeTitle: String { t("problem.mergeTitle") }
    static func problemMergeInto(_ name: String) -> String { String(format: t("problem.mergeIntoFmt"), name) }
    static var problemMergeHint: String { t("problem.mergeHint") }
    static var problemArchive: String { t("problem.archive") }
    static var problemUnarchive: String { t("problem.unarchive") }

    // MARK: - FR10.4 就诊准备包 / FR10.5 问诊问题
    static var prepTitle: String { t("prep.title") }
    static var prepPatient: String { t("prep.patient") }
    static var prepBloodType: String { t("prep.bloodType") }
    static var prepMeds: String { t("prep.meds") }
    static var prepObservations: String { t("prep.observations") }
    static var prepQuestions: String { t("prep.questions") }
    static var prepNoData: String { t("prep.noData") }
    static var prepNoQuestions: String { t("prep.noQuestions") }
    static func prepDaysLeft(_ n: Int) -> String { String(format: t("prep.daysLeftFmt"), n) }
    static var prepDisclaimer: String { t("prep.disclaimer") }
    static var questionTitle: String { t("question.title") }
    static var questionPlaceholder: String { t("question.placeholder") }
    static var questionMarkAsked: String { t("question.markAsked") }

    // MARK: - F10 预约（SP-18 · FR10.1-10.7）
    static var apptListTitle: String { t("appt.listTitle") }
    static var apptEmpty: String { t("appt.empty") }
    static var apptEmptyHint: String { t("appt.emptyHint") }
    static func apptStatusName(_ s: String) -> String { t("appt.status.\(s)") }
    static var apptReschedule: String { t("appt.reschedule") }
    static var apptCancel: String { t("appt.cancel") }
    static var apptComplete: String { t("appt.complete") }
    static var apptFollowUpHint: String { t("appt.followUpHint") }
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
    static func apptFollowUpDays(_ n: Int) -> String { String(format: t("appt.followUpDaysFmt"), n) }
    static var apptFollowUpConcreteDate: String { t("appt.followUpConcreteDate") }
    static var apptFollowUpDraftOnly: String { t("appt.followUpDraftOnly") }

    // MARK: - F3 成员详情/删除/归属确认（FR3.1/3.3/3.4）
    static var memberDetailBasic: String { t("member.detail.basic") }
    static var memberDetailMore: String { t("member.detail.more") }
    static var memberBloodType: String { t("member.bloodType") }
    static var memberIdNo: String { t("member.idNo") }
    static var memberInsuranceNo: String { t("member.insuranceNo") }
    static var memberNote: String { t("member.note") }
    static var memberDelete: String { t("member.delete") }
    static var memberSelfNoDelete: String { t("member.selfNoDelete") }
    static var memberDeleteImpact: String { t("member.delete.impact") }
    static var memberDeleteImpactDocs: String { t("member.delete.impactDocs") }
    static var memberDeleteImpactObs: String { t("member.delete.impactObs") }
    static var memberDeleteImpactPlans: String { t("member.delete.impactPlans") }
    static var memberDeleteImpactAppts: String { t("member.delete.impactAppts") }
    static var memberDeleteKeepDocs: String { t("member.delete.keepDocs") }
    static var memberDeletePlanChoice: String { t("member.delete.planChoice") }
    static var memberDeletePlans: String { t("member.delete.plans") }
    static var memberArchivePlans: String { t("member.archivePlans") }
    static var memberDeleteConfirm: String { t("member.delete.confirm") }
    static func memberDeleteConfirmPlaceholder(_ name: String) -> String {
        String(format: t("member.delete.confirmPlaceholderFmt"), name)
    }
    static var memberDeleteConfirmButton: String { t("member.delete.confirmButton") }
    static var memberConfirmBelongsTo: String { t("member.confirm.belongsTo") }
    static var memberConfirmSwitch: String { t("member.confirm.switch") }
    static var member_relationSelf: String { t("member.relation.self") }

    // MARK: - F5 资料库（SP-09/SP-10 · FR5.1-5.8 + FR6.6）
    static var docLibraryTitle: String { t("docLibrary.title") }
    static var docLibraryEmpty: String { t("docLibrary.empty") }
    static var docLibraryEmptyHint: String { t("docLibrary.emptyHint") }
    static var docLibraryUntitled: String { t("docLibrary.untitled") }
    static var docArchive: String { t("doc.archive") }
    static var docUnarchive: String { t("doc.unarchive") }
    static var docFavorite: String { t("doc.favorite") }
    static var docUnfavorite: String { t("doc.unfavorite") }
    static var docImportSourceTitle: String { t("doc.importSource.title") }
    static var docImportCamera: String { t("doc.importSource.camera") }
    static var docImportFile: String { t("doc.importSource.file") }
    static var docImportPhotos: String { t("doc.importSource.photos") }
    static var docImportManual: String { t("doc.importSource.manual") }
    static var docDuplicateTitle: String { t("doc.duplicate.title") }
    static var docDuplicateKeepBoth: String { t("doc.duplicate.keepBoth") }
    static var docDuplicateDiscard: String { t("doc.duplicate.discard") }
    static func docDuplicateHint(_ n: Int) -> String { String(format: t("doc.duplicate.hintFmt"), n) }
    static var docImportFailedTitle: String { t("doc.importFailed.title") }
    static var docImportFailed: String { t("doc.importFailed") }
    static var docPDFImportFailed: String { t("doc.pdfImportFailed") }
    static var docTypeReport: String { t("doc.type.report") }
    static var docTypeRecord: String { t("doc.type.record") }
    static var docManualCreateTitle: String { t("doc.manual.createTitle") }
    static var docManualTitle: String { t("doc.manual.title") }
    static var docManualType: String { t("doc.manual.type") }
    static var docManualNote: String { t("doc.manual.note") }

    // MARK: - F6 OCR 确认（FR6.3/6.4/6.8 · SP-53）
    static var onboardRejected: String { t("onboard.rejected") }
    static func onboardRejectLabel(_ label: String) -> String {
        String(format: t("onboard.rejectLabelFmt"), label)
    }
    static var ocrQueueTitle: String { t("ocrQueue.title") }
    static var ocrQueueEmpty: String { t("ocrQueue.empty") }
    static var ocrQueueEmptyHint: String { t("ocrQueue.emptyHint") }
    static func ocrQueueCount(_ n: Int) -> String { String(format: t("ocrQueue.countFmt"), n) }
    static var ocrQueueAllConfirm: String { t("ocrQueue.allConfirm") }
    static var ocrQueueAllConfirmBlocked: String { t("ocrQueue.allConfirmBlocked") }
    static var ocrQueue72h: String { t("ocrQueue.72h") }
    static var ocrQueueJumpSource: String { t("ocrQueue.jumpSource") }
    static func ocrQueueLowConfidence(_ n: Int) -> String { String(format: t("ocrQueue.lowConfidenceFmt"), n) }
    static var onboard_revise: String { t("onboard.revise") }
    static var onboard_reject: String { t("onboard.reject") }
    static var docReportIssue: String { t("doc.reportIssue") }

    // MARK: - F23 过敏与不良反应（SP-50 · FR23.1-23.6）
    static var allergyTitle: String { t("allergy.title") }
    static var allergyEmpty: String { t("allergy.empty") }
    static var allergyEmptyHint: String { t("allergy.emptyHint") }
    static var allergySelfReportBadge: String { t("allergy.selfReportBadge") }
    static func allergySeverity(_ s: String) -> String { t("allergy.severity.\(s)") }
    static var allergyDelete: String { t("allergy.delete") }
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

    // MARK: - FR12.10 AI 会话历史 / FR12.8 反馈四键
    static var aiHistoryTitle: String { t("aiHistory.title") }
    static var aiHistoryEmpty: String { t("aiHistory.empty") }
    static func aiHistoryCount(_ n: Int) -> String { String(format: t("aiHistory.countFmt"), n) }
    static var aiHistoryDelete: String { t("aiHistory.delete") }
    static var aiHistoryClearAll: String { t("aiHistory.clearAll") }
    static var aiHistoryClearNote: String { t("aiHistory.clearNote") }
    static var aiFeedbackUseful: String { t("aiFeedback.useful") }
    static var aiFeedbackUseless: String { t("aiFeedback.useless") }
    static var aiFeedbackCitationError: String { t("aiFeedback.citationError") }
    static var aiFeedbackDanger: String { t("aiFeedback.danger") }
    static var aiFeedbackMore: String { t("aiFeedback.more") }

    // MARK: - FR13.1/13.2 PDF 导出向导（SP-22）+ FR13.10 定期备份提醒
    static var exportWizardTitle: String { t("export.wizard.title") }
    static var exportScope: String { t("export.scope") }
    static var exportScopeAll: String { t("export.scope.all") }
    static var exportScopeDateRange: String { t("export.scope.dateRange") }
    static var exportScopeDoctorSummary: String { t("export.scope.doctorSummary") }
    static var exportDateFrom: String { t("export.dateFrom") }
    static var exportDateTo: String { t("export.dateTo") }
    static var exportContent: String { t("export.content") }
    static var exportIncludeNotes: String { t("export.includeNotes") }
    static var exportWatermark: String { t("export.watermark") }
    static var exportPrivacyHint: String { t("export.privacyHint") }
    static var exportStart: String { t("export.start") }
    static var exportUnlockReason: String { t("export.unlockReason") }
    static func exportProgress(_ n: Int, _ total: Int) -> String { String(format: t("export.progressFmt"), n, total) }
    static var exportCancel: String { t("export.cancel") }
    static var exportCancelled: String { t("export.cancelled") }
    static var exportFailed: String { t("export.failed") }
    static var exportRetry: String { t("export.retry") }
    static func exportFinished(_ n: Int, _ pages: Int) -> String { String(format: t("export.finishedFmt"), n, pages) }
    static var exportShare: String { t("export.share") }
    static func exportTitle(_ s: String) -> String { String(format: t("export.titleFmt"), s) }
    static var backupReminderTitle: String { t("backup.reminder.title") }
    static var backupReminderBody: String { t("backup.reminder.body") }

    // MARK: - FR14.1 九开关 / FR14.7 偏好中心 / FR14.3 数据生命周期
    static var authOcrLabel: String { t("auth.ocr") }
    static var authAILabel: String { t("auth.ai") }
    static var authFamilyLabel: String { t("auth.family") }
    static var authSharingLabel: String { t("auth.sharing") }
    static var authCloudBackupLabel: String { t("auth.cloudBackup") }
    static var authAnonymizedLabel: String { t("auth.anonymized") }
    static var authHealthLabel: String { t("auth.health") }
    static var authVoiceDictationLabel: String { t("auth.voiceDictation") }
    static var settings_dataLifecycle: String { t("settings.dataLifecycle") }
    static var settings_themeHint: String { t("settings.themeHint") }
    static var prefGroupReminders: String { t("pref.group.reminders") }
    static var prefGroupDisplay: String { t("pref.group.display") }
    static var prefGroupVoice: String { t("pref.group.voice") }
    static var prefTagGlobal: String { t("pref.tag.global") }
    static var prefTagNewOnly: String { t("pref.tag.newOnly") }
    static var prefRemindAdvance: String { t("pref.remindAdvance") }
    static var prefSnooze: String { t("pref.snooze") }
    static var prefQuietStart: String { t("pref.quietStart") }
    static var prefQuietEnd: String { t("pref.quietEnd") }
    static var prefTo: String { t("pref.to") }
    static var prefChannel: String { t("pref.channel") }
    static var prefChannelNotifyOnly: String { t("pref.channel.notifyOnly") }
    static var prefChannelRingUntilConfirm: String { t("pref.channel.ringUntilConfirm") }
    static var prefChannelSilentBanner: String { t("pref.channel.silentBanner") }
    static var prefNotifPreviewMed: String { t("pref.notifPreviewMed") }
    static var prefRemindScopeNote: String { t("pref.remindScopeNote") }
    static var prefDateFormat: String { t("pref.dateFormat") }
    static var prefWeekStart: String { t("pref.weekStart") }
    static var prefUnitSystem: String { t("pref.unitSystem") }
    static var prefUnitMetric: String { t("pref.unit.metric") }
    static var prefUnitImperial: String { t("pref.unit.imperial") }
    static var prefReduceMotion: String { t("pref.reduceMotion") }
    static var prefHomeSort: String { t("pref.homeSort") }
    static var prefHomeSortTime: String { t("pref.homeSort.time") }
    static var prefHomeSortType: String { t("pref.homeSort.type") }
    static var prefReadback: String { t("pref.readback") }
    static var prefReadbackNever: String { t("pref.readback.never") }
    static var prefReadbackAsk: String { t("pref.readback.ask") }
    static var prefReadbackAlways: String { t("pref.readback.always") }
    static var prefReadbackHint: String { t("pref.readbackHint") }
    static var prefRestoreAll: String { t("pref.restoreAll") }
    static var lifecycleSingle: String { t("lifecycle.single") }
    static var lifecycleSingleHint: String { t("lifecycle.singleHint") }
    static var lifecycleMember: String { t("lifecycle.member") }
    static var lifecycleMemberHint: String { t("lifecycle.memberHint") }
    static var lifecycleClearAll: String { t("lifecycle.clearAll") }
    static var lifecycleClearHint: String { t("lifecycle.clearHint") }
    static var lifecycleClearButton: String { t("lifecycle.clearButton") }
    static var lifecycleClearImpact: String { t("lifecycle.clearImpact") }
    static var lifecycleLogout: String { t("lifecycle.logout") }
    static var lifecycleLogoutHint: String { t("lifecycle.logoutHint") }

    // MARK: - FR21.9 向导 ④ 添加家人 / ⑥ 首日引导
    static var onboardAddFamilyTitle: String { t("onboard.addFamily.title") }
    static var onboardAddFamilyHint: String { t("onboard.addFamily.hint") }
    static var onboardAddFamilyManual: String { t("onboard.addFamily.manual") }
    static var onboardAddFamilyVoiceP1: String { t("onboard.addFamily.voiceP1") }
    static var onboardAddFamilyContactsP1: String { t("onboard.addFamily.contactsP1") }
    static var onboardAddFamilySkip: String { t("onboard.addFamily.skip") }
    static var onboardAddFamilyCompleteHint: String { t("onboard.addFamily.completeHint") }
    static var onboardFirstDayTitle: String { t("onboard.firstDay.title") }
    static var onboardFirstDayHint: String { t("onboard.firstDay.hint") }
    static var onboardFirstDayCapture: String { t("onboard.firstDay.capture") }
    static var onboardFirstDayReminder: String { t("onboard.firstDay.reminder") }
    static var onboardFirstDayAI: String { t("onboard.firstDay.ai") }

    // MARK: - FR22.5 反馈 / FR24.2 发送状态 / FR9.13a 收件人
    static var feedbackTitle: String { t("feedback.title") }
    static var feedbackCategory: String { t("feedback.category") }
    static func feedbackCategoryName(_ i: Int) -> String { t("feedback.category.\(i)") }
    static var feedbackDetail: String { t("feedback.detail") }
    static var feedbackDetailPlaceholder: String { t("feedback.detailPlaceholder") }
    static var feedbackAttachments: String { t("feedback.attachments") }
    static var feedbackAttachScreenshot: String { t("feedback.attachScreenshot") }
    static var feedbackAttachOriginal: String { t("feedback.attachOriginal") }
    static var feedbackAttachMedia: String { t("feedback.attachMedia") }
    static var feedbackAttachmentHint: String { t("feedback.attachmentHint") }
    static var feedbackSubmit: String { t("feedback.submit") }
    static var feedbackSubmitted: String { t("feedback.submitted") }
    static var fr24_markDelivered: String { t("fr24.markDelivered") }
    static var fr24_offlineNote: String { t("fr24.offlineNote") }
    static var helpcardRecipient: String { t("helpcard.recipient") }
    static var helpcardRecipientOther: String { t("helpcard.recipientOther") }
    static var helpcardRecipientPlaceholder: String { t("helpcard.recipientPlaceholder") }

    // MARK: - FR7.5 自测两步录入（SP-13 快速录入）
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
    static var metricViewTrend: String { t("metric.viewTrend") }

    // MARK: - FR17.9 语音速记面板（SP-55）+ FR8.10 观察随访
    static var voicePanelTitle: String { t("voicePanel.title") }
    static var voicePanelHint: String { t("voicePanel.hint") }
    static var voicePanelStart: String { t("voicePanel.start") }
    static func voiceTargetName(_ tag: TargetTag) -> String { t("voiceTarget.\(tag.rawValue)") }
    static var observationFollowUpSet: String { t("observation.followUp.set") }

    // MARK: - F16 设备接入（SP-29/SP-30）
    static var f16Title: String { t("f16.title") }
    static var f16AuthSection: String { t("f16.authSection") }
    static var f16AuthHint: String { t("f16.authHint") }
    static var f16RequestAuth: String { t("f16.requestAuth") }
    static var f16AuthGranted: String { t("f16.authGranted") }
    static var f16AuthDisabled: String { t("f16.authDisabled") }
    static var f16AuthFailed: String { t("f16.authFailed") }
    static var f16SyncSection: String { t("f16.syncSection") }
    static var f16SyncHint: String { t("f16.syncHint") }
    static var f16SyncNow: String { t("f16.syncNow") }
    static var f16Syncing: String { t("f16.syncing") }
    static func f16SyncDone(_ n: Int) -> String { String(format: t("f16.syncDoneFmt"), n) }
    static var f16SyncFailed: String { t("f16.syncFailed") }
    static var alertFilterAll: String { t("alert.filter.all") }
    static var alertShowL0: String { t("alert.showL0") }
    static var alert_historyEntry: String { t("alert.historyEntry") }

    // MARK: - F19 附表执行矩阵播报（纯事实句式）
    static var f19NoTodayMeds: String { t("f19.noTodayMeds") }
    static func f19NextAppointment(_ a: String, _ d: String) -> String {
        String(format: t("f19.nextAppointmentFmt"), a, d)
    }
    static var f19NoAppointment: String { t("f19.noAppointment") }
    static func f19RecentGlucose(_ v: String) -> String { String(format: t("f19.recentGlucoseFmt"), v) }
    static var f19NoGlucose: String { t("f19.noGlucose") }
    static func f19StockRemaining(_ name: String, _ days: Int) -> String {
        String(format: t("f19.stockRemainingFmt"), name, days)
    }
    static func f19StockNoPlan(_ name: String) -> String { String(format: t("f19.stockNoPlanFmt"), name) }
    static var f19NoStock: String { t("f19.noStock") }
    static func f19StockLocation(_ name: String, _ loc: String) -> String {
        String(format: t("f19.stockLocationFmt"), name, loc)
    }
    static var f19LocationUnknown: String { t("f19.locationUnknown") }
    static var f19NoExpiring: String { t("f19.noExpiring") }
    static func f19Expiring(_ name: String, _ d: String) -> String {
        String(format: t("f19.expiringFmt"), name, d)
    }
    static var f19Taken: String { t("f19.taken") }
    static var f19NotTaken: String { t("f19.notTaken") }
    static func f19SlotMedState(_ med: String, _ state: String) -> String {
        String(format: t("f19.slotMedStateFmt"), med, state)
    }
    static func f19MarkTakenNoMatch(_ name: String) -> String { String(format: t("f19.markTakenNoMatchFmt"), name) }
    static func f19MarkTakenDone(_ name: String) -> String { String(format: t("f19.markTakenDoneFmt"), name) }
    static func f19MetricRecorded(_ v: Double) -> String { String(format: t("f19.metricRecordedFmt"), v) }
    static func f19QuestionRecorded(_ q: String) -> String { String(format: t("f19.questionRecordedFmt"), q) }

    // MARK: - FR15.2 系统医疗急救卡引导
    static var medicalIDTitle: String { t("medicalID.title") }
    static var medicalIDStep1: String { t("medicalID.step1") }
    static var medicalIDStep1Hint: String { t("medicalID.step1Hint") }
    static var medicalIDStep2: String { t("medicalID.step2") }
    static var medicalIDStep2Hint: String { t("medicalID.step2Hint") }
    static var medicalIDStep3: String { t("medicalID.step3") }
    static var medicalIDStep3Hint: String { t("medicalID.step3Hint") }
    static var medicalIDOpenHealth: String { t("medicalID.openHealth") }
    static var medicalIDNote: String { t("medicalID.note") }

    enum TargetTag: String, CaseIterable {
        case metric, observation, question, ai, reminder, profile, anyText
    }

    /// 支持的本地化（三文件纪律）
    static let supportedLocalizations = ["zh-Hans", "zh-Hant", "en"]

    // MARK: - FR14.5 语言即时切换（无需重启）
    //
    // 直接按选定语言从对应 .lproj 解析——NSLocalizedString 跟随系统语言且
    // 每进程缓存，无法满足「切换即时生效、不要求重启」（FR14.5 验收）。
    // 视图层全部经本单出口取值：语言变更 → AppSettingsStore.values 变化 →
    // 视图重渲染 → t() 按新语言解析。

    /// 当前显示语言（"zh-Hans"/"zh-Hant"）。nonisolated(unsafe)：
    /// 仅在 App 启动与语言设置变更时写（两者皆发生在主线程 UI 流程），
    /// 读路径并发无害（缓存值切换的窗口期只影响一次渲染的文案）。
    nonisolated(unsafe) private static var languageCache: String = "zh-Hans"
    nonisolated(unsafe) private static var bundleCache: Bundle?

    static var bundleLanguage: String { languageCache }

    /// FR14.5 语言切换入口（设置页调用；App 启动时以持久化偏好初始化）
    static func setLanguage(_ lang: String) {
        guard supportedLocalizations.contains(lang) else { return }
        languageCache = lang
        bundleCache = nil
        UserDefaults.standard.set(lang, forKey: "vl.language")
    }

    /// 启动恢复：从持久化偏好初始化（AppRootView .task 调用）
    static func restoreLanguage() {
        let stored = UserDefaults.standard.string(forKey: "vl.language") ?? "zh-Hans"
        languageCache = stored
        bundleCache = nil
    }

    private static func t(_ key: String) -> String {
        if let bundle = currentBundle {
            let value = bundle.localizedString(forKey: key, value: key, table: nil)
            if value != key { return value }   // 缺译回落系统默认（三文件纪律由 SU-M15-L10N 兜底）
        }
        return NSLocalizedString(key, comment: "")
    }

    private static var currentBundle: Bundle? {
        if let cached = bundleCache { return cached }
        guard let path = Bundle.main.path(forResource: languageCache, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        bundleCache = bundle
        return bundle
    }
}
