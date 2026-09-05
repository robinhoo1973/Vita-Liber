import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

/// M1a 纵向切片的应用状态仓（@Observable，注入进环境）。
/// 评审修正批（架构 A1-A3 / Swift S1-S2 / PM）：
/// - 持久化面向 M1aPersisting 协议，生产实现 = GRDBM1aPersistor（§4.3 对应表），
///   UserDefaults 仅承载 UI 瞬态与偏好——「窄实现」窄化能力，不换存储介质；
/// - 门禁（V3.22）= 系统设备所有者认证（FR1.1）：GateUnlocking 协议注入，
///   生产实现 LocalAuthGateUnlocker（Infrastructure），无应用内 PIN 与节流阶梯；
/// - 假 OCR 收敛到 FakeOcrProvider（DocumentCapture 协议），生产代码无 -uitest 分支。
@MainActor
@Observable
final class AppState {
    enum OnboardingStage: Equatable {
        case disclosure(index: Int)
        case ownerName
        case addFamily          // FR21.9 ④（可选，可跳过）
        case scanCapture, ocrConfirm, timeline
        case firstDayActions    // FR21.9 ⑥ 首日引导（全部可跳过）
        case done
    }

    var stage: OnboardingStage = .disclosure(index: 0)
    var onboardingFinished: Bool

    // 门禁（FR1.1 · V3.22：系统设备所有者认证，无应用内 PIN）
    private let gateUnlocker: any GateUnlocking
    /// 审计写入口（可选注入）：导出等审计动作经此落 audit_event（§7 七动作）
    private let audit: AuditLogWriter?
    private(set) var lastUnlockedAt: Date?

    // 所有者与档案
    private(set) var owner: LocalOwner?

    // 时间轴
    private(set) var timeline: [TimelineDocumentEntry] = []

    // L1 首启三卡确认（ConsentRecord 语义，FR20.5）
    private(set) var consentRecords: [ConsentRecord] = []

    private let persistor: any M1aPersisting
    private let captureProvider: any DocumentCapture
    /// FR3.4/FR3.5 成员删除与重新归属（影响清单 + 单事务；可选注入，测试可空）
    private let memberDeletion: MemberDeletionService?
    private let defaults: UserDefaults
    private let launchArgs: [String]
    private let logger = Logger(subsystem: "com.vitaliber", category: "appstate")

    /// TTS 端口（FR17.13/17.16）。默认经 EAL 注册表取生产适配器；测试注入 RecordingSpeechSynthesizer。
    let speechSynthesizer: any SpeechSynthesizing
    /// FR12.11 图片文字识别端口。默认经 EAL 注册表取生产实现；测试注入桩。
    let imageRecognizer: any ImageTextRecognizing
    /// F17 语音输入引擎端口（ADR-023，经 EAL 接入）。默认经注册表取；测试可注入。
    let transcriptionEngine: any TranscriptionEngine

    init(persistor: any M1aPersisting,
         capture: any DocumentCapture,
         speech: (any SpeechSynthesizing)? = nil,
         imageRecognizer: (any ImageTextRecognizing)? = nil,
         transcription: (any TranscriptionEngine)? = nil,
         gateUnlocker: (any GateUnlocking)? = nil,
         audit: AuditLogWriter? = nil,
         memberDeletion: MemberDeletionService? = nil,
         defaults: UserDefaults = .standard,
         launchArgs: [String] = ProcessInfo.processInfo.arguments) {
        // 组合根：按当前上下文一次性注册全部引擎能力（ADR-027 EAL）。
        // 评审修正：AppContainer.assemble 已先行注册（资产仓装配需要）——此处幂等守卫，
        // 避免二次注册覆盖（测试桩若先行注入会被冲掉）；AppState 独立构造（无容器）时仍自注册。
        if !EngineRegistry.shared.isRegistered(TranscriptionEngineFactory.self) {
            EngineRegistry.shared.registerDefaultEngines()
        }
        self.speechSynthesizer = speech ?? EngineRegistry.shared.resolve(SpeechSynthesisFactory.self)
        self.imageRecognizer = imageRecognizer ?? EngineRegistry.shared.resolve(OCRRecognizerFactory.self)
        self.transcriptionEngine = transcription ?? EngineRegistry.shared.resolve(TranscriptionEngineFactory.self)
        self.persistor = persistor
        self.captureProvider = capture
        self.gateUnlocker = gateUnlocker ?? LocalAuthGateUnlocker()
        self.audit = audit
        self.memberDeletion = memberDeletion
        // 评审修正：删除此处的 AVSpeechAdapter()/VisionImageRecognizer() 二次赋值——
        // 它在 EAL resolve 之后把结果覆盖回具体实现，注册表解析成为死代码，
        // ADR-027「调用方永不直接 import 具体引擎类型」名存实亡（半重构残留）。
        self.defaults = defaults
        self.voiceInterviewCompleted = Set(defaults.stringArray(forKey: "voiceInterviewSteps") ?? [])
        self.launchArgs = launchArgs
        self.onboardingFinished = defaults.bool(forKey: "onboardingFinished")
        if launchArgs.contains("-uitest-reset") {
            defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.vitaliber.VitaLiber")
            self.onboardingFinished = false
        }
        // V3.22 门禁改造：应用内 PIN 整体退役。旧哈希不再有验证入口，直接清除
        // （不做任何迁移——系统设备所有者认证严格强于 6 位应用 PIN）
        for key in ["pinHashV2", "pinHash", "failedAttempts", "lockedUntil",
                    "lockStage", "pinLockSnapshot"] {
            defaults.removeObject(forKey: key)
        }
        if onboardingFinished {
            stage = .done
        } else {
            // 三卡断点续填：重启后从上次进度的下一张卡继续
            let progress = defaults.integer(forKey: "disclosureProgress")
            if progress > 0 {
                stage = .disclosure(index: min(progress, disclosureCards.count - 1))
            }
        }
        // UI 测试种子：确定性注入「已完成首启」状态——
        // 锁屏用例不再依赖前序用例的持久化数据（跨用例状态依赖不可靠）
        if launchArgs.contains("-uitest-seed-finished") {
            onboardingFinished = true
            defaults.set(true, forKey: "onboardingFinished")
            stage = .done
        }
        // 门禁旁路：直接视为本会话已认证（非门禁用例避免遮罩；XCUITest 专用）
        if launchArgs.contains("-uitest-gate-bypass") {
            lastUnlockedAt = Date()
        }
    }

    /// 启动装配（VitaLiberApp .task 调用）：清态（UI 测试）→ 装配锁定状态机 →
    /// 从 GRDB 加载所有者/同意/时间轴。
    func bootstrap() async {
        if launchArgs.contains("-uitest-reset") {
            do { try await persistor.reset() }
            catch { logger.error("测试清态失败: \(error)") }
        }
        do {
            owner = try await persistor.loadOwner()
            consentRecords = try await persistor.loadConsents()
            timeline = try await persistor.loadTimeline()
        } catch {
            logger.error("持久化加载失败: \(error)")
        }
    }

    // MARK: - 披露三卡

    var disclosureCards: [DisclosureCard] { DisclosureRegistry.l1Cards }

    func advanceDisclosure() {
        guard case .disclosure(let i) = stage else { return }
        // 每张卡确认即落 ConsentRecord（FR20.5 / TC-M1a-05）；按 key 去重，
        // 杀进程重走三卡不得重复落库（评审修正）
        let card = disclosureCards[i]
        if !consentRecords.contains(where: { $0.key == card.key }) {
            let record = ConsentRecord(key: card.key, version: card.version,
                                       acceptedAt: Date().timeIntervalSince1970)
            consentRecords.append(record)
            persist { [persistor] in try await persistor.saveConsent(record) }
        }
        // 断点续填（FR21.9）：进度落盘，重启后从当前卡继续
        defaults.set(i + 1, forKey: "disclosureProgress")
        if i + 1 < disclosureCards.count {
            stage = .disclosure(index: i + 1)
        } else {
            stage = .ownerName     // V3.22：无 PIN 步骤，三卡直接进入建档
        }
    }

    /// FR20.3/FR20.5 L2-L4 场景须知确认：写入 ConsentRecord。
    /// FR20.5 变更重确认：同 key 但**版本变化**必须重新确认——
    /// 去重只看「同 key 同 version」，条款重大修订以差异摘要重确认一次。
    func recordConsent(key: String, level: Int, version: String) async {
        if consentRecords.contains(where: { $0.key == key && $0.version == version }) { return }
        let record = ConsentRecord(key: key, level: level, version: version,
                                   acceptedAt: Date().timeIntervalSince1970)
        consentRecords.append(record)
        persist { [persistor] in try await persistor.saveConsent(record) }
    }

    // MARK: - 门禁（系统设备所有者认证；FR1.1 · V3.22 无应用 PIN）

    /// 门禁在完成首启后恒激活：无需注册步骤，系统认证自可用即生效。
    /// 首启向导期间不锁（无健康数据可泄；敏感媒体另有逐次 deviceOwner 门禁）。
    var isGateEnabled: Bool { onboardingFinished }

    /// 冷启动即锁：门禁生效且本会话尚未通过设备所有者认证。
    /// 锁屏是「派生状态」而非「转场标志」——冷启动无 background→foreground
    /// 转场，原 backgroundLocked 标志不会置位（隐私红线）。
    var needsLockScreen: Bool { isGateEnabled && lastUnlockedAt == nil }

    /// 回前台自动弹系统认证浮层（默认开；XCUITest 用 -uitest-gate-no-auto 关闭保确定性）
    var gateAutoAttempts: Bool { !launchArgs.contains("-uitest-gate-no-auto") }

    /// 门禁/敏感媒体共用认证入口（BR-007 修订：任一次系统设备所有者认证成功
    /// 即证明持机者在场——每次调用都弹新系统浮层，不存在「顺带解锁」语义问题；
    /// 失败节流由系统处理：biometryLockout 后系统自动引导设备密码）。
    func requestUnlock(reason: String) async -> Bool {
        let ok = await gateUnlocker.authenticate(reason: reason)
        if ok {
            lastUnlockedAt = Date()
        } else {
            logger.error("门禁认证失败或取消")
        }
        return ok
    }

    // MARK: - 所有者

    func createOwner(name: String) {
        var o = LocalOwner(displayName: name, createdAt: Date().timeIntervalSince1970)
        let profile = PatientProfile(displayName: name, relation: "本人",
                                     createdAt: o.createdAt, updatedAt: o.createdAt)
        o.selfPatientId = profile.id
        owner = o
        defaults.set(profile.id.uuidString, forKey: "selfPatientId")
        persist { [persistor] in try await persistor.saveOwner(o, profile: profile) }
        stage = .addFamily      // FR21.9：建档后进 ④ 添加家人（可跳过）
    }

    /// FR21.9 ④ 添加家人（可跳过，跳过直接进拍摄）
    func finishAddFamilyStep() {
        stage = .scanCapture
    }

    /// FR21.9：建档可跳过——以「本人」占位，稍后在设置中修改。
    /// 占位档案必须与 createOwner 一样落盘：只存内存的话，重启后 loadOwner() 返回 nil，
    /// currentPatientId 退回兜底值，跳过建档期间录入的资料就与锚点失联（BR-001）。
    func skipOwner() {
        var o = LocalOwner(displayName: "本人", createdAt: Date().timeIntervalSince1970)
        let profile = PatientProfile(displayName: "本人", relation: "本人",
                                     createdAt: o.createdAt, updatedAt: o.createdAt)
        o.selfPatientId = profile.id
        owner = o
        defaults.set(profile.id.uuidString, forKey: "selfPatientId")
        persist { [persistor] in try await persistor.saveOwner(o, profile: profile) }
        stage = .addFamily      // FR21.9 ④（可跳过）
    }

    // MARK: - 拍摄与 OCR 确认（DocumentCapture 协议注入）

    private(set) var activeSet: OcrConfirmationSet?

    func captureSample() {
        Task {
            do {
                activeSet = try await captureProvider.capture()
                stage = .ocrConfirm      // activeSet 先于 stage 赋值（UI 渲染竞态修正）
            } catch {
                logger.error("拍摄管线失败: \(error)")
            }
        }
    }

    func confirmField(id: UUID) {
        guard var set = activeSet else { return }
        set.confirm(field: id)
        activeSet = set
    }

    func reviseField(id: UUID, to value: String) {
        guard var set = activeSet, let i = set.fields.firstIndex(where: { $0.id == id }) else { return }
        // FR6.4：修订历史带「谁改的、何时」（本机所有者为唯一修改人）
        _ = set.fields[i].revise(to: value, by: owner?.displayName ?? "owner", at: Date())
        activeSet = set
    }

    /// FR6.4 ✕ 放弃：字段置 rejected（保留原识别值，不入正式区）
    func rejectField(id: UUID) {
        guard var set = activeSet, let i = set.fields.firstIndex(where: { $0.id == id }) else { return }
        set.fields[i].reject()
        activeSet = set
    }

    /// BR-003：全部字段确认后才入时间轴正式区。
    /// FR6.1：识别结果独立落 ocr_result（原文块+置信度+引擎版本留痕），
    /// 与文档投影 meta 解耦——识别留痕可追溯、可重放。
    func commitToTimeline() {
        guard let set = activeSet, set.isUsableInTimeline,
              let patientId = owner?.selfPatientId ?? owner?.id else { return }
        let entry = TimelineProjection.entries(from: [set], patientId: patientId,
                                                occurredAt: Date().timeIntervalSince1970)[0]
        timeline.append(entry)
        persist { [persistor, timeline] in
            try await persistor.saveTimeline(timeline)
            try await persistor.saveOCRResult(documentId: set.documentId, fields: set.fields,
                                              engineVersion: "fake-ocr-v1")
        }
        activeSet = nil
        stage = .timeline
    }

    // MARK: - FR6.8 SP-53 待确认字段聚合队列（跨文档）

    /// 跨文档聚合全部未确认字段（72h 置顶由视图层按 entry.occurredAt 排序展示）
    func pendingOcrFields() -> [(entry: TimelineDocumentEntry, field: CandidateField)] {
        timeline.flatMap { entry in
            (entry.fields ?? [])
                .filter { !$0.isConfirmed && $0.grade != .rejected }
                .map { (entry, $0) }
        }
    }

    /// FR6.8 逐字段确认（队列与单文档工作台共用同一写路径）
    func confirmTimelineField(entryId: UUID, fieldId: UUID) {
        guard let i = timeline.firstIndex(where: { $0.id == entryId }) else { return }
        var fields = timeline[i].fields ?? []
        guard let j = fields.firstIndex(where: { $0.id == fieldId }) else { return }
        _ = fields[j].confirm()
        timeline[i].fields = fields
        persistTimeline()
    }

    func reviseTimelineField(entryId: UUID, fieldId: UUID, to value: String) {
        guard let i = timeline.firstIndex(where: { $0.id == entryId }) else { return }
        var fields = timeline[i].fields ?? []
        guard let j = fields.firstIndex(where: { $0.id == fieldId }) else { return }
        _ = fields[j].revise(to: value, by: owner?.displayName ?? "owner", at: Date())
        timeline[i].fields = fields
        persistTimeline()
    }

    func rejectTimelineField(entryId: UUID, fieldId: UUID) {
        guard let i = timeline.firstIndex(where: { $0.id == entryId }) else { return }
        var fields = timeline[i].fields ?? []
        guard let j = fields.firstIndex(where: { $0.id == fieldId }) else { return }
        fields[j].reject()
        timeline[i].fields = fields
        persistTimeline()
    }

    /// FR6.8「全部确认」闸门：仅当无红色低置信度字段时可用（Domain 判定）
    var queueAllConfirmAllowed: Bool {
        !pendingOcrFields().contains { ConfidenceTier.tier($0.field.confidence) == .low }
    }

    /// 全部确认（FR6.8）：逐字段确认（不含已放弃）
    func confirmAllPendingFields() {
        guard queueAllConfirmAllowed else { return }
        for (idx, entry) in timeline.enumerated() {
            var fields = entry.fields ?? []
            var changed = false
            for (j, field) in fields.enumerated() where !field.isConfirmed && field.grade != .rejected {
                fields[j].confirm()
                changed = true
            }
            if changed { timeline[idx].fields = fields }
        }
        persistTimeline()
    }

    private func persistTimeline() {
        persist { [persistor, timeline] in try await persistor.saveTimeline(timeline) }
    }

    func finishOnboarding() {
        onboardingFinished = true
        defaults.set(true, forKey: "onboardingFinished")
        stage = .done
    }

    /// FR21.9 ⑥ 首日行动卡（全部可跳过——点击进入对应流程并继续完成向导）
    func finishFirstDayActions() {
        finishOnboarding()
    }

    // MARK: - F3 成员管理（FR3.7 添加家人）

    private(set) var members: [PatientProfile] = []

    /// 当前成员（BR-001 所有资料按当前成员过滤的锚点）。
    /// 默认 = 本人档案；用户切换后持久化，重启保持。
    /// 兜底用会话级常量 UUID：`UUID()` 每次求值都不同，`.task(id: currentPatientId)`
    /// 会因 id 每次变化而无限取消重启（owner 未加载时的忙碌死循环），BR-001 锚点必须稳定。
    var currentPatientId: UUID {
        get {
            if let stored = defaults.string(forKey: "currentPatientId"),
               let id = UUID(uuidString: stored) { return id }
            return owner?.selfPatientId ?? owner?.id ?? Self.sessionFallbackPatientId
        }
        set { defaults.set(newValue.uuidString, forKey: "currentPatientId") }
    }

    private static let sessionFallbackPatientId = UUID()

    /// 语音访谈已完成步骤（持久化到 defaults——审查修复：原按 note 段落文本
    /// 扫描计分，切换显示语言后历史标记失配，完成度从 8 掉回 0；持久化键
    /// 与显示语言无关）
    private(set) var voiceInterviewCompleted: Set<String>

    /// 档案完善进度（首页进度卡 · mock 对齐项）：血型/证件/医保/生日 4 个直接字段
    /// + 语音访谈四段（过敏/既往史/当前用药/紧急联系人）。
    /// 展示性计算（非 BR 业务规则），随档案更新实时反映。
    var profileCompletion: (done: Int, total: Int) {
        let total = 8
        guard let p = members.first(where: { $0.id == currentPatientId }) else { return (0, total) }
        var done = 0
        if !(p.bloodType?.isEmpty ?? true) { done += 1 }
        if !(p.idNo?.isEmpty ?? true) { done += 1 }
        if !(p.insuranceNo?.isEmpty ?? true) { done += 1 }
        if !(p.birthDate?.isEmpty ?? true) { done += 1 }
        for step in ["allergy", "pastHistory", "currentMeds", "emergencyContact"]
        where voiceInterviewCompleted.contains(step) {
            done += 1
        }
        return (done, total)
    }

    /// 访谈完成一步即记录（适配器 onCommitField 调用；语言无关持久化）
    func markVoiceInterviewStep(_ key: String) {
        guard ["allergy", "pastHistory", "currentMeds", "emergencyContact"].contains(key) else { return }
        voiceInterviewCompleted.insert(key)
        defaults.set(Array(voiceInterviewCompleted), forKey: "voiceInterviewSteps")
    }

    func setCurrentPatient(_ id: UUID) {
        guard members.contains(where: { $0.id == id }) else { return }
        currentPatientId = id
    }

    func loadMembers() async {
        do { members = try await persistor.members() }
        catch { logger.error("成员加载失败: \(error)") }
    }

    // MARK: - FR3.1 字段补全 / FR3.4 删除 / FR3.5 重新归属

    /// FR3.1 成员字段更新（血型/证件号/医保号等补全）
    func updateMember(_ profile: PatientProfile) async -> Bool {
        do {
            try await persistor.updateMember(profile)
            await loadMembers()
            return true
        } catch {
            logger.error("成员更新失败: \(error)")
            return false
        }
    }

    /// FR3.4 影响清单（删除前展示）
    func memberDeletionImpact(patientId: UUID) async -> MemberDeletionService.Impact {
        guard let memberDeletion else { return MemberDeletionService.Impact() }
        do {
            return try await memberDeletion.impact(patientId: patientId)
        } catch {
            logger.error("影响清单查询失败: \(error)")
            return MemberDeletionService.Impact()
        }
    }

    /// FR3.4 删除成员：影响清单先行 + 姓名二次确认（UI）→ 单事务执行。
    /// 资料不删（软删成员行），计划/预约按选择「删除」或「停用归档」。
    func deleteMember(patientId: UUID, choice: MemberDeletionService.DeleteChoice) async -> Bool {
        guard let memberDeletion else { return false }
        do {
            try await memberDeletion.deleteMember(patientId: patientId, choice: choice)
            if let audit {
                try await audit.record(action: "delete", entityType: "patient_profile",
                                       entityId: patientId.uuidString, actorLocal: "owner",
                                       meta: "choice=\(choice.rawValue)")
            }
            if currentPatientId == patientId {
                currentPatientId = owner?.selfPatientId ?? patientId
            }
            await loadMembers()
            return true
        } catch {
            logger.error("成员删除失败: \(error)")
            return false
        }
    }

    /// FR3.5 重新归属：资料移给另一成员（留审计——归错人必须可溯）
    func reattributeDocument(documentId: UUID, from: UUID, to: UUID) async -> Bool {
        guard let memberDeletion else { return false }
        do {
            try await memberDeletion.reattributeDocument(documentId: documentId, from: from, to: to)
            if let audit {
                try await audit.record(action: "update", entityType: "document_file",
                                       entityId: documentId.uuidString, actorLocal: "owner",
                                       meta: "reattribute \(from.uuidString)→\(to.uuidString)")
            }
            return true
        } catch {
            logger.error("重新归属失败: \(error)")
            return false
        }
    }

    /// 添加家人。返回是否成功（配额弹墙由调用方先判 `PaywallRules
    /// .addingMemberWouldExceed`，业务判定在 Domain，本方法只执行写入）。
    @discardableResult
    func addMember(name: String, relation: String, birthDate: String?) async -> Bool {
        let now = Date().timeIntervalSince1970
        let profile = PatientProfile(displayName: name, relation: relation,
                                     birthDate: birthDate, createdAt: now, updatedAt: now)
        do {
            try await persistor.saveMember(profile)
            await loadMembers()
            return true
        } catch {
            logger.error("成员保存失败: \(error)")
            return false
        }
    }

    // MARK: - FR17.13 回读装配（M1.5）

    /// 无耳机回读偏好三态（FR14.7）。`总是` 仅关怀模式可设——
    /// 写入口经 `ReadbackPolicy.isSelectable` 二次校验，防备份恢复带回非法状态。
    var readbackPreference: ReadbackPreference {
        get {
            let raw = defaults.string(forKey: AppSettingKey.readBackOptIn.rawValue) ?? ""
            return ReadbackPreference(rawValue: raw) ?? .never
        }
        set {
            guard ReadbackPolicy.isSelectable(newValue, careMode: careMode) else {
                logger.error("拒绝设置回读偏好 \(newValue.rawValue)：非关怀模式不可选")
                return
            }
            defaults.set(newValue.rawValue, forKey: AppSettingKey.readBackOptIn.rawValue)
        }
    }

    /// 关怀模式（F18）。M1.5 只需读取以驱动回读决策与触点放大；全量随 M2。
    var careMode: Bool {
        // 审查修复：统一到 AppSettingKey.careModeEnable.rawValue（与设置仓
        // 双写镜像同键）；旧键 "careMode" 只读兼容（已装机用户平滑迁移）
        get {
            if defaults.object(forKey: AppSettingKey.careModeEnable.rawValue) != nil {
                return defaults.bool(forKey: AppSettingKey.careModeEnable.rawValue)
            }
            return defaults.bool(forKey: "careMode")
        }
        set {
            defaults.set(newValue, forKey: AppSettingKey.careModeEnable.rawValue)
            defaults.removeObject(forKey: "careMode")   // 旧键一次性迁移后移除
        }
    }

    /// SP-14 步骤1：记忆上次选择的观察类型（FR8.1 默认高亮）。
    /// 键登记于 AppSettingKey.observationDefaultKind（§5.28 键枚举单一事实源），
    /// 经注入 defaults（测试可换 suite、-uitest-reset 可清），视图不得直连 UserDefaults。
    /// 读时校验合法 case（历史/外部写入的非法值回落默认，不污染宫格选中态与落库 kind）。
    var observationLastKind: String {
        get {
            let stored = defaults.string(forKey: AppSettingKey.observationDefaultKind.rawValue) ?? ""
            return ObservationKind(rawValue: stored)?.rawValue
                ?? AppSettingKey.observationDefaultKind.defaultValue
        }
        set { defaults.set(newValue, forKey: AppSettingKey.observationDefaultKind.rawValue) }
    }

    /// FR22.4 数据与存储健康（真实值，禁止硬编码「正常」充当诊断）
    func databaseHealth() async throws -> (sizeBytes: Int64, integrityOK: Bool) {
        try await persistor.databaseHealth()
    }

    /// FR14.3 清空全部（影响清单先行由 UI 承担；审计记录保留——匿名化语义）
    func persistorReset() async throws {
        try await persistor.reset()
        timeline = []
        consentRecords = []
        members = []
    }

    /// FR22.4/FR13.10 上次备份时间（F22.4 备份健康展示；随备份完成写入）
    var lastBackupAt: TimeInterval? {
        let t = defaults.double(forKey: "lastBackupAt")
        return t > 0 ? t : nil
    }

    /// FR13.10 备份完成记时（F22.4 联动展示「最近备份」；提醒只引导不自动建包）
    func recordBackup(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: "lastBackupAt")
    }

    /// FR22.5 反馈提交（默认只附版本/系统/错误码/脱敏日志；截图/原文/媒体逐项勾选）
    /// 审查修复：detail（用户反馈正文）此前在函数体内从未使用——正文被
    /// 静默丢弃。现截断进 meta（保留前 200 字），审计事实不丢。
    func reportFeedback(category: String, detail: String, attachments: [Bool]) {
        guard let audit else { return }
        Task {
            do {
                let trimmed = String(detail.prefix(200))
                try await audit.record(action: "feedback", entityType: "user_feedback",
                                       entityId: category, actorLocal: "owner",
                                       meta: "attachments=\(attachments.map { $0 ? "1" : "0" }.joined()) detail=\(trimmed)")
            } catch {
                logger.error("反馈提交失败: \(error)")
            }
        }
    }

    /// FR6.7 报告识别问题（本地记录，P1 进审核后台）：写审计事实，不传医疗内容
    func reportRecognitionIssue(documentId: UUID) {
        guard let audit else { return }
        Task {
            do {
                try await audit.record(action: "feedback", entityType: "ocr_result",
                                       entityId: documentId.uuidString, actorLocal: "owner",
                                       meta: "kind=ocr_issue")
            } catch {
                logger.error("识别问题报告失败: \(error)")
            }
        }
    }

    /// FR24.5 代确认审计：「由你代确认」必须可查（同机照护者视图）
    func auditCaregiverConfirm(doseId: String, patientId: UUID) {
        guard let audit else { return }
        Task {
            do {
                try await audit.record(action: "confirm_field", entityType: "dose_log",
                                       entityId: doseId, actorLocal: "caregiver",
                                       meta: "onBehalfOf=\(patientId.uuidString)")
            } catch {
                logger.error("代确认审计失败: \(error)")
            }
        }
    }

    /// 审计：文档导出（§7 七动作之一）。未注入审计（测试/预览）时静默跳过。
    func auditExport(documentId: UUID, title: String) {
        guard let audit else { return }
        Task {
            do {
                try await audit.record(action: "export", entityType: "document",
                                       entityId: documentId.uuidString,
                                       actorLocal: "owner", meta: title)
            } catch {
                logger.error("导出审计失败: \(error)")
            }
        }
    }

    /// TTS 单出口。**只播报已确认的结构化字段**（脚本由 Domain 的
    /// `ReadbackPolicy.readbackScript` 生成，本方法不拼文案、不做业务判断）。
    /// 抽成方法而非在各视图直接调 AVSpeechSynthesizer，是为了让测试可替身、
    /// 也为了 FR17.16 输出语言指定将来只需改这一处。
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speechSynthesizer.speak(text, localeIdentifier: voiceOutputLocale)
    }

    /// FR17.16 语音输出语言（六选一）；无对应发声时由合成器回退普通话并轻提示。
    var voiceOutputLocale: String {
        defaults.string(forKey: "voiceOutputLocale") ?? TranscriptionSegmentation.fallbackLocale
    }

    /// FR17.16 输出语言写入口（语音语言选择器调用；全局实时生效，FR14.7 例外②类）
    func setVoiceOutputLocale(_ locale: String) {
        defaults.set(locale, forKey: "voiceOutputLocale")
    }

    /// 统一异步持久化出口（§7：错误必须经 Logger 上报，不静默吞掉）
    private func persist(_ op: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await op() }
            catch { logger.error("持久化失败: \(error)") }
        }
    }
}
