import SwiftUI
import Domain
import Protocols
import Perception

/// FR17.1 / SP-55: hold to dictate; short tap and accessibility actions provide a toggle equivalent.
@MainActor
struct PressToTalkMicButton: View {
    let model: VoiceDictationModel

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(ringColor, lineWidth: model.phase == .recording ? 5 : 2)
                        .frame(width: model.phase == .recording ? 128 : 116,
                               height: model.phase == .recording ? 128 : 116)
                    Circle()
                        .fill(model.phase == .recording
                              ? Color("semantic-danger", bundle: .main).opacity(0.15)
                              : Color("bg-grouped", bundle: .main))
                        .frame(width: 104, height: 104)
                    VStack(spacing: 5) {
                        Image(systemName: model.phase == .recording ? "waveform" : "mic.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(model.phase == .recording
                                             ? Color("semantic-danger", bundle: .main)
                                             : Color("brand-primary", bundle: .main))
                            .recordingPulseCompat(isActive: model.phase == .recording)
                        if model.phase == .recording {
                            HStack(alignment: .center, spacing: 3) {
                                ForEach(Array([6.0, 12, 18, 12, 6].enumerated()), id: \.offset) { _, h in
                                    Capsule()
                                        .fill(Color("semantic-danger", bundle: .main))
                                        .frame(width: 3, height: h)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: model.phase)
                .frame(minWidth: 128, minHeight: 128)   // 触控目标 ≥64pt（关怀模式纪律）
                .accessibilityIdentifier("SP-55.panel.pressToTalk")
                .accessibilityLabel(model.phase == .recording ? L10n.voicenoteStop : L10n.voicenoteDictation)
                // 交互契约（业主 2026-09-16 第 5 项）：轻点开始/再点结束，也可按住说话。
                // 此前标签只说「语音速记」，用户（含 VoiceOver）无从得知规则——文案本身
                // 还在教「按住」（voicePanel.editHint 旧值）。
                .accessibilityHint(L10n.voicenoteTapHint)
                .modifier(DictationInteraction(model: model))

                // 聆听状态 / 部分文本 / 失败兜底 / 待机提示（§4.23 声波与聆听状态）
                switch model.phase {
                case .recording:
                    Text(model.isPreparing ? L10n.asrPreparing : L10n.voicenoteDictating)
                        .font(.subheadline)
                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                    if !model.partial.isEmpty {
                        Text(model.partial)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .accessibilityIdentifier("SP-55.panel.partial")
                    }
                case .failed:
                    Text(model.failureMessage)
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                case .idle:
                    Text(L10n.voicenoteDictation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if model.hasIncompleteTranscript {
                    Label(L10n.voiceDictationIncomplete, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("SP-55.panel.incomplete")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var ringColor: Color {
        model.phase == .recording
            ? Color("semantic-danger", bundle: .main)
            : Color("text-tertiary", bundle: .main)
    }
}

/// One touch-lifetime gesture serves both microphone views; accessibility invokes explicit model actions.
@MainActor
struct DictationInteraction: ViewModifier {
    let model: VoiceDictationModel
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var touching = false
    @State private var press = DictationPressState()
    @State private var holdTask: Task<Void, Never>?
    @State private var cancelledTouch = false

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, active, _ in active = true }
                    .onChanged { value in
                        guard isEnabled, scenePhase == .active, !cancelledTouch else { return }
                        // Preserve long-press movement cancellation instead of recording while the user scrolls.
                        if max(abs(value.translation.width), abs(value.translation.height)) > 10 {
                            cancelledTouch = true
                            endPress(cancelled: true)
                            return
                        }
                        guard press.id == nil else { return }
                        let id = press.begin()
                        holdTask = Task { @MainActor in
                            // 阈值 = 「点击开关」与「按住说话」的分界（DictationPressState.holdThreshold）。
                            // 抬手发生在阈值之前 → `.toggle`（本次点击即开关，业主第 5 项）；
                            // 到达阈值 → 按住说话（松手结束）。0.2s 的旧值把普通点击误判成按住，
                            // 一段几十毫秒的空录音后自报「未识别到语音」。
                            do { try await Task.sleep(nanoseconds: DictationPressState.holdThresholdNanoseconds) }
                            catch { return }
                            guard !Task.isCancelled, isEnabled, scenePhase == .active, press.recognize(id) else { return }
                            prepareAuthorization()
                            model.start()
                        }
                    }
                    .onEnded { _ in
                        endPress(cancelled: cancelledTouch)
                        cancelledTouch = false
                    })
                .onChangeCompat(of: touching) { _, active in
                    if !active {
                        endPress(cancelled: true)
                        cancelledTouch = false
                    }
                }
                .onChangeCompat(of: isEnabled) { _, enabled in
                    if !enabled { endPress(cancelled: true) }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggle() }
                .accessibilityAction(named: Text(L10n.voicenoteDictation)) {
                    guard isEnabled, scenePhase == .active else { return }
                    prepareAuthorization()
                    model.start()
                }
                .accessibilityAction(named: Text(L10n.voicenoteStop)) { model.stop() }
                .onAppear {
                    cancelledTouch = false
                    prepareAuthorization()
                }
                .onChangeCompat(of: settings.values[.authVoiceDictation]) { _, _ in
                    endPress(cancelled: true)
                    prepareAuthorization()
                }
                .onChangeCompat(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        break
                    case .inactive:
                        // 短暂失活（控制中心/来电横幅/系统弹窗）**不得**丢弃在录内容：
                        // 结束本次采集但保留交付（stop 走正常收尾），用户拉下控制中心
                        // 再收起时，已经说出的转写仍会落进草稿。原实现一律
                        // stopForDisappear()：作废会话、清空 partial、丢弃最终结果
                        // ——屏幕上的转写凭空消失（2026-09-16 评审，与「点击结束或暂停」
                        // 的预期相反）。
                        endPress(cancelled: true)
                        model.stop()
                    default:
                        endPress(cancelled: true)
                        model.stopForDisappear()
                    }
                }
                .onDisappear {
                    endPress(cancelled: true)
                    prepareAuthorization()
                    model.stopForDisappear()
                }
        }
    }

    private func prepareAuthorization() {
        model.setAuthorization(settings.values[.authVoiceDictation] != "false")
    }

    private func toggle() {
        guard isEnabled, scenePhase == .active else { return }
        prepareAuthorization()
        if model.phase == .recording { model.stop() } else { model.start() }
    }

    private func endPress(cancelled: Bool) {
        holdTask?.cancel()
        holdTask = nil
        switch press.end(cancelled: cancelled) {
        case .none: break
        case .toggle: toggle()
        case .stop: model.stop()
        }
    }
}
