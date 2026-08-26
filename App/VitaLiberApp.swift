import SwiftUI
import UIKit
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
    @State private var reminderStore: ReminderStore

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
        _appState = State(initialValue: AppState(
            persistor: container.persistor,
            capture: FakeOcrProvider(fixture: args.contains("-uitest-camera-fixture"))))
        _reminderStore = State(initialValue: ReminderStore(
            meds: container.meds, apts: container.apts, reconciler: container.reconciler))
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
            .environment(reminderStore)
            .task {
                await appState.bootstrap()
                // 四层补偿第 1 层（§5.4 V3.29）：前台启动时对账 + 首启请求通知授权
                if appState.onboardingFinished {
                    await reminderStore.requestNotificationAuthorization()
                    await reminderStore.refresh(patientId: appState.owner?.selfPatientId ?? appState.owner?.id)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if appState.isPinProtected { backgroundLocked = true }   // FR1.4：PIN 建立即锁
            case .active:
                // 四层补偿第 2 层：每次回前台轻量对账
                if appState.onboardingFinished {
                    Task {
                        await reminderStore.refresh(patientId: appState.owner?.selfPatientId ?? appState.owner?.id)
                    }
                }
            default:
                break
            }
        }
        // 四层补偿第 3 层：时区/时间显著变化 → 立即对账
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.significantTimeChangeNotification)) { _ in
            Task {
                await reminderStore.refresh(patientId: appState.owner?.selfPatientId ?? appState.owner?.id)
            }
        }
    }


}
