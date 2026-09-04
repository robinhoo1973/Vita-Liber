import SwiftUI
import Domain
import Protocols

/// FR8.9 / FR17.1 纯转写入口（观察创建 + 语音速记面板共用）：
/// 端上 SFSpeechRecognizer（`requiresOnDeviceRecognition=true`，offline-first）
/// 听写 → 实时部分文本 → 完成回调（调用方走 FR17.13 统一确认模板）。
///
/// 识别失败静默降级（FR8.9）：轻提示「可继续手动输入」，绝不阻断手输路径；
/// 音频零落盘由 TranscriptionEngine 类型级保证（FR17.7），本视图只接触文本。
///
/// 并发纪律（评审修正，CI 编译红自查）：引擎的 `onPartial` 是 **@Sendable 非隔离**回调，
/// 若在其中捕获视图 `@State`（非 Sendable 的 State wrapper）会在 Swift 6 严格并发下
/// 编译失败——录音/部分文本/失败态下沉到 `VoiceDictationModel`（@MainActor @Observable，
/// 即 Sendable），回调只捕获 model 并按 MainActor 投递。
struct VoiceDictationButton: View {
    @Environment(AppState.self) private var app
    /// 完成回调：文本 + 引擎置信度（落 C 级草稿、低置信强制复核由 FR17.13 模板承担）
    let onTranscript: (String, Double) -> Void

    @State private var model: VoiceDictationModel?

    var body: some View {
        Group {
            if let model {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.start()
                    } label: {
                        Label(model.phase == .recording ? L10n.voicenoteDictating : L10n.voicenoteDictation,
                              systemImage: model.phase == .recording ? "waveform" : "mic")
                            .frame(maxWidth: .infinity, minHeight: 44)   // 触控目标 ≥44pt（ui-ux §4.2）
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase == .recording)
                    .accessibilityIdentifier("voice.dictation.start")
                    if model.phase == .recording && !model.partial.isEmpty {
                        Text(model.partial)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .accessibilityIdentifier("voice.dictation.partial")
                    }
                    if model.phase == .failed {
                        Text(L10n.voicenoteDictationFailed)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                    }
                }
                .onDisappear { model.stop() }   // 视图销毁即终止在途听写投递（引擎无内部取消）
            }
        }
        .task { ensureModel() }   // 引擎在环境就绪后装配一次（@Environment 不可用于 @State 初始值）
    }

    /// 引擎在环境就绪后装配一次（@Environment 不可用于 @State 初始值）。
    private func ensureModel() {
        guard model == nil else { return }
        let m = VoiceDictationModel(engine: app.transcriptionEngine)
        m.onTranscript = onTranscript
        model = m
    }
}

/// 单次听写的状态机（@MainActor @Observable = Sendable）：可被 @Sendable 回调安全捕获。
@MainActor
@Observable
final class VoiceDictationModel {
    enum Phase: Equatable { case idle, recording, failed }
    private(set) var phase: Phase = .idle
    private(set) var partial = ""
    var onTranscript: ((String, Double) -> Void)?

    private let engine: any TranscriptionEngine
    private var task: Task<Void, Never>?
    private var stopped = false

    init(engine: any TranscriptionEngine) { self.engine = engine }

    func start() {
        // 重入守卫：.disabled 只是渲染态，快速双击的第二次点击在重渲染前仍会进来
        guard phase != .recording else { return }
        phase = .recording
        partial = ""
        stopped = false
        PartialGate.shared.reset()   // 每次会话独立节流状态（跨会话文本不互相吞）
        task = Task { await dictate() }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    private func dictate() async {
        let engine = self.engine
        // FR17.15：方言不可用时引擎内回落（SFSpeechTranscriber 已映射）；
        // 这里只补「无可用 locale 探测结果」的末级兜底——单一口径 TranscriptionSegmentation.fallbackLocale。
        let locale = engine.capability.availableLocales.first ?? TranscriptionSegmentation.fallbackLocale
        do {
            let result = try await engine.transcribe(
                TranscriptionRequest(localeIdentifier: locale),
                onPartial: { [weak self] text in
                    // @Sendable 非隔离回调：只捕获 model（MainActor 类 = Sendable），
                    // 经 PartialGate 去重后按 MainActor 投递。
                    PartialGate.shared.pass(text) { latest in
                        Task { @MainActor in self?.applyPartial(latest) }
                    }
                })
            guard !stopped else { return }   // 视图已消失：不投递、不改状态
            if !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
                phase = .idle
                onTranscript?(result.text, result.confidence)
            } else {
                phase = .failed   // FR8.9：识别失败静默降级为手输并给输入框轻提示
            }
        } catch is CancellationError {
            return   // 视图级取消：非失败
        } catch {
            guard !stopped else { return }
            phase = .failed
        }
    }

    private func applyPartial(_ text: String) {
        guard phase == .recording else { return }   // 视图已不在录音态则不投递
        partial = text
    }
}

/// 部分结果节流门：SFSpeechRecognizer 每秒数次回调，文本未变即跳过——
/// 避免高频 Task 分配与重复渲染；文本变化立即放行（不引入丢尾部风险）。
/// 每次会话 start 时 reset，跨会话/跨屏不串扰。
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
