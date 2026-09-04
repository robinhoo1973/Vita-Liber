import SwiftUI

/// M1a 首启流程编排（FR21.9 六步的 M1a 切片 V3.22：三卡 → 建档 → 拍摄 → 确认 → 时间轴，
/// 无 PIN 步骤——门禁自首启完成后以系统设备所有者认证生效）
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

/// 门禁遮罩：退后台回前台必见（FR1.4）。认证成功（lastUnlockedAt 变化）→ 通知 App 解除。
/// FR1.7 任务切换器快照遮罩：遮罩本身为整屏不透明内容 + 背景模糊，
/// 系统快照截取时不会泄露医疗内容（亮度断言归 L2 人工复核，test-plan E3）。
///
/// V3.22 生物识别门禁（ui-ux §5.1）：呈现即自动发起系统设备所有者认证浮层
/// （Face ID / Touch ID，系统兜底设备密码）；取消/失败停留在遮罩上可手动重试。
/// BR-012：SOS/急救信息豁免——急救卡在锁屏上直接可达，不需要、也不允许先解锁。
struct LockOverlayView: View {
    @Environment(AppState.self) private var app
    var onUnlocked: () -> Void

    @State private var showEmergency = false
    /// 认证失败提示（自动尝试失败或手动按钮失败后显示；下次尝试前清空）
    @State private var failedOnce = false

    var body: some View {
        ZStack {
            Color("bg-grouped", bundle: .main).ignoresSafeArea()
            VStack(spacing: 20) {
                VLIcon.faceid
                    .resizable().frame(width: 56, height: 56)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                Text(L10n.security_unlockTitle)
                    .font(.title2.bold())
                Text(L10n.security_unlockSubtitle)
                    .font(.footnote)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    failedOnce = false
                    Task { await attempt() }
                } label: {
                    Label(L10n.security_unlockButton, image: "ic-faceid")
                        .frame(maxWidth: 320, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("SP-01.lockOverlay.unlock")

                if failedOnce {
                    Text(L10n.security_unlockFailed)
                        .font(.caption)
                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                        .accessibilityIdentifier("SP-01.lockOverlay.failed")
                }

                // 两步可达（长按 + 二次确认）由 SOSButton 承担防误触，规则在 Domain SOSRules
                SOSButton { showEmergency = true }
                    .accessibilityIdentifier("SP-01.lockOverlay.sos")
            }
        }
        .accessibilityIdentifier("SP-01.lockOverlay")
        .task {
            // 冷启动/回前台呈现遮罩即自动弹系统认证一次。
            // 遮罩只在 needsLockScreen || backgroundLocked 时挂载，无需再问「是否需要解锁」；
            // UI 测试用 -uitest-gate-no-auto 关断自动尝试（Face ID 无法自动化）
            guard app.gateAutoAttempts else { return }
            await attempt()
        }
        .onChange(of: app.lastUnlockedAt) { _, value in
            if value != nil { onUnlocked() }
        }
        .sheet(isPresented: $showEmergency) {
            NavigationStack { EmergencyCardHubView() }
        }
    }

    private func attempt() async {
        // 成功 → lastUnlockedAt 置位 → onChange 解除遮罩并销毁本视图；
        // 失败/取消 → 返回 false → 显示重试提示（遮罩留存可手动重试）
        let ok = await app.requestUnlock(reason: L10n.security_unlockReason)
        failedOnce = !ok
    }
}
