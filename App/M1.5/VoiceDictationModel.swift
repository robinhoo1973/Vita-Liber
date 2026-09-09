import SwiftUI
import Domain
import Protocols

/// FR8.9 / FR17.1 端上听写状态机（原 VoiceDictationButton.swift）：
/// SFSpeechRecognizer（`requiresOnDeviceRecognition=true`，offline-first）
/// 听写 → 实时部分文本 → 完成回调（调用方走 FR17.13 统一确认模板）。
///
/// 2026-09-09 死代码清除：`VoiceDictationButton` 视图随 §4.23 中部大号
/// 按住说话按钮（PressToTalkMicButton）落地而零实例化——视图结构删除，
/// 本文件只保留模型与节流门（新组件依赖）。BR-012 前置在模型内统一执行
/// （命中即跳过草稿投递并调用 onEmergency）。
///
/// 并发纪律（评审修正）：引擎的 `onPartial` 是 **@Sendable 非隔离**回调，
/// 若在其中捕获视图 `@State`（非 Sendable）会在 Swift 6 严格并发下编译
/// 失败——录音/部分文本/失败态下沉到本模型（@MainActor @Observable，
/// 即 Sendable），回调只捕获 model 并按 MainActor 投递。

/// 单次听写的状态机（@MainActor @Observable = Sendable）：可被 @Sendable 回调安全捕获。
@MainActor
@Observable
final class VoiceDictationModel {
    enum Phase: Equatable { case idle, recording, failed }
    private(set) var phase: Phase = .idle
    private(set) var partial = ""
    var onTranscript: ((String, Double) -> Void)?
    /// BR-012 紧急关键词横切动作（命中即调用并跳过 onTranscript 草稿投递）
    var onEmergency: ((String) -> Void)?

    private let engine: any TranscriptionEngine
    // 视图在每次渲染时按最新设置更新（FR14.7 即时生效），故 setter 为 internal——
    // 与 phase/partial 的 private(set) 不同（第九轮 M1.5 审查：stale 闭包修复）
    var preferredLocale: String?
    private var task: Task<Void, Never>?
    private var stopped = false
    /// 会话代次：start 递增。收尾期（stop 后引擎仍在等静音端点）旧会话的
    /// 结果/部分文本按代次丢弃，防「快速重录时旧引擎文本污染新会话」。
    private var session = 0
    /// 每会话独立的节流门（审查修复：此前为全局单例，两个同时在途的听写
    /// 会话共享 lastText——A 先吐出的文本会把 B 的相同部分结果压掉，
    /// 「每次会话独立节流状态」的语义落空；reset 也会互相踩）。
    private let partialGate = PartialGate()

    init(engine: any TranscriptionEngine, preferredLocale: String? = nil) {
        self.engine = engine
        self.preferredLocale = preferredLocale
    }

    func start() {
        // 重入守卫：.disabled 只是渲染态，快速双击的第二次点击在重渲染前仍会进来
        guard phase != .recording else { return }
        session += 1
        phase = .recording
        partial = ""
        stopped = false
        partialGate.reset()   // 每次会话独立节流状态（跨会话文本不互相吞）
        task = Task { [session] in await dictate(session: session) }
    }

    /// 用户收尾（松手/点按停止，FR17.1）：立即回 idle 可重录，但不取消
    /// 引擎——SFSpeechRecognizer 在静音端点后给出 isFinal 最终文本，在途
    /// 转写必须投递（二轮审查：此前 stop 即取消，`guard !stopped` 把松手后
    /// 的全文静默丢弃，速记/指标/提醒草稿从不落编辑区）。引擎侧无外部取消
    /// （已登记待办），收尾由会话代次守卫界定归属。
    func stop() {
        guard phase == .recording else { return }
        phase = .idle
        // 软停提示：旧引擎尽快 endAudio 收尾（不取消——在途转写保留投递，
        // 由会话代次守卫界定归属）；避免旧会话与新录音竞争共享音频会话
        Task { await self.engine.endAudio() }
    }

    /// 视图销毁硬停：取消在途会话、不再投递（引擎仍由 isFinal 自然收尾，
    /// 到达后按 stopped 守卫丢弃——与既有取消路径行为一致）。
    func stopForDisappear() {
        stopped = true
        task?.cancel()
        // 终止会话即回 idle——phase 滞留 .recording 时 start() 被重入守卫
        // 拦下，听写死掉直到视图身份重建（TabView 切走再切回场景）。
        phase = .idle
    }

    private func dictate(session: Int) async {
        let engine = self.engine
        // FR17.15：方言不可用时引擎内回落（SFSpeechTranscriber 已映射）；
        // 这里只补「无可用 locale 探测结果」的末级兜底——单一口径 TranscriptionSegmentation.fallbackLocale。
        let locale = preferredLocale
            ?? engine.capability.availableLocales.first
            ?? TranscriptionSegmentation.fallbackLocale
        let gate = partialGate
        do {
            let result = try await engine.transcribe(
                TranscriptionRequest(localeIdentifier: locale),
                onPartial: { [weak self] text in
                    // @Sendable 非隔离回调：只捕获 model（MainActor 类 = Sendable）
                    // 与会话门（局部拷贝，非隔离可安全捕获），去重后按 MainActor 投递。
                    gate.pass(text) { latest in
                        Task { @MainActor in self?.applyPartial(latest, session: session) }
                    }
                })
            // 收尾期旧会话结果按代次丢弃：快速重录时（stop 后 ~1s 内再
            // start）前会话引擎的最终文本不得投递为新会话内容
            guard !stopped, self.session == session else { return }   // 硬停/换代：不投递、不改状态
            if !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
                phase = .idle
                // BR-012 紧急关键词前置（V3.40 横切义务）：判定在本组件内统一
                // 执行——此前仅快速面板与 F19 键盘路径实现，其余 6 处入口
                // 听写文本直入确认草稿，「我胸闷」被存成观察/速记而非急救卡
                // （红线一票否决）。命中即跳急救卡配置页并跳过草稿投递。
                if EmergencyKeywordRules.match(result.text), let onEmergency {
                    onEmergency(result.text)
                    return
                }
                onTranscript?(result.text, result.confidence)
            } else {
                phase = .failed   // FR8.9：识别失败静默降级为手输并给输入框轻提示
            }
        } catch is CancellationError {
            return   // 硬停/视图级取消：非失败
        } catch {
            guard !stopped, self.session == session else { return }
            phase = .failed
        }
    }

    private func applyPartial(_ text: String, session: Int) {
        guard phase == .recording, self.session == session else { return }   // 视图不在录音态或会话已换代则不投递
        partial = text
    }
}

/// 部分结果节流门：SFSpeechRecognizer 每秒数次回调，文本未变即跳过——
/// 避免高频 Task 分配与重复渲染；文本变化立即放行（不引入丢尾部风险）。
/// 每次会话 start 时 reset；实例归单个 VoiceDictationModel 所有，
/// 跨会话/跨屏不串扰（并发会话不共享节流状态）。
private final class PartialGate: @unchecked Sendable {
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
