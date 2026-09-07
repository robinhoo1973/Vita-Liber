import SwiftUI
import Combine   // AnyCancellable（TTL 倒计时订阅，第八轮会话令牌判读）
import Domain

/// ui-ux §5.8 就诊展示模式（FR8.6 · V3.72 点亮）：全屏临时解锁的时间线轮播——
/// 时间顺序的照片+描述+自述标记+用药背景，给医生看的「一眼版」。
/// 15 分钟剩余时间环 + [退出展示]；退出或超时自动重锁。
///
/// FR1.9 裁决后的会话令牌专用场景：进入需一次设备所有者认证，
/// 之后经 MediaUnlockSession（300s TTL）会话级解锁展示内容；
/// 敏感媒体逐容器认证（SensitiveMediaContainer）不受此影响。
struct DoctorShowcaseView: View {
    let patientId: UUID
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @Environment(MediaUnlockSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var remaining: TimeInterval = MediaUnlockPolicy.showcaseTTL
    @State private var authenticated = false
    /// 第八轮全仓审查修复（倒计时按需订阅 + 重新认证复位）：
    /// ① autoconnect 常开订阅在锁定占位态每秒空转（guard 返回）——改为
    /// authenticated 翻转时启停的 sink 订阅（锁定时零唤醒）；
    /// ② `remaining` 此前只在计时回调递减、从不复位——退后台重锁停在
    /// ~200s 后重新认证，新 300s 会话仍从 200 继续倒计，约提前 100s 被
    /// exit() 弹出。重新认证成功即复位 300。
    @State private var countdown: AnyCancellable?

    var body: some View {
        Group {
            // 第七轮全仓审查修复：会话令牌此前是死状态——isUnlocked 无任何
            // 读取方，300s TTL 空闲重锁/退后台重锁翻牌后展示内容照常渲染
            // （BR-007/008 会话级解锁形同虚设）。渲染门必须同时判读
            // authenticated 与会话令牌；令牌被 TTL 重锁 → 内容下线并给出
            // 重新认证入口（不得无出口转圈）。
            if authenticated && session.isUnlocked {
                // 渲染门必须同时判读装载成员：.task(id: patientId) 的加载是
                // 异步的，且 state.groups 为跨视图共享状态——首帧与加载竞态
                // 下会渲染上一成员/其他视图装载的观察组（BR-001/BR-007
                // 跨成员敏感媒体泄漏）。装载成功前只呈现加载态。
                if state.loadedPatientId == patientId {
                    showcaseContent
                } else if state.loadFailed {
                    ContentUnavailableView(L10n.observationListError,
                                           systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView()
                        .accessibilityIdentifier("SP-28.showcase.loading")
                }
            } else {
                // 认证前 / TTL 重锁后：锁占位 + 重新认证入口（无出口转圈）
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Button(L10n.sensitiveMedia_unlockToView) {
                        Task { await authenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 64)   // 关怀模式 ≥64pt
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L10n.showcaseTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 剩余时间环（300s 会话倒计时；≤60s 转警告色）
            ToolbarItem(placement: .topBarLeading) {
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining / MediaUnlockPolicy.showcaseTTL))
                        .stroke(remaining <= 60 ? Color("semantic-danger", bundle: .main)
                                                : Color("brand-primary", bundle: .main),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(ceil(remaining / 60)))")
                        .font(.caption2).monospacedDigit()
                }
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("SP-28.showcase.timer")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.showcaseExit) { exit() }
                    .accessibilityIdentifier("SP-28.showcase.exit")
            }
        }
        .onAppear {
            guard !authenticated else { return }
            Task { await authenticate() }
        }
        // 审查修复：展示模式必须按路由 patientId 加载该成员的观察组——此前
        // 直接渲染 ObservationStoreState.groups（上一成员浏览残留），跨成员
        // 敏感媒体泄漏（BR-001/BR-007），或冷启动恒空态。
        .task(id: patientId) {
            await state.load(patientId: patientId)
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            // 令牌被 TTL/退后台重锁 → 内容立即下线，重新认证（第七轮修复）
            if !unlocked { authenticated = false }
        }
        .onChange(of: authenticated) { _, on in
            if on { startCountdown() } else { stopCountdown() }
        }
        .onDisappear { stopCountdown(); exit() }
    }

    private func startCountdown() {
        stopCountdown()
        countdown = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if remaining <= 1 {
                    exit()
                } else {
                    remaining -= 1
                }
            }
    }

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
    }

    /// 进入展示模式需一次设备所有者认证（门禁联动，§5.8）；
    /// 认证成功后开 300s 会话令牌（FR1.9 专场景豁免）。onAppear 首次进入
    /// 与 TTL 重锁后的重新认证共用本路径（第七轮修复）。
    /// 第八轮修复：每次重新认证成功复位倒计时（新会话 = 全新 300s）。
    private func authenticate() async {
        if await app.requestUnlock(reason: L10n.showcaseUnlockReason) {
            remaining = MediaUnlockPolicy.showcaseTTL
            authenticated = true
            session.unlock()
        } else {
            dismiss()
        }
    }

    private var showcaseContent: some View {
        Group {
            if state.groups.isEmpty {
                ContentUnavailableView(L10n.showcaseEmpty, systemImage: "photo.on.rectangle.angled")
                    .accessibilityIdentifier("SP-28.showcase.empty")
            } else {
                TabView {
                    ForEach(state.groups) { group in
                        ShowcasePage(group: group)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
            }
        }
    }

    private func exit() {
        session.relock()   // 退出/超时自动重锁（BR-007/008）
        dismiss()
    }
}

/// 单组观察展示页：时间 + 类型 + 描述 + 自述标记 + 敏感媒体条（会话级解锁态渲染）
private struct ShowcasePage: View {
    let group: ObservationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let latest = group.latest {
                Text(latest.occurredAt.formatted(date: .long, time: .shortened))
                    .font(.headline)
                Text(L10n.observationKindName(group.kind))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let description = latest.description, !description.isEmpty {
                    Text(description).font(.body)
                }
                if let mark = latest.selfMark {
                    // 展示名经 markName 映射（BR-006：只译值本身）——此前直接
                    // 渲染英文机器值 improved/unchanged/worsened
                    Text("\(ObservationDetailView.markName(mark))（\(L10n.observationSelfMark)）")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
                if !latest.mediaAssetIds.isEmpty {
                    LockedMediaStrip(assetIds: latest.mediaAssetIds, memberId: latest.memberId)
                }
            }
            Spacer()
        }
        .padding(24)
    }
}
