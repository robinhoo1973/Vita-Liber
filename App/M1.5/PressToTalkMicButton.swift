import SwiftUI
import Domain
import Protocols

/// FR17.1 / SP-55: hold to dictate; short tap and accessibility actions provide a toggle equivalent.
@MainActor
struct PressToTalkMicButton: View {
    let model: VoiceDictationModel

    var body: some View {
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
                        .symbolEffect(.variableColor.iterative,
                                      options: .repeating,
                                      isActive: model.phase == .recording)
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
                Text(L10n.voicenoteDictationFailed)
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

    private var ringColor: Color {
        model.phase == .recording
            ? Color("semantic-danger", bundle: .main)
            : Color("text-tertiary", bundle: .main)
    }
}

/// Recognition timers and touch termination share one identity, so release cannot also toggle a Button.
struct DictationPressState {
    enum EndAction: Equatable { case none, toggle, stop }
    private(set) var id: UUID?
    private var holding = false

    init() {}

    mutating func begin() -> UUID {
        if let id { return id }
        let id = UUID()
        self.id = id
        return id
    }

    mutating func recognize(_ id: UUID) -> Bool {
        guard self.id == id, !holding else { return false }
        holding = true
        return true
    }

    mutating func end(cancelled: Bool) -> EndAction {
        guard id != nil else { return .none }
        let action: EndAction = holding ? .stop : (cancelled ? .none : .toggle)
        id = nil
        holding = false
        return action
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
                        do { try await Task.sleep(nanoseconds: 200_000_000) }
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
            .onChange(of: touching) { _, active in
                if !active {
                    endPress(cancelled: true)
                    cancelledTouch = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
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
            .onChange(of: settings.values[.authVoiceDictation]) { _, _ in
                endPress(cancelled: true)
                prepareAuthorization()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
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
