import SwiftUI
import Perception

/// M1a 首启流程编排（FR21.9 V3.39 简化切片：三卡 → 建档 → 添加家人 → 完成，
/// 无 PIN 步骤——门禁自首启完成后以系统设备所有者认证生效）。
/// V3.39：向导不再包含拍摄/OCR 确认/时间轴/首日行动卡步骤——
/// 资料采集走 SP-11 快速拍摄/SP-10 资料库生产管线（用户主动触发），
/// 首日引导三张行动卡由首页空态引导（SP-04 newUserGuide）承载。
struct OnboardingFlowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        WithPerceptionTracking {
            // §5.62 三步进度条（V3.39：三卡/建档/家人——仅初始化用户信息相关步骤）
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { idx in
                        // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                        WithPerceptionTracking {
                            Capsule()
                                .fill(idx <= stepIndex
                                      ? Color("brand-primary", bundle: .main)
                                      : Color("bg-grouped", bundle: .main))   // 语义令牌（token-only 纪律，不用系统调色板）
                                .frame(height: 4)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                switch app.stage {
                case .disclosure(let i):
                    // else 分支为防御性兜底（disclosureCards 为空时索引越界→空白而非崩溃）
                    if i < app.disclosureCards.count {
                        DisclosureCardsView(card: app.disclosureCards[i])
                    } else {
                        EmptyView()
                    }
                case .ownerName:
                    OwnerSetupView()
                case .addFamily:
                    // FR21.9 ④ 添加家人（可跳过）——向导最后一步
                    AddFamilyStepView()
                }
            }
        }
    }

    /// 三步映射：三卡/本人档案/添加家人
    private var stepIndex: Int {
        switch app.stage {
        case .disclosure: return 0
        case .ownerName: return 1
        case .addFamily: return 2
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
    @Environment(\.scenePhase) private var scenePhase
    var onUnlocked: () -> Void

    @State private var showEmergency = false
    /// 认证失败提示（自动尝试失败或手动按钮失败后显示；下次尝试前清空）
    @State private var failedOnce = false
    /// 自动尝试状态机（替换原 sawBackground × didAutoAttempt 双布尔——
    /// 四态含一非法态，每次扩展重试策略都要重推两张旗的交互）：
    /// pending = 尚未自动尝试 / attempted = 本生命周期已自动尝试过
    /// （防「取消 → .inactive→.active → 再弹」死循环）/ backgrounded =
    /// 经历过真退后台（.background）——Face ID 系统浮层只到 .inactive，
    /// 以此区分「用户离开应用」与「认证浮层自身的场景波动」
    @State private var autoGate: AutoGate = .pending
    /// 认证在途守卫（审查修复，E5 同族）：手动按钮与自动尝试、连点都会
    /// 并发 LAContext 求值——复用旧 context 或双弹认证层导致第二个必败
    /// 且可能双弹（LocalAuthGateUnlocker 注记），与敏感媒体容器的
    /// `unlocking` 守卫同纪律。
    @State private var attemptInFlight = false

    private enum AutoGate {
        case pending, attempted, backgrounded
    }

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color("bg-grouped", bundle: .main).ignoresSafeArea()
                    // 2026-09-19 审查修复：门禁改为覆盖层后，遮罩盖在**仍挂载**的内容视图之上——
                    // 纯 Color 不参与命中测试，点按会穿透到下方内容（锁定期间可操作病历）。
                    // contentShape + 空手势让背景层吸收全部触控；VStack 内按钮在子层级
                    // 优先命中，不受影响。
                    .contentShape(Rectangle())
                    .onTapGesture {}
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
                        Label(L10n.security_unlockButton, systemImage: "faceid")
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

                    // 两步可达（长按 + 二次确认）由 SOSButton 承担防误触，规则在 Domain SOSRules。
                    // FR18.6：锁屏 SOS 直达全屏求助页（唯一免门禁路径，安全优先于隐私）
                    SOSButton { showEmergency = true }
                        .accessibilityIdentifier("SP-01.lockOverlay.sos")
                }
            }
            // 容器 identifier 必须配 accessibilityElement(children: .contain)——
            // 否则 SwiftUI 把容器标识下放覆盖到每个子元素自身标识（解锁按钮的
            // SP-01.lockOverlay.unlock 被顶成 SP-01.lockOverlay，XCUITest 找不到，
            // CI 34021989599 实证层级 dump：两按钮同挂容器标识）。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-01.lockOverlay")
            .task {
                // 冷启动呈现遮罩即自动弹系统认证一次——必须等前台激活：遮罩在
                // 退后台（.inactive）也挂载，其 .task 随挂载立即执行，LAContext
                // 在非前台场景求值必失败（appNotForeground）且 .task 不因回前台
                // 重跑——回前台自动重试由下方 onChange(scenePhase) 驱动。
                // UI 测试用 -uitest-gate-no-auto 关断自动尝试（Face ID 无法自动化）
                guard app.gateAutoAttempts, scenePhase == .active else { return }
                autoGate = .attempted
                await attempt()
            }
            .onChangeCompat(of: scenePhase) { _, phase in
                // FR1.4「回前台必须重新认证、自动弹系统浮层」：仅从真后台返回时
                // 自动重试。审查修复：原实现每次 .active 都重试——自身 Face ID
                // 浮层取消/消失也令场景 inactive→active，形成「取消 → 立即再弹」
                // 死循环，锁屏 SOS（BR-012 免门禁路径）永不可达
                // 审查修复（冷启动回归）：autoGate 恒 pending 的冷启动首个
                // .active 必须补一次自动尝试（遮罩挂载于 .inactive、.task 守卫
                // 已跳过且不重跑）；attempted 防止浮层取消引发的
                // inactive→active 再次触发——每次遮罩生命周期最多自动一次。
                switch phase {
                case .background:
                    autoGate = .backgrounded
                case .active:
                    guard app.gateAutoAttempts else { return }
                    switch autoGate {
                    case .backgrounded:
                        autoGate = .attempted
                        failedOnce = false
                        Task { await attempt() }
                    case .pending:
                        autoGate = .attempted
                        Task { await attempt() }
                    case .attempted:
                        break
                    }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .onChangeCompat(of: app.lastUnlockedAt) { _, value in
                if value != nil { onUnlocked() }
            }
            .sheet(isPresented: $showEmergency) {
                SOSHelpView()
            }
        }
    }

    private func attempt() async {
        // 在途守卫：手动连点/手动+自动并发 → 只取第一次（并发二次求值
        // 必败且可能双弹认证层，与敏感媒体容器同纪律）
        guard !attemptInFlight else { return }
        attemptInFlight = true
        // 成功 → lastUnlockedAt 置位 → onChange 解除遮罩并销毁本视图；
        // 失败/取消 → 返回 false → 显示重试提示（遮罩留存可手动重试）
        let ok = await app.requestUnlock(reason: L10n.security_unlockReason)
        failedOnce = !ok
        attemptInFlight = false
    }
}
