import SwiftUI
import Domain
import Protocols

/// FR8.9 / FR17.1 纯转写入口（观察创建 + 语音速记面板共用）：
/// 端上 SFSpeechRecognizer（`requiresOnDeviceRecognition=true`，offline-first）
/// 听写 → 实时部分文本 → 完成回调（调用方走 FR17.13 统一确认模板）。
///
/// 识别失败静默降级（FR8.9）：轻提示「可继续手动输入」，绝不阻断手输路径；
/// 音频零落盘由 TranscriptionEngine 类型级保证（FR17.7），本视图只接触文本。
struct VoiceDictationButton: View {
    @Environment(AppState.self) private var app
    /// 完成回调：文本 + 引擎置信度（落 C 级草稿、低置信强制复核由 FR17.13 模板承担）
    let onTranscript: (String, Double) -> Void

    private enum Phase: Equatable { case idle, recording, failed }
    @State private var phase: Phase = .idle
    @State private var partial = ""
    /// 生命周期绑定：视图消失即取消在途听写任务（防录音/音频会话悬空）
    @State private var dictationTask: Task<Void, Never>?

    private var recording: Bool { phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                startDictation()
            } label: {
                Label(recording ? L10n.voicenoteDictating : L10n.voicenoteDictation,
                      systemImage: recording ? "waveform" : "mic")
                    .frame(maxWidth: .infinity, minHeight: 44)   // 触控目标 ≥44pt（ui-ux §4.2）
            }
            .buttonStyle(.borderedProminent)
            .disabled(recording)
            .accessibilityIdentifier("voice.dictation.start")
            if recording && !partial.isEmpty {
                Text(partial)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("voice.dictation.partial")
            }
            if phase == .failed {
                Text(L10n.voicenoteDictationFailed)
                    .font(.caption)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
            }
        }
        .onDisappear {
            dictationTask?.cancel()   // 视图销毁即终止在途听写（引擎无内部取消，取消的是投递）
        }
    }

    private func startDictation() {
        // 重入守卫：.disabled 只是渲染态，快速双击的第二次点击在重渲染前仍会进来
        guard phase != .recording else { return }
        phase = .recording
        partial = ""
        PartialGate.shared.reset()   // 每次会话独立节流状态（跨会话文本不互相吞）
        dictationTask = Task { await dictate() }
    }

    private func dictate() async {
        let engine = app.transcriptionEngine
        // FR17.15：方言不可用时引擎内回落（SFSpeechTranscriber 已映射）；
        // 这里只补「无可用 locale 探测结果」的末级兜底——单一口径 TranscriptionSegmentation.fallbackLocale。
        let locale = engine.capability.availableLocales.first ?? TranscriptionSegmentation.fallbackLocale
        do {
            let result = try await engine.transcribe(
                TranscriptionRequest(localeIdentifier: locale),
                onPartial: { text in
                    PartialGate.shared.pass(text) { latest in
                        Task { @MainActor in
                            if phase == .recording { partial = latest }   // 视图已不在录音态则不投递
                        }
                    }
                })
            guard !Task.isCancelled else { return }   // 视图已消失：不投递、不改状态
            if !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
                phase = .idle
                onTranscript(result.text, result.confidence)
            } else {
                phase = .failed   // FR8.9：识别失败静默降级为手输并给输入框轻提示
            }
        } catch is CancellationError {
            return   // 视图级取消：非失败
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}

/// 部分结果节流门：SFSpeechRecognizer 每秒数次回调，文本未变即跳过——
/// 避免高频 Task 分配与重复渲染；文本变化立即放行（不引入丢尾部风险）。
/// 每次会话 startDictation 时 reset，跨会话/跨屏不串扰。
private final class PartialGate: @unchecked Sendable {
    static let shared = PartialGate()
    private let lock = NSLock()
    private var lastText = ""

    func pass(_ text: String, deliver: (String) -> Void) {
        lock.lock()
        let changed = text != lastText
        if changed { lastText = text }
        lock.unlock()
        if changed { deliver(text) }
    }

    func reset() {
        lock.lock()
        lastText = ""
        lock.unlock()
    }
}
