import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// 主界面会话：原 `VitaLiberApp.init` 的 store 装配与全局启动副作用。
/// 只由 `ReadyAppRoot` 创建一次（holder 兜底防重复）；首帧前不构造。
@MainActor
final class AppSession: ObservableObject {
    let container: AppContainer
    let router: AppRouter
    /// §5.45 通知点击→路由映射契约：delegate 必须被强引用（UNUserNotificationCenter
    /// 对 delegate 是弱引用），故由 App 持有，路由经注入的 AppRouter 分发
    let notificationDelegate: AppNotificationDelegate
    let appState: AppState
    let reminderStore: ReminderStore
    let settingsStore: AppSettingsStore
    let avatarState: AvatarState
    let chatHistoryState: ChatHistoryState
    let observationState: ObservationStoreState
    let entitlementStore: AppEntitlementStore
    let trendState: TrendEntryState
    let voiceNoteState: VoiceNoteState
    let m2Hub: M2HubStore
    let searchState: SearchViewState
    let encountersState: EncountersState
    let timelineState: TimelineViewState
    let questionsState: QuestionsState
    let documentsState: DocumentsState
    /// 导出副本用户面（2026-10-27 存储边界委员会）：账本/镜像/对账唯一出口
    let documentExportState: DocumentExportState
    let exportWizardState: ExportWizardState
    let f16DeviceState: F16DeviceState
    /// 类型化数据变更信号（V3.49：文档保存/设备读数落库 → 版本计数 → 跨页刷新）
    let dataChangeCenter: AppDataChangeCenter
    /// 模型安装中心（2026-09-16）：下载进行态 App 级可观察（首页条目 + 设置页同源）。
    let asrInstallCenter: ASRInstallCenter
    /// T2 本机 LLM 模型安装中心（2026-10-09 换型+下载化批）：模型不随包、
    /// 运行时自 CNB 下载——状态与生命周期同样上提 App 层。
    let llmModelInstallCenter: LLMModelInstallCenter
    let backupState: BackupState
    /// 三切片目录状态（2026-10-28 切片-only）：SP-64/首启卡/更新中心唯一数据源。
    let catalogSlicesState: CatalogSlicesState
    /// 待办卡通知门面：有状态，必须在会话内单例化——根视图每次重算都新建
    /// 会清空 `items/detail`（2026-10-27 审查 P2）。
    let pendingCardCenterState: PendingCardCenterState
    let updateAdviceState: UpdateAdviceState
    /// 统一更新中心批（2026-10-07）：ASR 检查态 + 中心编排（App 级跨页存活）。
    let asrCheckState: ASRIndexCheckState
    let updateCenterState: UpdateCenterState

    init(container: AppContainer, router: AppRouter,
         notificationDelegate: AppNotificationDelegate,
         catalogSlicesState: CatalogSlicesState) {
        self.container = container
        let args = ProcessInfo.processInfo.arguments
        // 单一 owner（2026-10-27 审查 P1/P2）：目录状态由启动门创建后注入，
        // 避免启动卡与会话各建一份导致版本/进度/假失败分裂。
        self.catalogSlicesState = catalogSlicesState
        self.pendingCardCenterState = PendingCardCenterState(
            store: container.pendingCards, scheduler: container.reminderScheduler)
        // P3（2026-10-07）：通告面状态（provider 由组装根注入；缺省=全域不可用）。
        let adviceState = UpdateAdviceState(provider: container.updateAdvice)
        self.updateAdviceState = adviceState
        self.router = router
        self.notificationDelegate = notificationDelegate
        // 门禁测试桩（XCUITest 无法自动化 Face ID）：-uitest-gate-stub-{success,fail}
        // 注入确定性认证结果；生产路径缺省 nil → LocalAuthGateUnlocker（真系统认证）。
        // 审查修复：全部测试桩与 launch-arg 旁路收敛进 #if DEBUG——
        // 发布构建里不存在任何可绕过门禁/伪造 OCR 的启动参数开关。
        #if DEBUG
        let gateUnlocker: (any GateUnlocking)? =
            args.contains("-uitest-gate-stub-success") ? FakeGateUnlocker()
            : args.contains("-uitest-gate-stub-fail") ? FakeGateUnlocker(result: false)
            : nil
        // 语音转写测试桩（同 FakeGateUnlocker 纪律）：XCUITest 无法驱动真实麦克风/语音识别，
        // -uitest-transcription-stub 注入确定性脚本，FR8.9 静默降级路径才可确定性验证。
        let transcriptionStub: (any TranscriptionEngine)? =
            args.contains("-uitest-transcription-stub")
            ? StubTranscriptionEngine(capability: .baseline(), scripted: ["这是一段测试听写文本"])
            : nil
        // V3.39：-uitest-camera-fixture 样张注入退役——首启向导不再含拍摄/OCR 步，
        // BR-003 闸门覆盖在活管线：单元/验收测试直测 DocumentsState.commitDraft /
        // DocumentStore.confirmText（M1aAcceptanceTests）+ Domain 层 OcrConfirmationTests。
        #else
        let gateUnlocker: (any GateUnlocking)? = nil
        let transcriptionStub: (any TranscriptionEngine)? = nil
        #endif
        self.appState = AppState(
            persistor: container.persistor,
            transcription: transcriptionStub,
            gateUnlocker: gateUnlocker,
            audit: container.audit,
            memberDeletion: container.memberDeletion,
            codeIndex: container.codeIndex,
            lexiconSource: container.codeIndex)
        self.reminderStore = ReminderStore(
            meds: container.meds, apts: container.apts, reconciler: container.reconciler,
            // 第八轮全仓审查修复：第七轮通道门只接到 AppointmentStore 与
            // ReminderReconciler——本 store 直连裸 UNReminderScheduler。
            // 改经组装根的投递门统一实例。门的作用域：dose-/slot- 的「静音
            // 仅横幅」真实生效（有应用内横幅承接）；预约/随访/临期/备份等
            // 无承接族照常系统投递（§5.58 降级链，W4 逐类别收紧）。
            scheduler: container.reminderScheduler, composer: container.composer)
        // 单一实例：环境注入与 DocumentsState 授权闭包共用（AppRootView 启动即 load）
        let appSettings = AppSettingsStore(store: container.settings)
        self.settingsStore = appSettings
        self.avatarState = AvatarState(settings: appSettings)
        self.observationState = ObservationStoreState(
            store: container.observations, allergyStore: container.allergies,
            mediaAssets: container.mediaAssets)
        self.entitlementStore = AppEntitlementStore(store: container.entitlements)
        self.trendState = TrendEntryState(store: container.trends, audit: container.audit)
        self.voiceNoteState = VoiceNoteState(store: container.voiceNotes)
        self.m2Hub = M2HubStore(
            meds: container.meds, emergency: container.emergencyCards,
            immunizations: container.immunizations,
            messages: container.messages, guidelines: container.guidelines,
            audit: container.audit)
        self.searchState = SearchViewState(search: container.search)
        self.encountersState = EncountersState(store: container.encounters)
        self.timelineState = TimelineViewState(
            store: container.timelineQuery, problemStore: container.healthProblems)
        self.questionsState = QuestionsState(store: container.questions)
        // 单一镜像实例：会话删除清理与导出状态共用（2026-10-30 登记项：
        // 删除会话时同步移除 Files 副本，避免账本外键置 NULL 后的孤儿目录）。
        let documentExportMirror = DocumentExportMirror(
            ledger: container.documentExports,
            exportsBase: MediaRootPaths.documentsBase(),
            originalsDir: AppContainer.defaultOriginalsDir())
        self.chatHistoryState = ChatHistoryState(store: container.chatHistory,
                                                 exportMirror: documentExportMirror)
        // 类型化数据变更信号（先于 DocumentsState 装配——后者携带本实例注入）
        // 局部常量中转（审查修复）：init 内引用 State 包装值（dataChangeCenter）
        // 即触 self 属性访问——Swift 明确初始化纪律禁止全部存储属性就绪前
        // 触 self（L1 34192387824：编译器指名未初始化的 documentsState）。
        // 后续 State 的 initialValue 一律引用本局部常量，闭包惰性捕获不受限。
        let dataChange = AppDataChangeCenter()
        self.dataChangeCenter = dataChange
        let installCenter = ASRInstallCenter(dataChange: dataChange)
        self.asrInstallCenter = installCenter
        // T2 本机 LLM 模型安装中心（2026-10-09 换型+下载化批）：与 ASR 中心同构
        // （状态上提、进度分离观察域、完成广播）；首启语义 = 一次显式同意后自动补齐。
        let llmInstallCenter = LLMModelInstallCenter(dataChange: dataChange)
        self.llmModelInstallCenter = llmInstallCenter
        // 统一更新中心批（2026-10-07）：ASR 检查状态机上提为 App 级（跨页存活 +
        // 供中心编排驱动）；安装互斥口径与提升前按钮禁用条件逐字同源
        // （暂停中的安装不参与——任务已退出、暂存保留）。
        let asrCheckState = ASRIndexCheckState(
            isInstallActive: { installCenter.active.contains { !$0.isPaused } })
        self.asrCheckState = asrCheckState
        // 2026-10-28 切片-only：医疗域链改由三切片状态驱动（v4 状态保留到 B2 删除）。
        self.updateCenterState = UpdateCenterState(
            advice: adviceState,
            chains: [.asrModels: asrCheckState, .medicalData: catalogSlicesState])
        self.documentsState = DocumentsState(
            store: container.documents,
            pipeline: OCRPipeline(
                recognizer: EngineRegistry.shared.resolve(OCRRecognizerFactory.self),
                grayscaleDecoder: GrayscaleImageDecoder()),
            // FR14.1 authOcr/authAI 消费点：每次导入实时读授权（撤回即时生效）。
            // 审查修复：布尔读一律 SettingsRules.resolved（stored ?? defaultValue）
            // ——values 只存非默认覆盖（默认均为 "true"），裸 `== "true"` 把
            // 未落库的默认授权读成拒绝（装载前/装载失败时 OCR 恒 skipped、
            // AI 恒关闭，与设置页开关状态相反——SettingsViews 同批修复口径）。
            ocrAuthorized: { SettingsRules.resolved(appSettings.values[.authOcr], key: .authOcr) == "true" },
            aiAuthorization: { (SettingsRules.resolved(appSettings.values[.authAI], key: .authAI) == "true", appSettings.authAIRevision) },
            originalsDir: AppContainer.defaultOriginalsDir(),
            prescriptionStore: container.prescriptions,
            // FR17.18 期一（V3.49）：共享文本理解引擎 + F25 惰性接线 +
            // FR11.4 懒创建 + 保存后跨页刷新信号
            understandingEngine: EngineRegistry.shared.resolve(TextUnderstandingFactory.self),
            codeIndex: container.codeIndex,
            // F25 词表锚定（2026-09-21，FR25.12⑬）：词表来自同一码表实例；
            // 语区随界面语言设置（替代硬编码 zh_Hans）。
            lexiconSource: container.codeIndex,
            uiLocale: { Locale(identifier: SettingsRules.resolved(appSettings.values[.language], key: .language)) },
            problemStore: container.healthProblems,
            dataChange: dataChange,
            pendingCards: container.pendingCards,
            // 审查修复：encounterStore/trendStore 参数在 DocumentsState 中
            // 从未存储/引用（静默丢弃的装饰性接线）——删除参数与传参，
            // 避免未来「走注入仓持久化」的路径误以为已接线而静默不落库
            // （FR6.9 页级实体卡落库现走 OCRCardStore 原始 SQL 路径）
            scheduler: container.reminderScheduler,
            cardStore: OCRCardStore(writer: container.store.writer),
            // 子项目 D · D4-2：卡确认后「资料建议」采集/接受流（只读回执 → 逐项显式接受写资料 + 审计）
            suggestionStore: ProfileSuggestionStore(writer: container.store.writer))
        self.exportWizardState = ExportWizardState(service: container.pdfExport)
        self.documentExportState = DocumentExportState(
            store: container.documents,
            ledger: container.documentExports,
            mirror: documentExportMirror)
        self.f16DeviceState = F16DeviceState(
            syncService: container.healthSync,
            dataChange: dataChange,
            settings: appSettings)
        // 审查修复：BackupState 此前从未装配——SP-24 打开即
        // "No Observable object of type BackupState found" 崩溃。
        // 且必须在此处先行赋值：下方 backgroundSyncHandler 的捕获列表
        // [appState] 创建时求值（触 self）——本 State 是最后一个未初始化
        // 存储属性，Swift 明确初始化纪律要求其先行（L1 34193285034）。
        self.backupState = BackupState(service: container.backup)
        // data-flow §9.2 恢复末步：重建提醒投影——此前恢复后零排程，恢复的
        // 计划要到下次回前台/重启才补排，恢复后首剂提醒静默漏发。回调在此
        // 装配（self 完全初始化之后）：init 内捕获 self 会触发「backupState
        // 未初始化」编译错（L1 34288551094）
        backupState.onRestored = { [appState = self.appState, reminderStore = self.reminderStore] in
            await reminderStore.refreshTriggered(patientId: appState.currentPatientId, force: true)
        }
        // 2026-10-27 存储边界（E1）：非敏感提交件自动镜像——设置开关键在消费时读，
        // 关=零写入；敏感件由 commitDraft 侧过滤，闭包永不接收。
        documentsState.autoMirrorHook = { [exportState = self.documentExportState,
                                           settingsStore = self.settingsStore] documentID in
            guard settingsStore.values[.filesExportAutoMirror] == "true" else { return }
            _ = await exportState.exportCopy(documentID: documentID, conversationID: nil,
                                             conversationTitle: nil, allowSensitive: false)
        }
        // 业主 2026-09-17 定：健康写回接线（最后一个存储属性初始化之后装配；
        // 结构体 init 内逃逸闭包**必须用捕获列表**取属性值——闭包体直写
        // `appState` 触发「escaping closure captures mutating 'self' parameter」
        // （CI 35180851132 实证；`[appState, reminderStore]` 是既有通行形态）。
        f16DeviceState.ownerPatientID = { [appState = self.appState] in appState.owner?.selfPatientId }
        // 收口批E②（FR16.2 履约口径）：手录/自测读数分级+派发接线——此前
        // AlertRuleEngine.escalate 无生产调用方（手录读数永不参与 L1+ 判定）。
        // 落库后：窗口定级（连续 3 次越限）→ 合格事件 → 与设备轨同源派发
        // （L1 静默时段门 / L2+ 时间敏感）。分级/派发失败不阻断录入主流程。
        trendState.gradeManualReading = { [dataChange] patientId, metric in
            do {
                let event = try await container.guidelines.evaluateRecentManualReadings(
                    patientId: patientId, metricKey: metric.rawValue)
                if event != nil {
                    let quietStart = try await container.settings.value(for: .quietHoursStart)
                    let quietEnd = try await container.settings.value(for: .quietHoursEnd)
                    _ = try await container.healthSync.dispatchPendingElevated(
                        patientId: patientId, quietStart: quietStart, quietEnd: quietEnd)
                }
                await MainActor.run { dataChange.alertsChanged() }
            } catch {
                // 分级/派发失败静默容忍：读数已落库；下轮同步的待派发重试链兜底
                await MainActor.run { dataChange.alertsChanged() }
            }
        }
        trendState.writeBack = { [f16 = self.f16DeviceState] patientId, metric, value, secondaryValue, unit, measuredAt in
            await f16.writeBackSample(patientId: patientId, metric: metric, value: value,
                                      secondaryValue: secondaryValue, unit: unit, measuredAt: measuredAt)
        }
        // FR16.1 V3.86 后台自动化同步：BGTask 注册（App init 唯一注册点，
        // 标识符已登记 Info.plist BGTaskSchedulerPermittedIdentifiers）+
        // 后台唤起执行体（BG 启动无 UI——未建档/未授权即跳过，前台锚点
        // 兜底路径不受影响）
        let bgSync = container.healthSync
        let healthSettings = container.settings
        HealthKitSyncService.backgroundCancelHandler = { await bgSync.cancelSync() }
        // round5 Q2：分钟级回填执行体（BGProcessingTask / iOS 26 continued processing 共用）——
        // 轮数与时间预算由系统给的到期时间推算（Domain HealthSyncBacklogPolicy），积压排空即停止重排
        HealthKitSyncService.backgroundBackfillHandler = { [dataChange] budget in
            do {
                guard try await bgSync.canAutomaticallySync() else { return BackgroundJobOutcome(success: true, reschedule: false) }
                await MainActor.run { dataChange.healthSyncStarted() }
                let start = try await healthSettings.value(for: .quietHoursStart)
                let end = try await healthSettings.value(for: .quietHoursEnd)
                let interval = HealthSyncInterval.resolved(
                    try await healthSettings.value(for: .healthSyncIntervalMinutes))
                let report = try await bgSync.performSyncAll(
                    quietStart: start, quietEnd: end,
                    maxRounds: HealthSyncBacklogPolicy.maxRounds(for: budget),
                    timeBudget: budget, joinTimeout: .seconds(15),
                    cycleInterval: interval, enforceCycleInterval: true,
                    managedCycle: true)
                await MainActor.run {
                    if report.persistedRows > 0 { dataChange.metricsChanged() }
                    dataChange.alertsChanged()
                    dataChange.healthSyncProgress(
                        active: report.cycleCompletedAt == nil && report.cycleStartedAt != nil,
                        stableKinds: report.cycleStableKinds ?? 0,
                        totalKinds: report.cycleTotalKinds ?? HealthDataKind.allCases.count,
                        lastCompletedAt: report.cycleCompletedAt)
                }
                let more = HealthSyncBacklogPolicy.shouldRequestProcessing(remainingWindows: report.remainingWindows, hasMore: report.hasMore)
                // 2026-10-20：部分窗口失败不等于整次 BGTask 失败；把
                // setTaskCompleted(false) 留给致命态，避免系统降频。失败用重排重试。
                return BackgroundJobOutcome(success: true,
                                            reschedule: more || !report.failedTypes.isEmpty)
            } catch HealthImportStore.ImportError.busy {
                // 已有共享轮次在跑：本次回填不排队等；重排保留积压处理权。
                return BackgroundJobOutcome(success: true, reschedule: true)
            } catch is CancellationError {
                return BackgroundJobOutcome(success: false, reschedule: true)   // 到期打断：进度已逐类落盘，下次续排
            } catch {
                return BackgroundJobOutcome(success: false, reschedule: false)
            }
        }
        // S-6①（第九轮审查权重重判）：展示文案注入——Domain 不再持用户可见
        // 中文（知情 L1-L4 / 文档命名类型名），App 层经 L10n 映射；未注入
        // 路径（测试/预览）回落内置文案。
        DisclosureRegistry.labels = DisclosureRegistry.Labels(
            title: { key in L10n.disclosureTextTitle(key) },
            body: { key in L10n.disclosureTextBody(key) })
        OCRCardStore.namingLabels = DocumentNaming.Labels(
            forKind: { kind in
                let key: DocumentTypeKey? = switch kind {
                case "prescription": .prescription
                case "encounter": .outpatientRecord
                case "metric_sample": .labReport
                case "medication": .medicationLabel
                case "claim_item": .invoice
                case "immunization": .vaccineRecord
                default: nil
                }
                return key.map { L10n.docTypeName($0) } ?? ""
            },
            forDocType: { type in DocumentTypeKey(rawValue: type).map { L10n.docTypeName($0) } })
        HealthKitSyncService.backgroundSyncHandler = { [dataChange] in
            do {
                guard try await bgSync.canAutomaticallySync() else { return false }
                await MainActor.run { dataChange.healthSyncStarted() }
                let start = try await healthSettings.value(for: .quietHoursStart)
                let end = try await healthSettings.value(for: .quietHoursEnd)
                let interval = HealthSyncInterval.resolved(
                    try await healthSettings.value(for: .healthSyncIntervalMinutes))
                // C3（2026-10-03 评审修复）：后台每唤醒此前只跑 1 轮（1 页/类），
                // 20s 预算只用 2-7s——改多轮排空（预算内 ≤8 轮），唤醒次数 3-5× 降。
                // 实参顺序必须与声明一致（maxRounds 先于 timeBudget）——L1 编译修复 CI #646
                let report = try await bgSync.performSyncAll(
                    quietStart: start, quietEnd: end,
                    maxRounds: 8, timeBudget: .seconds(18),
                    joinTimeout: .seconds(5),
                    cycleInterval: interval, enforceCycleInterval: true,
                    managedCycle: true)
                await MainActor.run {
                    if report.persistedRows > 0 { dataChange.metricsChanged() }
                    dataChange.alertsChanged()
                    dataChange.healthSyncProgress(
                        active: report.cycleCompletedAt == nil && report.cycleStartedAt != nil,
                        stableKinds: report.cycleStableKinds ?? 0,
                        totalKinds: report.cycleTotalKinds ?? HealthDataKind.allCases.count,
                        lastCompletedAt: report.cycleCompletedAt)
                }
                await bgSync.scheduleBackgroundRefresh(
                    after: report.cycleCompletedAt != nil ? interval.seconds : nil)
                return true
            } catch HealthImportStore.ImportError.busy {
                // 共享轮次在跑：本次唤醒不排队等；不是失败，下一唤醒/回前台继续。
                await bgSync.scheduleBackgroundRefresh()
                return true
            } catch {
                await MainActor.run {
                    dataChange.metricsChanged()
                    dataChange.alertsChanged()
                }
                await bgSync.scheduleBackgroundRefresh()
                return false
            }
        }
        // C1-6（2026-10-04 评审）：投递唤醒专用轻量执行体——先排期 refresh（被系统
        // 切断也有兜底通道）再受限排空（2 轮/10s，Domain 唤醒源分型背板）；积压由
        // backfill 承接。预算依据：HealthKit 后台投递每次唤醒仅约 15s（社区实测，
        // 待 L2 复核）；refresh 作业保持 8 轮/18s 不变。
        HealthKitSyncService.backgroundObserverHandler = { [dataChange] kind in
            do {
                guard try await bgSync.canAutomaticallySync() else { return false }
                await MainActor.run { dataChange.healthSyncStarted() }
                await bgSync.scheduleBackgroundRefresh()
                // 2026-10-21 业主裁决：observer 带类别 → 只唤醒/同步该类别，
                // 不清其他类别的退避状态；预算也只给这一类。
                await bgSync.wake(kind: kind)
                let start = try await healthSettings.value(for: .quietHoursStart)
                let end = try await healthSettings.value(for: .quietHoursEnd)
                let interval = HealthSyncInterval.resolved(
                    try await healthSettings.value(for: .healthSyncIntervalMinutes))
                // completion 已由 Reader 提前确认；撞共享轮次最多等 2s。
                let report = try await bgSync.performSyncAll(
                    quietStart: start, quietEnd: end,
                    maxRounds: 2, timeBudget: .seconds(10),
                    joinTimeout: .seconds(2), kinds: [kind],
                    cycleInterval: interval, enforceCycleInterval: true,
                    managedCycle: true)
                await MainActor.run {
                    if report.persistedRows > 0 { dataChange.metricsChanged() }
                    dataChange.alertsChanged()
                    dataChange.healthSyncProgress(
                        active: report.cycleCompletedAt == nil && report.cycleStartedAt != nil,
                        stableKinds: report.cycleStableKinds ?? 0,
                        totalKinds: report.cycleTotalKinds ?? HealthDataKind.allCases.count,
                        lastCompletedAt: report.cycleCompletedAt)
                }
                await bgSync.scheduleBackgroundRefresh(
                    after: report.cycleCompletedAt != nil ? interval.seconds : nil)
                // 投递已确认（Reader 提前 completion）；部分失败由 refresh/backfill 重试。
                return true
            } catch {
                await MainActor.run {
                    dataChange.metricsChanged()
                    dataChange.alertsChanged()
                }
                return false
            }
        }
        // 2026-09-23 修复：启动入口改为统一维护（观察注册复核 + 刷新/回填请求重排）
        Task { await container.healthSync.maintainBackgroundAutomation() }
        AppSessionHolder.shared.install(self)
    }
}
