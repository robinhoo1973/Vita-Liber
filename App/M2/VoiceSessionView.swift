import SwiftUI
import os
import Domain
import Protocols

/// F19 关怀语音助手会话 UI（M3 零阻塞项的后半场）。
///
/// 状态机在 Domain（`VoiceConversationEngine`，纯函数）——本层只做三件事：
/// 1. 把用户输入（转写/键盘）喂给状态机，渲染事件（speak / askOptions /
///    requireRepeatObject / execute / rejectForbidden / exitGracefully）；
/// 2. TTS 经 `AppState.speak` 出口（SpeechSynthesizing 端口）；
/// 3. FR19.1：退出前台立即停止聆听（scenePhase 观察）。
///
/// 零业务判断（tech-spec §1.1 规则 4）：危险分级、拒绝、超时全部由状态机裁决。
///
/// 转写接入说明：`TranscriptionEngine` 端口已就绪，但语音结构化路径受
/// FR17.4 定标放行线门控（`FeatureFlags.voiceStructuringEnabled == false`）。
/// 因此当前会话态以键盘输入驱动（F19 的降级路径）；引擎接入后同一视图
/// 直接消费转写文本，交互状态零改动——这是刻意的：UI 不因能力开关分叉。

// MARK: - 会话状态仓

@MainActor
@Observable
final class VoiceSessionState {
    private(set) var engineState = ConversationState()
    private(set) var caption = ""              // 与播报一致的屏幕字幕（FR19.3）
    private(set) var options: [String] = []
    private(set) var pendingObject: String?    // 拨号复述对象（FR19.5）
    private(set) var rejected = false
    private(set) var isListening = false
    private(set) var ended = false

    private let logger = Logger(subsystem: "com.vitaliber", category: "voicesession")

    func clearPendingObject() { pendingObject = nil }
    func clearOptions() { options = [] }
    func clearRejection() { rejected = false }
    func end() { ended = true; isListening = false }
    func start() { isListening = true }
    func pause() { isListening = false }       // 退出前台（FR19.1）
    func resume() { isListening = true }

    /// 输入一轮（转写文本或键盘输入）→ 渲染事件。
    /// 返回需要执行的动作（callContact/callEmergency120 的拨号 payload、
    /// 导航落点）——执行由视图层承担，状态机不接触 UIApplication。
    @discardableResult
    func submit(_ text: String, speak: (String) -> Void) -> VoiceCommand? {
        let (newState, events) = VoiceConversationEngine.step(state: engineState,
                                                              transcript: text)
        engineState = newState
        // 引擎相位是唯一事实源：离开复述相位即清除本地镜像
        if newState.phase != .repeatingObject { pendingObject = nil }
        var executed: VoiceCommand?
        for event in events {
            switch event {
            case .speak(let t):
                caption = t
                speak(t)                 // FR19.3：TTS 播报与屏幕字幕一致
            case .askOptions(let opts):
                options = opts
            case .requireRepeatObject(let obj):
                pendingObject = obj
            case .execute(let command, let payload):
                executed = command
                caption = L10n.f19Executed(command.rawValue) + (payload.map { "（\($0)）" } ?? "")
                if command == .callContact || command == .callEmergency120 {
                    pendingObject = payload
                }
            case .rejectForbidden:
                rejected = true
            case .exitGracefully:
                ended = true
                isListening = false
            }
        }
        return executed
    }
}

// MARK: - 关怀模式首页入口卡（FR19.1：关怀模式首页大卡 [开始语音]）

struct VoiceSessionLaunchCard: View {
    @Environment(AppState.self) private var app
    @State private var showSession = false

    var body: some View {
        if app.careMode {
            Button {
                showSession = true
            } label: {
                HStack(spacing: 12) {
                    VLIcon.mic.resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.f19_launch).font(.title3).bold()
                        Text(L10n.f19_listeningHint).font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 72)   // 关怀模式 72pt 大卡
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(Color("bg-grouped", bundle: .main)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("F19.session.launchCard")
            .fullScreenCover(isPresented: $showSession) {
                VoiceSessionView()
            }
        }
    }
}

// MARK: - 会话视图

struct VoiceSessionView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var session = VoiceSessionState()
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VLIcon.waveform.resizable().frame(width: 28, height: 28)
                Text(L10n.f19_sessionTitle).font(.title2).bold()
                Spacer()
                Button {
                    endSession()
                } label: {
                    VLIcon.stopOctagon.resizable().frame(width: 24, height: 24)
                        .frame(width: 64, height: 64)
                }
                .accessibilityLabel(L10n.f19_end)
                .accessibilityIdentifier("F19.session.end")
            }

            // 聆听状态（FR19.1：必须显示聆听状态与结束按钮）
            listeningIndicator

            captionBlock
            optionsBlock
            repeatConfirmBlock
            rejectionBlock

            Spacer()

            // 键盘降级输入（转写接入前驱动会话；接入后保留为兜底，FR19.6）
            HStack(spacing: 8) {
                TextField(L10n.f19_typeHint, text: $typed, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("F19.session.input")
                Button {
                    let text = typed
                    typed = ""
                    let executed = session.submit(text, speak: { app.speak($0) })
                    if let executed { handleExecution(executed, object: session.pendingObject) }
                } label: {
                    VLIcon.send.resizable().frame(width: 22, height: 22)
                        .frame(width: 64, height: 64)
                }
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("发送指令")
                .accessibilityIdentifier("F19.session.send")
            }
            .padding(.horizontal, 12)
        }
        .padding(16)
        .accessibilityIdentifier("F19.session.view")
        .onAppear { session.start() }
        .onChange(of: scenePhase) { _, phase in
            // FR19.1：退出后台立即停止监听（不结束会话，回前台可继续）
            if phase == .background {
                session.pause()
            } else if phase == .active {
                session.resume()
            }
        }
        .onChange(of: session.ended) { _, ended in
            if ended { dismiss() }
        }
    }

    // 四个条件块独立成 computed var：单一大 body 在 Swift 6.0 触发
    // type-check 超时（CI 实证「unable to type-check in reasonable time」）

    @ViewBuilder
    private var captionBlock: some View {
        // 屏幕字幕（与播报一致，FR19.3）
        if !session.caption.isEmpty {
            Text(session.caption)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color("bg-grouped", bundle: .main)))
                .accessibilityIdentifier("F19.session.caption")
        }
    }

    @ViewBuilder
    private var optionsBlock: some View {
        // 列选（FR19.4：≤3 项编号）
        if !session.options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        handleChoice(number: index + 1)
                    } label: {
                        HStack {
                            Text("\(index + 1)").bold().frame(width: 28)
                            Text(option)
                            Spacer()
                        }
                        .padding(10)
                        .frame(minHeight: 64)     // 关怀模式 ≥64pt
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color("surface-tint-start", bundle: .main).opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("F19.session.option.\(index + 1)")
                }
            }
        }
    }

    @ViewBuilder
    private var repeatConfirmBlock: some View {
        // 拨号复述确认（FR19.5）
        if let obj = session.pendingObject {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.f19RepeatObject(obj)).font(.headline)
                    .accessibilityIdentifier("F19.session.repeatObject")
                HStack(spacing: 16) {
                    Button(L10n.f19_cancel) {
                        _ = session.submit("取消", speak: { app.speak($0) })
                    }
                    .frame(minWidth: 88, minHeight: 64)
                    .accessibilityIdentifier("F19.session.cancelCall")
                    Button(L10n.f19_confirm) {
                        // 走引擎的 repeatingObject 确认语义——UI 触屏确认
                        // 与语音「确认」同一条路径，不绕过状态机（FR19.5）
                        let executed = session.submit("确认", speak: { app.speak($0) })
                        handleExecution(executed, object: session.pendingObject)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 88, minHeight: 64)
                    .accessibilityIdentifier("F19.session.confirmCall")
                }
            }
        }
    }

    @ViewBuilder
    private var rejectionBlock: some View {
        // 拒绝卡（FR19.5：删除/剂量变更一律拒绝 → 引导触屏）
        if session.rejected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VLIcon.ban.resizable().frame(width: 24, height: 24)
                    Text(L10n.f19_rejectedTitle).font(.headline)
                }
                Text(L10n.f19_goTouch).font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.f19_goTouch) { session.clearRejection() }
                    .frame(minHeight: 64)
                    .accessibilityIdentifier("F19.session.rejected.dismiss")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color("grade-d", bundle: .main).opacity(0.1)))
            .accessibilityIdentifier("F19.session.rejectionCard")
        }
    }

    private var listeningIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isListening ? Color.green : Color("text-tertiary", bundle: .main))
                .frame(width: 10, height: 10)
            Text(session.isListening ? L10n.f19_listeningHint : L10n.f19_stopped)
                .font(.caption).foregroundStyle(.secondary)
            if !session.isListening {
                Button(L10n.f19_paused) { session.resume() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("F19.session.resume")
            }
        }
        .accessibilityIdentifier("F19.session.listening")
    }

    private func handleChoice(number: Int) {
        let text = number == 1 ? "第一个" : number == 2 ? "第二个" : "第三个"
        let executed = session.submit(text, speak: { app.speak($0) })
        handleExecution(executed, object: session.pendingObject)
        session.clearOptions()
    }

    private func handleExecution(_ command: VoiceCommand?, object: String?) {
        guard let command else { return }
        switch command {
        case .callContact, .callEmergency120:
            // FR19.5：复述对象 + 确认之后才真正拨号
            if let object { performCall(object) }
            session.clearPendingObject()
        case .openTimeline, .goHome, .exitSession:
            // 会话以 fullScreenCover 呈现，无法直接驱动 Tab 切换——
            // 回落入口页并如实提示（FR19.3：不假装导航成功）
            _ = session.submit(command == .openTimeline ? "打开时间轴" : "回到首页",
                               speak: { app.speak($0) })
            dismiss()
        default:
            break
        }
    }

    private func performCall(_ object: String) {
        let number = object == "120" ? "120" : object
        guard let url = URL(string: "tel://\(number)") else { return }
        openURL(url)
    }

    private func endSession() {
        session.end()
        dismiss()
    }
}
