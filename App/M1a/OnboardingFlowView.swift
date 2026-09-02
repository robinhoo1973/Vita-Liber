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
        case .done:
            EmptyView()
        }
    }
}

/// 门禁遮罩：退后台回前台必见（FR1.4）。验证成功（lastVerifiedAt 变化）→ 通知 App 解除。
/// FR1.7 任务切换器快照遮罩：遮罩本身为整屏不透明内容 + 背景模糊，
/// 系统快照截取时不会泄露医疗内容（亮度断言归 L2 人工复核，test-plan E3）。
struct LockOverlayView: View {
    @Environment(AppState.self) private var app
    var onUnlocked: () -> Void

    /// BR-012：SOS/急救信息豁免门禁。急救卡在锁屏上直接可达，
    /// 不需要、也不允许要求先解锁——伤者昏迷或由旁人操作时没人知道 PIN。
    @State private var showEmergency = false

    var body: some View {
        ZStack {
            Color("bg-grouped", bundle: .main).ignoresSafeArea()
            VStack(spacing: 24) {
                // 安全降级必须明示，不能只留日志（FR1.3 节流降级为内存态时告知用户）
                if app.pinThrottleDegraded {
                    Text(L10n.securityThrottleDegraded)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("SP-01.lockOverlay.degraded")
                }
                PinEntryView(mode: .verify)
                // 两步可达（长按 + 二次确认）由 SOSButton 承担防误触，规则在 Domain SOSRules
                SOSButton { showEmergency = true }
                    .accessibilityIdentifier("SP-01.lockOverlay.sos")
            }
        }
        .accessibilityIdentifier("SP-01.lockOverlay")
        .onChange(of: app.lastVerifiedAt) { _, value in
            if value != nil { onUnlocked() }
        }
        .sheet(isPresented: $showEmergency) {
            NavigationStack { EmergencyCardHubView() }
        }
    }
}
