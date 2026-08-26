import SwiftUI

@main
struct VitaLiberApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    /// 退后台锁屏状态（FR1.4）：scenePhase 切 background 置位，回前台由门禁遮罩接管
    @State private var backgroundLocked = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.onboardingFinished {
                    OnboardingFlowView()
                } else if backgroundLocked {
                    LockOverlayView { backgroundLocked = false }
                } else {
                    RootAdaptiveView()
                }
            }
            .environment(appState)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundLocked = true          // FR1.4：退后台必见锁屏
            case .active:
                break                            // 解锁动作留给门禁遮罩（验证 PIN 后才消失）
            default:
                break
            }
        }
    }
}
