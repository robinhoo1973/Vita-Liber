import SwiftUI
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
    @State private var backupState: BackupState

    init() {
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
        let captureStub: (any DocumentCapture)? =
            args.contains("-uitest-camera-fixture") ? FakeOcrProvider(fixture: true) : nil
        #else
        let gateUnlocker: (any GateUnlocking)? = nil
        let transcriptionStub: (any TranscriptionEngine)? = nil
        let captureStub: (any DocumentCapture)? = nil
        #endif
        _appState = State(initialValue: AppState(
            persistor: container.persistor,
            capture: captureStub,
            transcription: transcriptionStub,
            gateUnlocker: gateUnlocker,
            audit: container.audit,
            memberDeletion: container.memberDeletion))
        _reminderStore = State(initialValue: ReminderStore(
            meds: container.meds, apts: container.apts, reconciler: container.reconciler,
            scheduler: UNReminderScheduler(), composer: container.composer))
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
                        // 审计失败不阻断反馈交互
                    }
                }
            },
            quotaUseHook: { [store = container.entitlements] in
                // comercial §2.3：每次成功回答计一次额度（免费档 20 次/月）
                // 直连 EntitlementStore actor（AppEntitlementStore 展示侧 load 时同步）
                Task {
                    do { try await store.recordAIUse() }
                    catch { /* 额度计数失败不阻断回答 */ }
                }
            }))
        _settingsStore = State(initialValue: AppSettingsStore(store: container.settings))
        _observationState = State(initialValue: ObservationStoreState(
            store: container.observations, allergyStore: container.allergies,
            mediaAssets: container.mediaAssets))
        _entitlementStore = State(initialValue: AppEntitlementStore(store: container.entitlements))
        _trendState = State(initialValue: TrendEntryState(store: container.trends))
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
        _documentsState = State(initialValue: DocumentsState(
            store: container.documents,
            pipeline: OCRPipeline(
                recognizer: EngineRegistry.shared.resolve(OCRRecognizerFactory.self),
                grayscaleDecoder: GrayscaleImageDecoder())))
        _aiHistoryState = State(initialValue: AIHistoryState(store: container.aiHistory))
        _exportWizardState = State(initialValue: ExportWizardState(service: container.pdfExport))
        _f16DeviceState = State(initialValue: F16DeviceState(
            reader: container.healthReader, guidelines: container.guidelines,
            scheduler: UNReminderScheduler()))
        // 审查修复：BackupState 此前从未装配——SP-24 打开即
        // "No Observable object of type BackupState found" 崩溃
        _backupState = State(initialValue: BackupState(service: container.backup))
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
        AppRootView(seedBundled: { try await container.guidelines.seedBundled() },
                    launchReady: { [router, delegate = notificationDelegate] in
                        // 首帧后导航就绪（顺序不可反）：先恢复持久化 path，
                        // 再投递启动窗口内暂存的通知路由（crash 1/2 根因修复）
                        router.finishRestore()
                        delegate.markReadyAndDeliverPending()
                    })
            .environment(appState)
            .environment(reminderStore)
            .environment(assistantStore)
            .environment(settingsStore)
            .environment(observationState)
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
