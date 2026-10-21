import SwiftUI
import AVFoundation
import Domain
import Infrastructure
import Perception

/// 语音访谈前置音量自检（FR17.11 · SP-58 步骤 0.5）。
///
/// 业界标准做法（Apple HIG 语音交互 / 医疗语音助手类 app）：
/// - 进入录音流程前先做 mic check——朗读一句测试句，实时显示音量条；
/// - 音量**持续**过低给出靠近麦克风的提示，可重新检测；无障碍用户可跳过（保留手输）；
/// - 测试句自动 TTS 朗读，指导用户「该说什么」。
///
/// 生命周期纪律：本视图只在访谈开始前运行，通过/跳过后立即 stop 引擎并移除
/// tap——与后续 SFSpeechRecognizer 的 audio session 不冲突（听写引擎自管类别）。
struct VoiceLevelCheck: View {
    let onPass: () -> Void
    let onSkip: () -> Void

    @Environment(AppState.self) private var app
    @State private var meter = VoiceLevelMeter()
    @State private var level: Float = 0
    /// 最近一次达标电平的时刻——「持续过低」判定的唯一依据。
    /// 旧实现按单帧 RMS 与阈值比较：level 初值 0 使警告从进场即常亮，停顿/换气
    /// 也反复触发（业主实测「音量自检老是提示音量偏低」），与规格「持续过低」不符。
    @State private var lastAdequateAt = Date()
    @State private var tooLow = false
    @State private var startTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    /// 通过/跳过按钮已收尾——onDisappear 不得再停播（否则会掐掉访谈首问的 TTS）
    @State private var finished = false

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 20) {
                Image(systemName: "waveform.and.mic")
                    .font(VLFont.levelDisplay)
                    .foregroundStyle(tooLow ? Color("semantic-warning", bundle: .main)
                                           : Color("brand-primary", bundle: .main))
                Text(L10n.voiceguide_micTitle).font(.title3.bold())
                Text(L10n.voiceguide_micPrompt)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // 测试句卡片（采集就绪后自动朗读一次——见 startMeter）
                Text(meter.testPhrase)
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .glassCard(cornerRadius: VLCornerRadius.compact)   // §3.3 表面阶梯 L2（V4.05：常态无阴影）

                // 实时音量条（RMS 归一化；达标段绿、不足段警示色）
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color("bg-grouped", bundle: .main))
                        Capsule()
                            .fill(tooLow ? Color("semantic-warning", bundle: .main)
                                         : Color("semantic-success", bundle: .main))
                            .frame(width: max(8, geo.size.width * CGFloat(min(level * 4, 1.0))))
                    }
                    .frame(height: 10)
                }
                .frame(maxWidth: 280, minHeight: 10)

                // 失败与低音量必须分型（FR17.6）：权限拒绝/会话失败绝不能说成
                // 「音量偏低」——用户会照着提示反复靠近麦克风，却永远无法通过。
                if let failure = meter.failure {
                    Label(failureMessage(failure), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("voice.mic.failure")
                } else if tooLow {
                    Label(L10n.voiceguide_micTooLow, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("voice.mic.tooLow")
                }

                // 规格步骤 0.5 的 [重新检测]：失败（先授权/换路由后重试）与
                // 持续过低都给出同一重试出口，不必退回上一页。
                if meter.failure != nil || tooLow {
                    Button(L10n.voiceguide_micRetry) { restart() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("voice.mic.retry")
                }

                HStack(spacing: 16) {
                    Button(L10n.voiceguide_micSkip) { finishAndSkip() }
                        .frame(minHeight: 44)
                    Button(L10n.voiceguide_micPass) { finishAndPass() }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("voice.mic.pass")
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 32)
            .onAppear { begin() }
            .onDisappear {
                // 按钮路径已在 finishCheck 收尾（finished=true），此处不得再停播：
                // 新分支（访谈首问）的 onAppear 可能先于本视图 onDisappear 执行，
                // 无条件 stopSpeaking 会把首问朗读掐掉。返回键退出时才停。
                if !finished { app.stopSpeaking() }
                teardown()
            }
        }
    }

    private func begin() {
        level = 0
        tooLow = false
        lastAdequateAt = Date()
        meter.onLevel = { rms in
            level = rms
            if rms >= VoiceLevelMeter.lowThreshold { lastAdequateAt = Date() }
        }
        startMeter()
        startLowPoll()
    }

    private func restart() {
        finishCheck()
        begin()
    }

    private func finishAndPass() { finished = true; finishCheck(); onPass() }
    private func finishAndSkip() { finished = true; finishCheck(); onSkip() }

    /// 自检拆除单一出口（幂等）：取消异步启动/轮询 → 停引擎并还原会话。
    private func teardown() {
        startTask?.cancel()
        startTask = nil
        pollTask?.cancel()
        pollTask = nil
        meter.stop()
    }

    /// 按钮收尾：拆除采集并停掉测试句朗读。
    private func finishCheck() {
        teardown()
        app.stopSpeaking()
    }

    /// 采集就绪后再朗读测试句。旧实现把 `app.speak` 挂在测试句卡片的 onAppear 上，
    /// 与 `.record` 会话激活同帧竞争：类别无输出路由时测试句被系统静音，用户不知道
    /// 该说什么，自检自然恒低（讨论 F-A7-10）。
    private func startMeter() {
        startTask?.cancel()
        startTask = Task { @MainActor in
            await meter.start()
            guard !Task.isCancelled, meter.isRunning else { return }
            app.speak(meter.testPhrase)
        }
    }

    /// 持续过低判定：进场先给 2.4 s 宽限（听测试句 + 反应），此后距上一次达标
    /// 超过 2.5 s 才提示——瞬时跌落在停顿/换气时必然出现，不得据此报警。
    private func startLowPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_400_000_000) } catch { return }
            while !Task.isCancelled {
                if meter.failure != nil {
                    tooLow = false
                    return
                }
                tooLow = Date().timeIntervalSince(lastAdequateAt) >= 2.5
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            }
        }
    }

    private func failureMessage(_ failure: VoiceLevelMeter.MeterFailure) -> String {
        switch failure {
        case .unauthorized: return L10n.voicenoteDictationDenied
        case .sessionFailed: return L10n.voiceguide_micUnavailable
        }
    }
}

/// 麦克风实时电平（AVAudioEngine tap，RMS 归一化 0..1）。
/// 阈值取经验值：正常说话 RMS 通常 >0.03；低于该值判定「音量过低」。
@MainActor
@Perceptible
final class VoiceLevelMeter {
    /// 采集失败分型（FR17.6）：权限拒绝与会话/引擎失败是两回事，
    /// 旧实现一律吞成「无电平」，界面只能误报「音量偏低」。
    enum MeterFailure: Equatable {
        case unauthorized
        case sessionFailed
    }

    /// 判定「音量过低」的 RMS 阈值（实测经验值：耳语 ~0.01，正常 ~0.05-0.3）
    static let lowThreshold: Float = 0.03

    var testPhrase: String { L10n.voiceguide_micPhrase }
    var onLevel: (@MainActor (Float) -> Void)?
    private(set) var failure: MeterFailure?
    var isRunning: Bool { started }

    private let engine = AVAudioEngine()
    private var started = false
    private var starting = false
    private var tapInstalled = false
    /// 采集前的会话状态快照（拆除时对称还原；采集激活单一出口 AudioSessionCapture）
    private var sessionState: AudioSessionCapture.State?

    /// 启动自检采集（async：首次先请求麦克风权限，用户未答复前不启引擎）。
    /// 结束后以 `failure` 区分未授权/会话失败；成功则 `isRunning == true`。
    func start() async {
        guard !started, !starting else { return }
        starting = true
        failure = nil
        defer { starting = false }
        // 权限前置（FR17.6 / ui-ux §5.54「麦克风拒绝→手输兜底提示」）：
        // 旧实现直接 start 引擎，首次使用的系统权限弹窗由引擎隐式触发，
        // start 失败被 `try?` 吞掉且 started 已置位——授权后也永不重启，
        // 电平恒 0 → 永远「音量偏低」；用户若在此拒绝，后续听写同样被拒。
        guard await Self.ensureMicPermission() else {
            failure = .unauthorized
            onLevel?(0)
            return
        }
        guard !Task.isCancelled else { return }
        // 自检需要同时朗读（输出）与采集（输入）：专用 playAndRecord 会话
        // （`.record` 类别会让测试句静音，见 activateMicCheckSession）。
        let prior = AudioSessionCapture.remember()
        do { try AudioSessionCapture.activateMicCheckSession() }
        catch {
            AudioSessionCapture.restore(prior)
            failure = .sessionFailed
            return
        }
        sessionState = prior
        let input = engine.inputNode
        // 与 AudioCaptureController 同源：输入节点取 outputFormat，且装 tap 前
        // 校验格式——非法格式会让 installTap 抛 Objective-C 异常（Linux 型检
        // 看不见），旧实现的 inputFormat + 无校验在会话失败时正落此路径。
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            failure = .sessionFailed
            return
        }
        // 投递节流：48kHz/1024 ≈ 47 buffer/秒，每个 buffer 都 hop 主线程并
        // 触发视图重算过密——|Δ|<0.01 的微小抖动跳过，归零必达（结束即清零）
        var lastSent: Float = -1
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = channel[i]; sum += s * s }
            let rms = sqrt(sum / Float(max(n, 1)))
            let clamped = min(max(rms, 0), 1)
            guard abs(clamped - lastSent) >= 0.01 || clamped == 0 else { return }
            lastSent = clamped
            // tap 回调在音频线程；电平投递到主线程后按 MainActor 断言消费
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onLevel?(clamped) }
            }
        }
        tapInstalled = true
        do { try engine.start() }
        catch {
            stop()
            failure = .sessionFailed
            return
        }
        started = true
    }

    func stop() {
        guard started || starting || tapInstalled || sessionState != nil else { return }
        started = false
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // 采集拆除单一出口：对称还原采集前状态——只停用不还原会让共享会话
        // 停在 .playAndRecord，其后访谈提问的 TTS 朗读路由漂移。
        if let prior = sessionState {
            AudioSessionCapture.restore(prior)
            sessionState = nil
        }
        onLevel?(0)
    }

    /// 麦克风权限前置（iOS 16 走 AVAudioSession，17+ 走 AVAudioApplication）。
    /// 只读取系统 TCC 状态；拒绝时不重复请求（系统不会再弹）。
    private static func ensureMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            case .undetermined: break
            @unknown default: return false
            }
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted: return true
            case .denied: return false
            case .undetermined: break
            @unknown default: return false
            }
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
