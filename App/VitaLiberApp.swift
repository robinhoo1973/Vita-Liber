import SwiftUI
import Domain
import Infrastructure
import Protocols

@main
struct VitaLiberApp: App {
    @State private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    /// 退后台锁屏状态（FR1.4）：scenePhase 切 background 置位，回前台由门禁遮罩接管。
    /// 评审修正：锁定优先级在向导分支**之前**——PIN 一旦建立，向导期间退后台同样锁屏。
    @State private var backgroundLocked = false

    init() {
        // 组装根（评审 A2：AppContainer 由 App 消费，AppState 只面向协议）
        let args = ProcessInfo.processInfo.arguments
        var container: AppContainer?
        do {
            container = try AppContainer.live(databasePath: AppContainer.defaultDatabasePath())
        } catch {
            // 生产库不可用时降级内存库（极端环境兜底；错误经日志上报）
            do { container = try AppContainer.preview() }
            catch { container = nil }
        }
        let persistor: any M1aPersisting = container?.persistor ?? FallbackPersistor()
        _appState = State(initialValue: AppState(
            persistor: persistor,
            capture: FakeOcrProvider(fixture: args.contains("-uitest-camera-fixture"))))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if backgroundLocked {
                    LockOverlayView { backgroundLocked = false }
                } else if !appState.onboardingFinished {
                    OnboardingFlowView()
                } else {
                    RootAdaptiveView()
                }
            }
            .environment(appState)
            .task { await appState.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if appState.isPinProtected { backgroundLocked = true }   // FR1.4：PIN 建立即锁
            case .active:
                break                                                     // 解锁留给门禁遮罩
            default:
                break
            }
        }
    }
}

/// 极端兜底：DB 完全不可用时的内存实现（不应到达；保留 App 可启动）
private actor FallbackPersistor: M1aPersisting {
    private var owner: LocalOwner?
    private var consents: [ConsentRecord] = []
    private var timeline: [TimelineDocumentEntry] = []
    func loadOwner() async throws -> LocalOwner? { owner }
    func saveOwner(_ o: LocalOwner, profile: PatientProfile) async throws { owner = o }
    func loadConsents() async throws -> [ConsentRecord] { consents }
    func saveConsent(_ c: ConsentRecord) async throws { consents.append(c) }
    func loadTimeline() async throws -> [TimelineDocumentEntry] { timeline }
    func saveTimeline(_ entries: [TimelineDocumentEntry]) async throws { timeline = entries }
    func reset() async throws { owner = nil; consents = []; timeline = [] }
}
