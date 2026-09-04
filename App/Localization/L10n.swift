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
    static var onboard_observation: String { t("onboard.observation") }
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
    static var observationUnlockedPlaceholder: String { t("observation.unlockedPlaceholder") }
    static var observationLockedHint: String { t("observation.lockedHint") }
    static var observationUnlockedHint: String { t("observation.unlockedHint") }

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
        "nav.records", "nav.reminders", "observation.groupSummary", "observation.lockedHint",
        "observation.trend.improved", "observation.trend.unchanged", "observation.trend.worsened", "observation.unlockedHint",
        "observation.unlockedPlaceholder", "onboard.aimPrescription", "onboard.buildProfile", "onboard.cancel",
        "onboard.capturePrescription", "onboard.confirm", "onboard.confirmAllTimeline", "onboard.confirmResult",
        "onboard.confirmed", "onboard.confirmedCount", "onboard.createContinue",
        "onboard.finishEnterApp", "onboard.gotIt", "onboard.later", "onboard.newValue",
        "onboard.observation", "onboard.ocrDisclaimer", "onboard.ocrRaw", "onboard.ownerNote",
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
        "voicenote.empty.title", "voicenote.inTimeline", "voicenote.save.accessibility", "voicenote.title"
    ]

    /// 支持的本地化（三文件纪律）
    static let supportedLocalizations = ["zh-Hans", "zh-Hant", "en"]

    private static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
