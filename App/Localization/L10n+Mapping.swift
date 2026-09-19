// Swift file split out of L10n.swift — 由 split-l10n.py 生成。
// 文案唯一出口（tech-spec §3）：符号名不变，仅换文件；键表按前缀分域。
import Foundation
import Domain

extension L10n {
    static func trendExcludedHeader(_ count: Int) -> String { String(format: t("trend.excluded.headerFmt"), count) }

    static func voiceRejectWhat(_ category: String) -> String {
        switch category {
        case "frequency": return t("voice.rejectWhat.frequency")
        case "discontinue": return t("voice.rejectWhat.discontinue")
        default: return t("voice.rejectWhat.dosage")
        }
    }

    static func voiceRejectTitle(_ what: String) -> String { String(format: t("voice.rejectTitle"), what) }

    static func voiceRejectBody(_ what: String) -> String { String(format: t("voice.rejectBody"), what) }

    static func backupRestoredCount(_ n: Int) -> String { String(format: t("backup.restoredCountFmt"), n) }

    static func inventoryMonthlyReportFmt(_ planned: Int, _ confirmed: Int, _ skipped: Int, _ missed: Int) -> String {
        String(format: t("inventory.monthlyReportFmt"), planned, confirmed, skipped, missed)
    }

    static func emergencyReaction(_ tags: String) -> String { String(format: t("emergency.reactionFmt"), tags) }

    static func emergencySeverity(_ s: String) -> String { String(format: t("emergency.severityFmt"), s) }

    static func careParametersSOSValue(seconds: Int) -> String {
        String(format: t("care.parameters.sosValue"), seconds)
    }

    static func claimTotals(_ count: Int, _ amount: String) -> String {
        String(format: t("claim.totalsFmt"), count, amount)
    }

    static func voicePromptText(_ p: SpeechPrompt) -> String {
        switch p {
        case .repeatHint: return t("voice.prompt.repeatHint")
        case .pickOption: return t("voice.prompt.pickOption")
        case .optionNotFound: return t("voice.prompt.optionNotFound")
        case .callConfirm(let target): return String(format: t("voice.prompt.callConfirm"), target.isEmpty ? t("voice.prompt.contactFallback") : target)
        case .markTakenConfirm(let object): return String(format: t("voice.prompt.markTakenConfirm"), object.isEmpty ? t("voice.prompt.thisMedFallback") : object)
        case .forbiddenHint: return t("voice.prompt.forbiddenHint")
        case .recordConfirm(let metric): return String(format: t("voice.prompt.recordConfirm"), metric)
        case .sayCallTargetAgain: return t("voice.prompt.sayCallTargetAgain")
        case .cancelled: return t("voice.prompt.cancelled")
        case .confirmToCall: return t("voice.prompt.confirmToCall")
        case .confirmToSave: return t("voice.prompt.confirmToSave")
        case .multipleMatches(let options):
            let numbered = options.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: t("voice.prompt.listSeparator"))
            return String(format: t("voice.prompt.multipleMatches"), numbered)
        }
    }

    static func f19_contactNotFound(_ object: String) -> String { String(format: t("f19.contactNotFound"), object) }

    static func f19_contactAmbiguous(_ object: String, _ resolved: String) -> String { String(format: t("f19.contactAmbiguous"), object, resolved) }

    static func reminder_a11yTaken(name: String) -> String { String(format: t("reminder.a11yTaken"), name) }

    static func reminder_a11ySnoozed(name: String) -> String { String(format: t("reminder.a11ySnoozed"), name) }

    static func reminder_a11ySkipped(name: String) -> String { String(format: t("reminder.a11ySkipped"), name) }

    static func aiConclusion(_ count: Int) -> String { String(format: t("ai.conclusion"), count) }

    static func aiTerm(_ term: String, _ explanation: String) -> String { String(format: t("ai.term"), term, explanation) }

    static func aiSourceLine(_ kind: String, _ title: String) -> String { String(format: t("ai.sourceLine"), kind, title) }

    static func aiScopeNote(_ count: Int) -> String { String(format: t("ai.scopeNote"), count) }

    static func settingsQuietHours(_ a: String, _ b: String) -> String {
        String(format: t("settings.quietHours"), a, b)   // 位置参数 %1$@ / %2$@
    }

    static func reminderTakenCount(_ a: Int, _ b: Int) -> String {
        String(format: t("reminder.takenCount"), a, b)   // 位置参数 %1$d / %2$d
    }

    static func helpVersion(_ version: String, _ build: String, _ hash: String) -> String {
        String(format: t("help.versionFormat"), version, build, hash)   // %1$@ %2$@ %3$@
    }

        static func doseNumber(_ n: Int) -> String { String(format: t("dose.number"), n) }

    static func voiceguide_profileDonePartial(_ written: Int, _ skipped: Int) -> String { String(format: t("voiceguide.profileDonePartial"), written, skipped) }

    static func voiceguideStep(_ a: Int, _ b: Int) -> String {
        String(format: t("voiceguide.stepOf"), a, b)
    }

    static func trendBandAccessibility(_ source: String, _ lo: String, _ hi: String) -> String {
        String(format: t("trend.band.accessibility"), source, lo, hi)   // %1$@ %2$@ %3$@
    }

    static func trendChartAccessibility(_ metric: String, _ points: Int, _ bands: Int) -> String {
        String(format: t("trend.chart.accessibility"), metric, points, bands)
    }

    static func trendBandLegend(_ source: String, _ lo: String, _ hi: String) -> String {
        String(format: t("trend.band.legend"), source, lo, hi)   // %1$@ %2$@ %3$@
    }

    static func trendWindow(_ window: TrendTimeWindow) -> String {
        switch window {
        case .week: return t("trend.window.week")
        case .month: return t("trend.window.month")
        case .quarter: return t("trend.window.quarter")
        case .year: return t("trend.window.year")
        }
    }

    static func trendEmptyOutOfWindow(_ latest: String) -> String { String(format: t("trend.emptyOutOfWindowFmt"), latest) }

    static func trendPeriodAccessibility(_ range: String) -> String { String(format: t("trend.period.accessibility"), range) }

    static func trendSleepChartAccessibility(_ nights: Int, _ stages: Int) -> String {
        String(format: t("trend.sleep.chart.accessibility"), nights, stages)   // %1$d %2$d
    }

    static func sleepStage(_ stage: SleepStage) -> String {
        switch stage {
        case .deep: return t("sleep.stage.deep")
        case .core: return t("sleep.stage.core")
        case .rem: return t("sleep.stage.rem")
        case .awake: return t("sleep.stage.awake")
        case .unspecified: return t("sleep.stage.unspecified")
        case .inBed: return t("sleep.stage.inBed")
        }
    }

    static func sleepStageValue(_ stage: SleepStage, _ value: String) -> String {
        String(format: t("sleep.stage.valueFmt"), sleepStage(stage), value)   // %1$@ %2$@
    }

    static func trendRefRange(_ lo: String, _ hi: String) -> String {
        String(format: t("trend.refRange"), lo, hi)   // %1$@ %2$@
    }

    static func trendRowAccessibility(_ v: String, _ unit: String, _ source: String, _ time: String) -> String {
        String(format: t("trend.row.accessibility"), v, unit, source, time)
    }

    static func homeSwipeArchived(_ title: String) -> String { String(format: t("home.swipe.archived"), title) }

    static func homeSwipeSnoozedTomorrow(_ title: String) -> String { String(format: t("home.swipe.snoozedTomorrow"), title) }

    static func observationGroupSummary(_ count: Int, _ mark: String) -> String {
        String(format: t("observation.groupSummary"), count, mark)   // %1$d %2$@
    }

    static func observationMediaBadge(_ n: Int) -> String {
        String(format: t("observation.mediaBadge"), n)   // %1$d
    }

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

    static func observationMediaCount(_ n: Int) -> String {
        String(format: t("observation.media.count"), n)   // %1$d
    }

    static func alertEvidenceFacts(_ metric: String, _ value: String, _ unit: String,
                                   _ origin: String, _ time: String) -> String {
        String(format: t("alert.evidenceFacts"), metric, value, unit, origin, time)
    }

    static func alertEvidenceSource(_ title: String, _ org: String, _ year: Int, _ clause: String) -> String {
        String(format: t("alert.evidenceSource"), title, org, year, clause)
    }

    static func alertOriginName(_ origin: String) -> String {
        switch origin {
        case "hospital": return trendOriginHospital
        case "device": return trendOriginDevice
        default: return trendSelfMeasured
        }
    }

    static func gsDetailMetric(_ key: String) -> String { String(format: t("gsDetail.metric"), healthMetricName(key)) }

    static func inventoryDualLine(_ plan: String, _ unit: String, _ confirmed: String) -> String {
        String(format: t("inventory.dualLine"), plan, unit, confirmed)   // %1$@ %2$@ · %3$@ %2$@
    }

    static func inventoryBookValue(_ v: String, _ unit: String) -> String {
        String(format: t("inventory.bookValue"), v, unit)   // %1$@ %2$@
    }

    static func inventoryPhysical(_ v: String, _ unit: String) -> String {
        String(format: t("inventory.physical"), v, unit)   // %1$@ %2$@
    }

    static func inventoryReconcileConfirm(_ v: String, _ unit: String) -> String {
        String(format: t("inventory.reconcileConfirm"), v, unit)   // %1$@ %2$@
    }

    static func helpcardRemaining(_ v: String, _ unit: String) -> String {
        String(format: t("helpcard.remaining"), v, unit)   // %1$@ %2$@
    }

    static func helpDataStorageSize(_ mb: String) -> String {
        String(format: t("help.data.storageSizeFmt"), mb)   // %@
    }

    static func caregiverPending(_ time: String) -> String { String(format: t("caregiver.pendingFmt"), time) }

    static func caregiverAlertBody(patient: String, medication: String) -> String {
        String(format: t("caregiver.alertBodyFmt"), patient, medication)
    }

    static func homeGreeting(_ name: String) -> String { String(format: t("home.greeting"), name) }

    static func homePendingOcrCount(_ n: Int) -> String { String(format: t("home.pendingOcrCountFmt"), n) }

    static func homeProfileProgressFmt(_ done: Int, _ total: Int) -> String {
        String(format: t("home.profileProgressFmt"), done, total)   // 位置参数 %1$d / %2$d
    }

    static func homeStockBacklog(_ name: String) -> String { String(format: t("home.stockBacklogFmt"), name) }

    static func homeRemainingFmt(_ n: Int) -> String { String(format: t("home.remainingFmt"), n) }

    static func ncExpireDate(_ d: String) -> String { String(format: t("nc.expireDateFmt"), d) }

    static func ncOcrCount(_ n: Int) -> String { String(format: t("nc.ocrCountFmt"), n) }

    static func searchNoResult(_ q: String) -> String { String(format: t("search.noResultFmt"), q) }

    static func planEventEnded(_ reason: String) -> String {
        reason.isEmpty ? t("plan.event.ended") : String(format: t("plan.event.endedReasonFmt"), reason)
    }

    static func planFormLotUnits(_ n: Double) -> String { String(format: t("plan.form.lot.unitsFmt"), Int(n)) }

    static func encounterDocCount(_ n: Int) -> String { String(format: t("encounter.docCountFmt"), n) }

    static func encounterDocTitle(_ s: String.SubSequence) -> String {
        String(format: t("encounter.docTitleFmt"), String(s))
    }

    /// 就诊总结页「尚未经你确认」行：只出资料标题。
    /// 审查修复（F-A4-04）：此前第二个参数是**恒为 1** 的假字段数（Infrastructure
    /// 侧 `map { ($0, 1) }`），模板会把它直接上屏成「1 个字段待确认」——
    /// 给医生看的页面不得出现无法证实的计数。
    static func encounterSummaryDocFields(_ title: String) -> String {
        String(format: t("encounter.summary.docFieldsFmt"), title)
    }

    static func problemMergeInto(_ name: String) -> String { String(format: t("problem.mergeIntoFmt"), name) }

    static func prepDaysLeft(_ n: Int) -> String { String(format: t("prep.daysLeftFmt"), n) }

    static func apptFollowUpDays(_ n: Int) -> String { String(format: t("appt.followUpDaysFmt"), n) }

    static func memberDeleteConfirmPlaceholder(_ name: String) -> String {
        String(format: t("member.delete.confirmPlaceholderFmt"), name)
    }

    /// FR8.5 自述标记三值（improved/unchanged/worsened）→ 展示名。
    /// 审查修复（复用）：该映射原为 `ObservationDetailView.markName` 私有静态，
    /// SP-14 列表（ObservationViews）因此拿不到、把库里的英文原文直出上屏
    /// （「3 次记录 · 最近 improved」）。上提到文案出口作为单一事实源，
    /// 详情页/展示页/列表页共用。BR-006：只译值本身，不附加判断。
    static func observationMarkName(_ mark: String) -> String {
        switch mark {
        case "improved": return observationTrendImproved
        case "worsened": return observationTrendWorsened
        default: return observationTrendUnchanged
        }
    }

    static func memberRelationDisplayName(_ raw: String) -> String {
        switch raw {
        case "本人": return member_relationSelf
        case "配偶", "partner", "spouse": return member_relationPartner
        case "子女", "child": return member_relationChild
        case "父母", "parent": return member_relationParent
        case "祖父母", "grandparent": return member_relationGrandparent
        case "父亲", "father": return member_relationFather
        case "母亲", "mother": return member_relationMother
        case "儿子", "son": return member_relationSon
        case "女儿", "daughter": return member_relationDaughter
        case "其他", "other": return member_relationOther
        // 审查修复（遗留英文词表容错）：引导流程曾以英文 rawValue 落库
        // （partner/child/...）——上述同义映射保证旧行显示仍本地化（en
        // 首字母大写），不再原样吐回小写英文。
        default: return raw.isEmpty ? member_relationFamily : raw
        }
    }

    static func docDuplicateHint(_ n: Int) -> String { String(format: t("doc.duplicate.hintFmt"), n) }

    static func docPDFPartialFailed(_ n: Int) -> String { String(format: t("doc.pdfPartialFailed"), n) }

    static func entityCardRowIndex(_ n: Int) -> String { String(format: t("entityCard.rowIndexFmt"), n) }

    static func entityCardHeaderPage(_ page: Int, _ total: Int) -> String { String(format: t("entityCard.header.pageFmt"), page, total) }

    static func entityCardHeaderIndex(_ index: Int, _ total: Int) -> String { String(format: t("entityCard.header.indexFmt"), index, total) }

    static func entityCardMissingRequired(_ label: String) -> String { String(format: t("entityCard.missingRequiredFmt"), label) }

    static func entityCardReviewQueue(count: Int, labels: String) -> String {
        String(format: t("entityCard.reviewQueueFmt"), count, labels)
    }

    static func sharedFieldsPending(_ count: Int) -> String { String(format: t("sharedFields.pendingFmt"), count) }

    static func sharedFieldsCarriers(_ list: String) -> String { String(format: t("sharedFields.carriersFmt"), list) }

    static func voiceRecognizedAs(_ locale: String) -> String { String(format: t("voice.recognizedAsFmt"), locale) }

    static func ocrCardsRemaining(_ n: Int) -> String { String(format: t("ocr.cards.remaining"), n) }

    static func ocrCardFieldCount(_ n: Int) -> String { String(format: t("ocr.cards.fieldCount"), n) }

    static func healthImportedPointCount(_ n: Int) -> String { String(format: t("health.importedPointCount"), n) }

    static func healthImportedDayCount(_ n: Int) -> String { String(format: t("health.importedDayCount"), n) }

    static func healthCandidateExisting(_ value: String) -> String { String(format: t("health.candidate.existingFmt"), value) }

    static func healthWriteBackLast(_ written: Int, _ skipped: Int) -> String {
        String(format: t("health.writeBack.lastFmt"), written, skipped)
    }

    static func healthSparseWindows(_ count: Int) -> String { String(format: t("health.sparseWindowsFmt"), count) }

    /// 2026-09-19 审查修复：后台观察注册失败如实呈现（此前标志只写不读——自动导入
    /// 静默死亡而界面显示「自动导入已开启」）。
    static func healthBackgroundSyncFailed() -> String { t("health.backgroundSyncFailed") }

    static func healthBackfillProgress(_ lane: String, _ remaining: Int) -> String {
        String(format: t("health.backfillProgressFmt"), lane, remaining)
    }

    static func healthBackfillLane(_ lane: HealthFetchLane) -> String {
        switch lane {
        case .recent: return t("health.backfillLane.recent")
        case .history: return t("health.backfillLane.history")
        }
    }

    static func ocrReviewPartialSaved(_ count: Int) -> String { String(format: t("ocr.review.partialSavedFmt"), count) }

    static func healthPreservedAggregates(_ count: Int) -> String { String(format: t("health.preservedAggregatesFmt"), count) }

    static func healthDeferredWindows(_ count: Int) -> String { String(format: t("health.deferredWindowsFmt"), count) }

    static func ocGroupName(_ category: String) -> String {
        switch category {
        case "rx": return t("oc.group.rx")
        case "lab": return t("oc.group.lab")
        case "visit": return t("oc.group.visit")
        default: return t("oc.group.generic")
        }
    }

    static func docConfirmUnconfirmedCount(_ n: Int) -> String { String(format: t("docConfirm.unconfirmedCountFmt"), n) }

    static func prescriptionLineCount(_ count: Int) -> String { String(format: t("prescription.lineCountFmt"), count) }

    static func labReportSamplesCount(_ count: Int) -> String { String(format: t("labReport.samplesCountFmt"), count) }

    static func labReportResultsCount(_ count: Int) -> String { String(format: t("labReport.resultsCountFmt"), count) }

    static func profileSuggestionSource(_ page: Int) -> String { String(format: t("profileSuggestion.sourceFmt"), page) }

    static func inventoryBarAccessibility(_ pct: Int) -> String { String(format: t("inventory.barAccessibility"), pct) }

    static func ocrQueueCount(_ n: Int) -> String { String(format: t("ocrQueue.countFmt"), n) }

    static func exportProgress(_ n: Int, _ total: Int) -> String { String(format: t("export.progressFmt"), n, total) }

    static func exportFinished(_ n: Int, _ pages: Int) -> String { String(format: t("export.finishedFmt"), n, pages) }

    static func exportTitle(_ s: String) -> String { String(format: t("export.titleFmt"), s) }

    static func exportRecordCount(_ count: Int) -> String { String(format: t("export.recordCount"), count) }

    /// 审查修复（tech §3）：导出 PDF 目录页标题此前硬编码简体「目录」于
    /// Infrastructure（L10n 门禁只扫 App 视图层，扫不到 CoreKit）。
    /// 现与封面/免责/类型名同口径由 App 层注入。
    static var exportTocTitle: String { t("export.tocTitle") }

    static func exportDisclaimer(_ emergency: String) -> String { String(format: t("export.disclaimer"), emergency) }

    static func exportKindName(_ kind: String) -> String {
        switch kind {
        case "record": return t("export.kind.record")
        case "observation": return t("export.kind.observation")
        case "plan": return t("export.kind.plan")
        case "encounter": return t("export.kind.encounter")
        // F8 观察类型名复用既有映射（审查修复：PDF 此前直出英文 raw key
        // ——export.kind.* 与 observation.kind.* 两套映射合流，防漂移）
        default: return ObservationKind(rawValue: kind).map(observationKindName) ?? kind
        }
    }

    static func f16SyncDone(_ n: Int) -> String { String(format: t("f16.syncDoneFmt"), n) }

    static func f16SyncedRows(_ n: Int) -> String { String(format: t("f16.syncedRowsFmt"), n) }

    static func f16LastSync(_ time: String) -> String { String(format: t("f16.lastSyncFmt"), time) }

    static func f16NoRange(_ n: Int) -> String { String(format: t("f16.noRangeFmt"), n) }

    static func healthImportSubject(_ name: String) -> String { String(format: t("health.importSubject"), name) }

    static func healthImportPartial(_ count: Int) -> String { String(format: t("health.importPartial"), count) }

    static func healthWindowEnd(_ time: String) -> String { String(format: t("health.windowEnd"), time) }

    static func healthWindowStatistics(_ low: String, _ high: String, _ count: Int) -> String {
        String(format: t("health.windowStatistics"), low, high, count)
    }

    static func f19NextAppointment(_ a: String, _ d: String) -> String {
        String(format: t("f19.nextAppointmentFmt"), a, d)
    }

    static func f19RecentGlucose(_ v: String) -> String { String(format: t("f19.recentGlucoseFmt"), v) }

    static func f19MetricNotSupported(_ key: String) -> String {
        String(format: t("f19.metricNotSupportedFmt"), key)
    }

    static func f19StockRemaining(_ name: String, _ days: Int) -> String {
        String(format: t("f19.stockRemainingFmt"), name, days)
    }

    static func f19StockNoPlan(_ name: String) -> String { String(format: t("f19.stockNoPlanFmt"), name) }

    static func f19StockLocation(_ name: String, _ loc: String) -> String {
        String(format: t("f19.stockLocationFmt"), name, loc)
    }

    static func f19Expiring(_ name: String, _ d: String) -> String {
        String(format: t("f19.expiringFmt"), name, d)
    }

    static func f19Expired(_ name: String, _ d: String) -> String {
        String(format: t("f19.expiredFmt"), name, d)
    }

    static func f19ExpiryUnknown(_ name: String) -> String {
        String(format: t("f19.expiryUnknownFmt"), name)
    }

    static func f19StockNoMatch(_ name: String) -> String {
        String(format: t("f19.stockNoMatchFmt"), name)
    }

    static func f19SlotMedState(_ med: String, _ state: String) -> String {
        String(format: t("f19.slotMedStateFmt"), med, state)
    }

    static func f19MarkTakenNoMatch(_ name: String) -> String { String(format: t("f19.markTakenNoMatchFmt"), name) }

    static func f19MarkTakenDone(_ name: String) -> String { String(format: t("f19.markTakenDoneFmt"), name) }

    static func f19MarkTakenFailed(_ name: String) -> String { String(format: t("f19.markTakenFailedFmt"), name) }

    static func f19MarkTakenMultiple(_ names: String) -> String { String(format: t("f19.markTakenMultipleFmt"), names) }

    static func emergency_sos_holdA11y(_ seconds: Double) -> String {
        // 必须 Double + %1$.1f：Int 截断把 0.6 秒显示成「长按 0 秒激活」
        // （CI 34021989599 层级 dump 实证）——SOS 防误触语义在提示层失真
        String(format: t("emergency.sosHoldA11yFmt"), seconds)
    }

    static func startupDegradedBody(_ reason: String) -> String {
        String(format: t("startup.degradedBodyFmt"), reason)
    }

    static func f19MetricRecorded(_ v: Double) -> String { String(format: t("f19.metricRecordedFmt"), v) }

    static func f19QuestionRecorded(_ q: String) -> String { String(format: t("f19.questionRecordedFmt"), q) }

    static func asrModelVariantName(_ raw: String) -> String {
        switch raw {
        case "small": return asrModelVariantSmall
        case "medium": return asrModelVariantMedium
        case "large": return asrModelVariantLarge
        default: return raw
        }
    }

    static func asrModelVariantHint(_ variant: String, _ ramGB: String) -> String {
        String(format: t("asr.model.variantHint"), asrModelVariantName(variant), ramGB)
    }

    static func asrModelUpdate(_ version: String) -> String { String(format: t("asr.model.update"), version) }

    static func asrModelInstalled(_ version: String) -> String { String(format: t("asr.model.installed"), version) }

    static func asrModelCheckUpdates(_ count: Int) -> String { String(format: t("asr.model.checkUpdatesFmt"), count) }

    static func asrModelProgress(_ received: String, _ total: String) -> String {
        String(format: t("asr.model.progressFmt"), received, total)
    }

    static func asrModelModeSegmented(_ segments: Int) -> String {
        String(format: t("asr.model.modeSegmentedFmt"), segments)
    }

    static func voiceEngineName(_ choice: VoiceEngineChoice) -> String {
        switch choice {
        case .auto: return voiceEngineAuto
        case .classic: return voiceEngineClassic
        case .advanced: return voiceEngineAdvanced
        case .dictation: return voiceEngineDictation
        case .zipformer: return t("asr.zipformer")
        case .qwen3: return t("asr.qwen3")
        case .dolphin: return t("asr.dolphin")
        case .whisper: return t("asr.whisper")
        }
    }

    static func voiceEngineHint(_ choice: VoiceEngineChoice) -> String {
        switch choice {
        case .auto: return voiceEngineAutoHint
        case .classic: return voiceEngineClassicHint
        case .advanced: return voiceEngineAdvancedHint
        case .dictation: return voiceEngineDictationHint
        case .zipformer: return t("asr.zipformer.hint")
        case .qwen3: return t("asr.qwen3.hint")
        case .dolphin: return t("asr.dolphin.hint")
        case .whisper: return t("asr.whisper.hint")
        }
    }

    static func asrAvailability(_ availability: VoiceEngineAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .requiresNewerOS: return voiceLabRequiresNewerOS
        case .unsupportedDevice: return voiceLabUnsupported
        case .missingModelAssets: return t("asr.missingAssets")
        // round2 A-N6：「可下载」与「缺件」文案分离，不再共用「缺失或不完整」。
        case .downloadable: return t("asr.downloadable")
        }
    }

    static func timelineHubCount(_ kind: TimelineEntryKind, _ count: Int) -> String {
        String(format: t("timeline.hub.countFmt"), timelineKindName(kind), count)
    }

    static func timelineHubChildren(_ count: Int) -> String { String(format: t("timeline.hub.childrenFmt"), count) }

    static func timelineHubItems(_ count: Int) -> String { String(format: t("timeline.hub.itemsFmt"), count) }

    static func timelineHubConclusions(_ count: Int) -> String { String(format: t("timeline.hub.conclusionsFmt"), count) }

    static func healthExamReportsCount(_ count: Int) -> String { String(format: t("healthExam.reportsCountFmt"), count) }

    static func encounterLinkAppointmentConfirmTitle(_ name: String) -> String { String(format: t("encounter.linkAppointment.confirmFmt"), name) }
}
