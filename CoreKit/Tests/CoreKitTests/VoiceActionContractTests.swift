import Foundation
import Testing
@testable import Domain

// binds: SU-M15-VOICE
/// FR17.19 B1 契约金样：目录 schema 完整性、计划/补槽/确认/动作资格、
/// 红线风险（BR-006/BR-012）与过期语义。全部纯函数，零资产、零网络。
@Suite("SU-M15-VOICE · B1 任务助手契约")
struct VoiceActionContractTests {

    private let patient = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    // MARK: - 目录完整性

    @Test("九意图目录：无 askAssistant，槽位/路由/确认标签全覆盖")
    func catalogCompleteness() {
        let keys = VoiceIntentCatalog.entries.map(\.key)
        #expect(keys.count == VoiceIntentKey.allCases.count)
        #expect(Set(keys).count == keys.count)
        #expect(!keys.contains(.unknown) == false)   // unknown 必须登记
        #expect(VoiceIntentKey(rawValue: "askAssistant") == nil) // D2 已退役
        for entry in VoiceIntentCatalog.entries {
            #expect(!entry.displayLabelKey.isEmpty)
            #expect(!entry.confirmationLabelKey.isEmpty)
            #expect(entry.route.rawValue.isEmpty == false)
            #expect(VoiceIntentCatalog.entry(for: entry.key).route == entry.route)
        }
        // 期一可自动分类 = metric/reminder/profile/note/unknown；其余四类靠显式改类。
        let fallback = VoiceIntentCatalog.entries.filter(\.classifiableFallback).map(\.key)
        #expect(fallback == [.recordMetric, .createReminder, .appendProfile,
                             .appendNote, .unknown])
    }

    @Test("策略：槽位 schema 与文法键对齐（指标/提醒/档案）")
    func slotKeysMatchGrammar() {
        let metricKeys = Set(VoiceGrammarDefaults.metricRules.map(\.metricKey))
        let metricEntry = VoiceIntentCatalog.entry(for: .recordMetric)
        #expect(Set(metricEntry.slots.map(\.key)) == metricKeys)
        #expect(Set(metricEntry.requiredAnyOfKeys) == metricKeys)

        let reminderEntry = VoiceIntentCatalog.entry(for: .createReminder)
        #expect(Set(reminderEntry.requiredAnyOfKeys) == ["time", "date", "hour"])
        #expect(reminderEntry.slots.contains { $0.key == "content" && $0.required })

        let profileKeys = Set(VoiceGrammarDefaults.profileRules.map(\.fieldKey))
        #expect(Set(VoiceIntentCatalog.entry(for: .appendProfile).requiredAnyOfKeys) == profileKeys)
    }

    // MARK: - 计划与补槽

    @Test("指标：文法命中即完整，确认后生成唯一 VerifiedAction")
    func metricPlanExecutesAfterConfirmation() {
        let result = VoiceIntentCatalog.classify("血压 148 92", confidence: 0.9)
        let plan = VoiceActionPlanner.plan(intentKey: result.suggestedTarget ?? "",
                                           transcript: "血压 148 92",
                                           drafts: result.fields,
                                           patientId: patient, source: .voice)
        #expect(plan.intent == .recordMetric)
        #expect(plan.grade == .draft)
        #expect(plan.missingRequiredKeys.isEmpty)
        #expect(plan.riskFlags.isEmpty)
        #expect(plan.slotValue(for: "blood_pressure_sys")?.value == "148")
        #expect(plan.slotValue(for: "blood_pressure_dia")?.value == "92")
        #expect(plan.slotValue(for: "blood_pressure_sys")?.rawText == "148")

        #expect(VoiceActionPlanner.verifiedActions(for: plan, confirmationId: UUID()).isEmpty)

        let confirmation = UUID()
        let confirmed = VoiceActionPlanner.confirming(plan, confirmationId: confirmation)
        let actions = VoiceActionPlanner.verifiedActions(for: confirmed, confirmationId: confirmation)
        #expect(actions.count == 1)
        #expect(actions.first?.kind == .recordMetric)
        #expect(actions.first?.slotValues["blood_pressure_sys"] == "148")
        #expect(actions.first?.rawTranscript == "血压 148 92")
        #expect(actions.first?.patientId == patient)
        #expect(actions.first?.idempotencyKey == "\(plan.planId.uuidString):recordMetric")
    }

    @Test("提醒：缺内容进确认卡；补槽硬上限一次")
    func reminderClarificationAndCap() {
        let result = VoiceIntentCatalog.classify("明天8点提醒我吃降压药", confidence: 0.9)
        let plan = VoiceActionPlanner.plan(intentKey: result.suggestedTarget ?? "",
                                           transcript: "明天8点提醒我吃降压药",
                                           drafts: result.fields,
                                           patientId: patient, source: .voice)
        #expect(plan.intent == .createReminder)
        // 文法未抽 content（期一三键+重复），必填缺失由确认卡承接。
        #expect(plan.missingRequiredKeys == ["content"])
        let prompt = VoiceActionPlanner.nextClarification(for: plan)
        #expect(prompt?.key == "content")

        let filled = VoiceActionPlanner.filling(plan, key: "content", value: "吃降压药")
        #expect(filled.missingRequiredKeys.isEmpty)
        #expect(filled.clarificationCount == 1)
        #expect(VoiceActionPlanner.nextClarification(for: filled) == nil) // 上限 1
        let confirmation = UUID()
        let actions = VoiceActionPlanner.verifiedActions(
            for: VoiceActionPlanner.confirming(filled, confirmationId: confirmation),
            confirmationId: confirmation)
        #expect(actions.first?.kind == .createReminder)
        #expect(actions.first?.slotValues["content"] == "吃降压药")
    }

    @Test("缺失必填以空槽占位；时间三键组内任一即可")
    func missingSlotsBecomeEditablePlaceholders() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.createReminder.rawValue,
                                           transcript: "提醒我吃药", drafts: [],
                                           patientId: patient, source: .text)
        #expect(plan.missingRequiredKeys == ["time", "content"])
        #expect(plan.slotValue(for: "time")?.isValid == false)
        #expect(plan.slotValue(for: "content")?.isValid == false)

        let withHour = VoiceActionPlanner.filling(plan, key: "hour", value: "8")
        #expect(withHour.missingRequiredKeys == ["content"]) // anyOf 组已满足
    }

    @Test("预约：仅医院/科室必填；时间留给表单 DatePicker；原文不冒充医院")
    func appointmentMissingFields() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.createAppointment.rawValue,
                                           transcript: "下周三去市医院复查", drafts: [],
                                           patientId: patient, source: .voice)
        #expect(plan.missingRequiredKeys == ["hospital", "department"])
        #expect(plan.slotValue(for: "hospital")?.isValid == false)
        #expect(plan.slotValue(for: "department")?.isValid == false)
        #expect(plan.slotValue(for: "time") == nil)
        #expect(plan.slots.contains { $0.key == "hospital" && $0.value == "下周三去市医院复查" } == false)
    }

    // MARK: - 原文归位与速记

    @Test("问诊问题：整句原文进 question 槽，确认后动作 kind=createQuestion")
    func questionUsesRawTextSlot() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.createQuestion.rawValue,
                                           transcript: "问医生这个药还要吃多久",
                                           drafts: [VoiceInputTemplate.fallbackDraft(value: "问医生这个药还要吃多久",
                                                                                     confidence: 0.6)],
                                           patientId: patient, source: .text)
        #expect(plan.slots.count == 1)
        #expect(plan.slotValue(for: "question")?.value == "问医生这个药还要吃多久")
        #expect(plan.missingRequiredKeys.isEmpty)
        let confirmation = UUID()
        let actions = VoiceActionPlanner.verifiedActions(
            for: VoiceActionPlanner.confirming(plan, confirmationId: confirmation),
            confirmationId: confirmation)
        #expect(actions.first?.kind == .createQuestion)
    }

    @Test("unknown：整句进 note，绝不静默丢弃")
    func unknownFallsBackToNote() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.unknown.rawValue,
                                           transcript: "今天天气不错", drafts: [],
                                           patientId: patient, source: .text)
        #expect(plan.intent == .unknown)
        #expect(plan.slotValue(for: "note")?.value == "今天天气不错")
        #expect(plan.missingRequiredKeys.isEmpty)
        let confirmation = UUID()
        let actions = VoiceActionPlanner.verifiedActions(
            for: VoiceActionPlanner.confirming(plan, confirmationId: confirmation),
            confirmationId: confirmation)
        #expect(actions.first?.kind == .appendNote)
        #expect(VoiceIntentCatalog.entry(for: .unknown).route == .note)
    }

    // MARK: - 红线与资格

    @Test("BR-012：急救词命中 → 风险标记，确认后也不生成动作")
    func emergencyNeverExecutes() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.appendNote.rawValue,
                                           transcript: "我胸痛喘不上气", drafts: [],
                                           patientId: patient, source: .voice)
        #expect(plan.riskFlags.contains(.emergency))
        let confirmation = UUID()
        let actions = VoiceActionPlanner.verifiedActions(
            for: VoiceActionPlanner.confirming(plan, confirmationId: confirmation),
            confirmationId: confirmation)
        #expect(actions.isEmpty)
    }

    @Test("BR-006：停药/调量 → 高风险标记，确认后也不生成动作")
    func highRiskTopicNeverExecutes() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.appendMedDraft.rawValue,
                                           transcript: "帮我停掉阿司匹林", drafts: [],
                                           patientId: patient, source: .voice)
        #expect(plan.riskFlags.contains(.highRiskTopic))
        let confirmation = UUID()
        #expect(VoiceActionPlanner.verifiedActions(
            for: VoiceActionPlanner.confirming(plan, confirmationId: confirmation),
            confirmationId: confirmation).isEmpty)
    }

    @Test("过期计划与确认 ID 不匹配均不可执行")
    func expiredOrMismatchedConfirmation() {
        let plan = VoiceActionPlanner.plan(intentKey: VoiceIntentKey.unknown.rawValue,
                                           transcript: "记一下", drafts: [],
                                           patientId: patient, source: .text)
        let confirmation = UUID()
        // 过期后确认：必须保持 draft，不得刷新 TTL 或升 C。
        let expiredConfirmation = VoiceActionPlanner.confirming(
            plan, confirmationId: confirmation, now: plan.expiresAt.addingTimeInterval(1))
        #expect(expiredConfirmation.grade == .draft)
        #expect(VoiceActionPlanner.verifiedActions(
            for: expiredConfirmation, confirmationId: confirmation).isEmpty)

        let confirmed = VoiceActionPlanner.confirming(plan, confirmationId: confirmation)
        let later = confirmed.expiresAt.addingTimeInterval(1)
        #expect(VoiceActionPlanner.verifiedActions(for: confirmed,
                                                   confirmationId: confirmation,
                                                   now: later).isEmpty)
        #expect(VoiceActionPlanner.verifiedActions(for: confirmed,
                                                   confirmationId: UUID()).isEmpty)
    }

    @Test("槽值复扫：编辑后的停药/调量措辞也触发高风险")
    func editedSlotValueIsRescanned() {
        let plan = VoiceActionPlanner.plan(
            intentKey: VoiceIntentKey.appendMedDraft.rawValue,
            transcript: "阿莫西林",
            drafts: [FieldDraft(key: "medicationName", value: "阿莫西林", confidence: 0.9)],
            patientId: patient, source: .text)
        #expect(!plan.riskFlags.contains(.highRiskTopic))
        let edited = VoiceActionPlanner.plan(
            intentKey: VoiceIntentKey.appendMedDraft.rawValue,
            transcript: "阿莫西林",
            drafts: [FieldDraft(key: "medicationName", value: "停掉阿莫西林", confidence: 1.0)],
            patientId: patient, source: .text)
        #expect(edited.riskFlags.contains(.highRiskTopic))
        let confirmation = UUID()
        #expect(VoiceActionPlanner.verifiedActions(
            for: VoiceActionPlanner.confirming(edited, confirmationId: confirmation),
            confirmationId: confirmation).isEmpty)
    }

    @Test("动作闭集与意图一一对应：unknown 只落 appendNote")
    func actionKindsAreClosed() {
        #expect(VoiceActionPlanner.actionKind(for: .recordMetric) == .recordMetric)
        #expect(VoiceActionPlanner.actionKind(for: .createAppointment) == .createAppointment)
        #expect(VoiceActionPlanner.actionKind(for: .appendMedDraft) == .appendMedDraft)
        #expect(VoiceActionPlanner.actionKind(for: .unknown) == .appendNote)
        #expect(VoiceActionKind.allCases.count == 8)
        // 禁止动作不在闭集内：markTaken/剂量/频次/急救/拨号。
        #expect(VoiceActionKind(rawValue: "markTaken") == nil)
        #expect(VoiceActionKind(rawValue: "changeDose") == nil)
        #expect(VoiceActionKind(rawValue: "callEmergency") == nil)
    }
}
