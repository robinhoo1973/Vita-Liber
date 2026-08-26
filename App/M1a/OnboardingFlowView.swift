import SwiftUI

/// M1a 首启流程编排（FR21.9 六步的 M1a 切片：三卡 → PIN → 建档 → 拍摄 → 确认 → 时间轴）
struct OnboardingFlowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.stage {
        case .disclosure(let i):
            if i < app.disclosureCards.count {
                DisclosureCardsView(card: app.disclosureCards[i])
            } else {
                EmptyView()
            }
        case .pinSetup:
            PinEntryView(mode: .setup)
        case .ownerName:
            OwnerSetupView()
        case .scanCapture:
            ScanCaptureView()
        case .ocrConfirm:
            OcrConfirmView()
        case .timeline:
            TimelineView()
        case .done, .pinVerify:
            EmptyView()
        }
    }
}

/// 门禁遮罩：退后台回前台必见（FR1.4）。验证成功（lastVerifiedAt 变化）→ 通知 App 解除。
struct LockOverlayView: View {
    @Environment(AppState.self) private var app
    var onUnlocked: () -> Void

    var body: some View {
        ZStack {
            Color("bg-grouped", bundle: .main).ignoresSafeArea()
            PinEntryView(mode: .verify)
        }
        .accessibilityIdentifier("SP-01.lockOverlay")
        .onChange(of: app.lastVerifiedAt) { _, value in
            if value != nil { onUnlocked() }
        }
    }
}
