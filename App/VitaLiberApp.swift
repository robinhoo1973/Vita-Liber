import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

@main
struct VitaLiberApp: App {
    private let container: AppContainer   // init 内装配，body/task 复用（信源播种等）
    /// 审查修复：生产库打开失败的可见降级标记——非 nil 时 body 渲染
    /// 降级引导页而非主界面（绝不静默跑内存库写入）
    private let router: AppRouter
    /// §5.45 通知点击→路由映射契约：delegate 必须被强引用（UNUserNotificationCenter
    /// 对 delegate 是弱引用），故由 App 持有，路由经注入的 AppRouter 分发
    private let notificationDelegate: AppNotificationDelegate
    @State private var appState: AppState
    @State private var reminderStore: ReminderStore
    @State private var assistantStore: AssistantStore
    @State private var settingsStore: AppSettingsStore
    @State private var observationState: ObservationStoreState
    @State private var entitlementStore: AppEntitlementStore
    @State private var trendState: TrendEntryState
    @State private var voiceNoteState: VoiceNoteState
    @State private var m2Hub: M2HubStore
    @State private var searchState: SearchViewState
    @State private var encountersState: EncountersState
    @State private var timelineState: TimelineViewState
    @State private var questionsState: QuestionsState
    @State private var documentsState: DocumentsState
    @State private var aiHistoryState: AIHistoryState
    @State private var exportWizardState: ExportWizardState
    @State private var f16DeviceState: F16DeviceState
    /// 类型化数据变更信号（V3.49：文档保存/设备读数落库 → 版本计数 → 跨页刷新）
    @State private var dataChangeCenter: AppDataChangeCenter
    @State private var backupState: BackupState

    init() {
        // FR14.5 启动语言恢复（评审修正）：同步执行、首帧前完成——
        // 消除非默认语言用户首帧 zh-Hans 闪烁；不广播（重渲染由
        // settingsStore.values[.language] 观察驱动，见 AppRootView）。
        L10n.restoreLanguage()
        // 评审修正（§7 不静默吞）：审计/额度失败必须记日志（不阻断交互）。
        // 局部常量：init 闭包捕获 self 成员须待全部成员初始化，故此处用局部值。
        let logger = Logger(subsystem: "com.vitaliber", category: "app")
        // 组装根（评审 A2：AppContainer 由 App 消费，AppState/ReminderStore 只面向协议）。
        // 数据层装配是启动不变量：live 失败降级 preview（内存库）；连内存库都建不出来
        // 意味着 SQLite 损坏——此时任何降级都无意义，显式终止并留清晰信息。
        let args = ProcessInfo.processInfo.arguments
        // 审查修复：live 失败走显式降级容器（degradedReason 非 nil），
        // body 显示可见引导——原静默降级内存库、用户看到空档案且写入即丢
        let container = AppContainer.liveOrDegraded(databasePath: AppContainer.defaultDatabasePath())
        self.container = container
        let appRouter = AppRouter()
        self.router = appRouter
        let delegate = AppNotificationDelegate(router: appRouter)
        self.notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
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
        _appState = State(initialValue: AppState(
            persistor: container.persistor,
            transcription: transcriptionStub,
            gateUnlocker: gateUnlocker,
            audit: container.audit,
            memberDeletion: container.memberDeletion))
        _reminderStore = State(initialValue: ReminderStore(
            meds: container.meds, apts: container.apts, reconciler: container.reconciler,
            // 第八轮全仓审查修复：第七轮通道门只接到 AppointmentStore 与
            // ReminderReconciler——本 store 直连裸 UNReminderScheduler。
            // 改经组装根的投递门统一实例。门的作用域：dose-/slot- 的「静音
            // 仅横幅」真实生效（有应用内横幅承接）；预约/随访/临期/备份等
            // 无承接族照常系统投递（§5.58 降级链，W4 逐类别收紧）。
            scheduler: container.reminderScheduler, composer: container.composer))
        _assistantStore = State(initialValue: AssistantStore(
            provider: container.aiProvider,
            history: container.aiHistory,
            feedback: { kind in
                // FR12.8 反馈四键：本地留存（audit feedback 行动），P1 上报
                Task {
                    do {
                        try await container.audit.record(action: "feedback", entityType: "ai_answer",
                                                         entityId: kind, actorLocal: "owner", meta: nil)
                    } catch {
                        // 审计失败不阻断反馈交互，但必须上报（§7 不静默吞）
                        logger.error("AI 反馈审计失败: \(error)")
                    }
                }
            },
            quotaUseHook: { [store = container.entitlements] in
                // comercial §2.3：每次成功回答计一次额度（免费档 20 次/月）
                // 直连 EntitlementStore actor（AppEntitlementStore 展示侧 load 时同步）
                Task {
                    do { try await store.recordAIUse() }
                    catch {
                        // 额度计数失败不阻断回答，但必须上报（§7 不静默吞）
                        logger.error("AI 额度计数失败: \(error)")
                    }
                }
            }))
        // 单一实例：环境注入与 DocumentsState 授权闭包共用（AppRootView 启动即 load）
        let appSettings = AppSettingsStore(store: container.settings)
        _settingsStore = State(initialValue: appSettings)
        _observationState = State(initialValue: ObservationStoreState(
            store: container.observations, allergyStore: container.allergies,
            mediaAssets: container.mediaAssets))
        _entitlementStore = State(initialValue: AppEntitlementStore(store: container.entitlements))
        _trendState = State(initialValue: TrendEntryState(store: container.trends, audit: container.audit))
        _voiceNoteState = State(initialValue: VoiceNoteState(store: container.voiceNotes))
        _m2Hub = State(initialValue: M2HubStore(
            meds: container.meds, emergency: container.emergencyCards,
            immunizations: container.immunizations, claims: container.claims,
            messages: container.messages, guidelines: container.guidelines,
            audit: container.audit))
        _searchState = State(initialValue: SearchViewState(search: container.search))
        _encountersState = State(initialValue: EncountersState(store: container.encounters))
        _timelineState = State(initialValue: TimelineViewState(
            store: container.timelineQuery, problemStore: container.healthProblems))
        _questionsState = State(initialValue: QuestionsState(store: container.questions))
        // 类型化数据变更信号（先于 DocumentsState 装配——后者携带本实例注入）
        // 局部常量中转（审查修复）：init 内引用 State 包装值（dataChangeCenter）
        // 即触 self 属性访问——Swift 明确初始化纪律禁止全部存储属性就绪前
        // 触 self（L1 34192387824：编译器指名未初始化的 documentsState）。
        // 后续 State 的 initialValue 一律引用本局部常量，闭包惰性捕获不受限。
        let dataChange = AppDataChangeCenter()
        _dataChangeCenter = State(initialValue: dataChange)
        _documentsState = State(initialValue: DocumentsState(
            store: container.documents,
            pipeline: OCRPipeline(
                recognizer: EngineRegistry.shared.resolve(OCRRecognizerFactory.self),
                grayscaleDecoder: GrayscaleImageDecoder()),
            // FR14.1 authOcr 消费点：每次导入实时读授权（撤回即时生效）
            ocrAuthorized: { appSettings.values[.authOcr] != "false" },
            originalsDir: AppContainer.defaultOriginalsDir(),
            prescriptionStore: container.prescriptions,
            // FR17.18 期一（V3.49）：共享文本理解引擎 + F25 惰性接线 +
            // FR11.4 懒创建 + 保存后跨页刷新信号
            understandingEngine: EngineRegistry.shared.resolve(TextUnderstandingFactory.self),
            codeIndex: container.codeIndex,
            problemStore: container.healthProblems,
            dataChange: dataChange,
            pendingCards: container.pendingCards,
            // FR6.9 V3.61 页级实体卡：就诊/检验落库与稍后处理 1h 通知
            encounterStore: container.encounters,
            trendStore: container.trends,
            scheduler: container.reminderScheduler))
        _aiHistoryState = State(initialValue: AIHistoryState(store: container.aiHistory, audit: container.audit))
        _exportWizardState = State(initialValue: ExportWizardState(service: container.pdfExport))
        _f16DeviceState = State(initialValue: F16DeviceState(
            syncService: container.healthSync,
            dataChange: dataChange))
        // 审查修复：BackupState 此前从未装配——SP-24 打开即
        // "No Observable object of type BackupState found" 崩溃。
        // 且必须在此处先行赋值：下方 backgroundSyncHandler 的捕获列表
        // [appState] 创建时求值（触 self）——本 State 是最后一个未初始化
        // 存储属性，Swift 明确初始化纪律要求其先行（L1 34193285034）。
        _backupState = State(initialValue: BackupState(service: container.backup))
        // data-flow §9.2 恢复末步：重建提醒投影——此前恢复后零排程，恢复的
        // 计划要到下次回前台/重启才补排，恢复后首剂提醒静默漏发。回调在此
        // 装配（self 完全初始化之后）：init 内捕获 self 会触发「backupState
        // 未初始化」编译错（L1 34288551094）
        backupState.onRestored = { [appState, reminderStore] in
            await reminderStore.refreshTriggered(patientId: appState.currentPatientId, force: true)
        }
        // FR16.1 V3.86 后台自动化同步：BGTask 注册（App init 唯一注册点，
        // 标识符已登记 Info.plist BGTaskSchedulerPermittedIdentifiers）+
        // 后台唤起执行体（BG 启动无 UI——未建档/未授权即跳过，前台锚点
        // 兜底路径不受影响）
        HealthKitSyncService.registerBackgroundTask()
        let bgSync = container.healthSync
        let healthSettings = container.settings
        HealthKitSyncService.backgroundCancelHandler = { await bgSync.cancelSync() }
        HealthKitSyncService.backgroundSyncHandler = { [dataChange] in
            do {
                guard try await bgSync.canSync() else { return false }
                let start = try await healthSettings.value(for: .quietHoursStart)
                let end = try await healthSettings.value(for: .quietHoursEnd)
                let report = try await bgSync.performSync(quietStart: start, quietEnd: end)
                await MainActor.run {
                    if report.persistedRows > 0 { dataChange.metricsChanged() }
                    dataChange.alertsChanged()
                }
                await bgSync.scheduleBackgroundRefresh()
                return report.failedTypes.isEmpty
            } catch {
                await MainActor.run {
                    dataChange.metricsChanged()
                    dataChange.alertsChanged()
                }
                await bgSync.scheduleBackgroundRefresh()
                return false
            }
        }
        Task { await container.healthSync.startBackgroundObservation() }
    }

    var body: some Scene {
        // 门禁分支 / 生命周期补偿 / FR14.4 主题注入 均已下沉 AppRootView
        //（@Environment 读值 + preferredColorScheme 修饰符需 View 上下文）
        WindowGroup {
            if let reason = container.degradedReason {
                // 审查修复：生产库打开失败 → 可见降级页（不渲染主界面、
                // 不写入内存库——数据零风险）
                ContentUnavailableView(
                    L10n.startupDegradedTitle, systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(L10n.startupDegradedBody(reason)))
                    .accessibilityIdentifier("STARTUP.degraded")
            } else {
                mainRoot
            }
        }
    }

    /// 主界面装配（降级路径不执行——内存库上的环境装配无意义）
    @ViewBuilder
    private var mainRoot: some View {
        AppRootView(seedBundled: {
            try await container.guidelines.seedBundled()
            // F25 码表种子装载（V3.72）：装配层唯一调用点——幂等（app_settings
            // 记 bundle_version），失败记日志不阻断启动（码表缺 = 未解析态，FR25.1）
            try await container.codeIndex.loadBundledSeedsIfNeeded()
        })
            .environment(appState)
            .environment(reminderStore)
            .environment(assistantStore)
            .environment(settingsStore)
            .environment(observationState)
            .environment(dataChangeCenter)
            .environment(container.notificationCenterState)
            .environment(PendingCardCenterState(store: container.pendingCards))
            .environment(entitlementStore)
            .environment(trendState)
            .environment(voiceNoteState)
            .environment(m2Hub)
            .environment(container.mediaSession)
            .environment(router)
            .environment(searchState)
            .environment(encountersState)
            .environment(timelineState)
            .environment(questionsState)
            .environment(documentsState)
            .environment(aiHistoryState)
            .environment(exportWizardState)
            .environment(f16DeviceState)
            .environment(backupState)
    }
}
