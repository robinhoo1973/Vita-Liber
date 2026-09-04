import SwiftUI
import Domain
import Infrastructure
import Protocols

@main
struct VitaLiberApp: App {
    private let container: AppContainer   // init 内装配，body/task 复用（信源播种等）
    @State private var appState: AppState
    @State private var reminderStore: ReminderStore
    @State private var assistantStore: AssistantStore
    @State private var settingsStore: AppSettingsStore
    @State private var observationState: ObservationStoreState
    @State private var entitlementStore: AppEntitlementStore
    @State private var trendState: TrendEntryState
    @State private var voiceNoteState: VoiceNoteState
    @State private var m2Hub: M2HubStore

    init() {
        // 组装根（评审 A2：AppContainer 由 App 消费，AppState/ReminderStore 只面向协议）。
        // 数据层装配是启动不变量：live 失败降级 preview（内存库）；连内存库都建不出来
        // 意味着 SQLite 损坏——此时任何降级都无意义，显式终止并留清晰信息。
        let args = ProcessInfo.processInfo.arguments
        let container: AppContainer
        do {
            container = try AppContainer.live(databasePath: AppContainer.defaultDatabasePath())
        } catch {
            do { container = try AppContainer.preview() }
            catch {
                fatalError("数据层初始化失败（live 与 preview 均不可用）: \(error)")
            }
        }
        self.container = container
        // 门禁测试桩（XCUITest 无法自动化 Face ID）：-uitest-gate-stub-{success,fail}
        // 注入确定性认证结果；生产路径缺省 nil → LocalAuthGateUnlocker（真系统认证）
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
        _appState = State(initialValue: AppState(
            persistor: container.persistor,
            capture: FakeOcrProvider(fixture: args.contains("-uitest-camera-fixture")),
            gateUnlocker: gateUnlocker,
            transcription: transcriptionStub))
        _reminderStore = State(initialValue: ReminderStore(
            meds: container.meds, apts: container.apts, reconciler: container.reconciler))
        _assistantStore = State(initialValue: AssistantStore(provider: container.aiProvider))
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
            messages: container.messages, guidelines: container.guidelines))
    }

    var body: some Scene {
        // 门禁分支 / 生命周期补偿 / FR14.4 主题注入 均已下沉 AppRootView
        //（@Environment 读值 + preferredColorScheme 修饰符需 View 上下文）
        WindowGroup {
            AppRootView(seedBundled: { try await container.guidelines.seedBundled() })
                .environment(appState)
                .environment(reminderStore)
                .environment(assistantStore)
                .environment(settingsStore)
                .environment(observationState)
                .environment(entitlementStore)
                .environment(trendState)
                .environment(voiceNoteState)
                .environment(m2Hub)
        }
    }
}
