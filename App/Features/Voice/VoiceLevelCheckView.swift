import SwiftUI
import AVFoundation
import Speech
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
    @Environment(AppSettingsStore.self) private var settings
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
    /// 自检录音试听（FR17.11）：录到的片段只用于本页回放，离开即删（FR17.7）。
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackFailed = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackSession: AudioSessionCapture.State?
    /// 语音识别 TCC 与麦克风 TCC 是两件事：自检通过但识别未授权，首步听写仍失败。
    @State private var speechDenied = false

    /// 关怀模式触控目标（常规 44 / 关怀 64，CLAUDE.md UI 纪律）。
    private var touchTarget: CGFloat {
        (app.careMode ? CareModeMetrics.care : .standard).touchTarget
    }

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

                // FR17.11 业主实测：自检必须告诉用户当前用的是哪个输入设备——
                // 蓝牙耳机/外接麦克风接错时，「靠近麦克风」的提示会让人对着
                // 手机白喊。路由变化（插拔耳机/蓝牙切换）即时刷新。
                if !meter.inputDeviceName.isEmpty {
                    Label(L10n.voiceguideMicInputDevice(meter.inputDeviceName), systemImage: "mic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice.mic.inputDevice")
                }

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

                // 业主实测：只显示音量条不够——必须能重播刚录到的声音，
                // 让用户自己判断音量和清晰度。试听即停采集（playback 会话），
                // 播完/停止/离开页面均还原会话并删除临时文件。
                if meter.hasRecording {
                    Button {
                        if isPlaying { stopPlayback() } else { playRecording() }
                    } label: {
                        Label(isPlaying ? L10n.voiceguide_micPlaying : L10n.voiceguide_micPlay,
                              systemImage: isPlaying ? "stop.circle" : "play.circle")
                            .frame(minHeight: touchTarget)
                    }
                    .accessibilityIdentifier("voice.mic.play")
                    if playbackFailed {
                        Label(L10n.voiceguide_micPlaybackFailed, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                            .accessibilityIdentifier("voice.mic.playbackFailed")
                    }
                }

                // 失败与低音量必须分型（FR17.6）：权限拒绝/会话失败绝不能说成
                // 「音量偏低」——用户会照着提示反复靠近麦克风，却永远无法通过。
                if let failure = meter.failure {
                    Label(failureMessage(failure), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("voice.mic.failure")
                    // 权限被拒后「重新检测」只会再次读到 .denied——必须给系统设置出口，
                    // 否则 FR17.6 的手输兜底之外是一条死路。
                    if failure == .unauthorized {
                        Button(L10n.helpPermOpenSettings) { SystemLinks.openSettings() }
                            .frame(minHeight: touchTarget)
                            .accessibilityIdentifier("voice.mic.openSettings")
                    }
                } else if speechDenied {
                    VStack(spacing: 6) {
                        Label(L10n.voiceguide_speechUnavailable, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("voice.mic.speechDenied")
                        Button(L10n.helpPermOpenSettings) { SystemLinks.openSettings() }
                            .frame(minHeight: touchTarget)
                            .accessibilityIdentifier("voice.mic.speechSettings")
                    }
                } else if tooLow {
                    Label(L10n.voiceguide_micTooLow, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("voice.mic.tooLow")
                }

                // 规格步骤 0.5 的 [重新检测]：失败（先授权/换路由后重试）与
                // 持续过低都给出同一重试出口，不必退回上一页。
                if meter.failure != nil || tooLow || speechDenied || (!meter.isRunning && meter.hasRecording) {
                    Button(L10n.voiceguide_micRetry) { restart() }
                        .frame(minHeight: touchTarget)
                        .accessibilityIdentifier("voice.mic.retry")
                }

                HStack(spacing: 16) {
                    Button(L10n.voiceguide_micSkip) { finishAndSkip() }
                        .frame(minHeight: touchTarget)
                    Button(L10n.voiceguide_micPass) { finishAndPass() }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: touchTarget)
                        .accessibilityIdentifier("voice.mic.pass")
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 32)
            .onAppear {
                // 隐私设置已关闭语音输入：不得再弹 TCC、开麦或写临时录音——
                // 直接按「跳过自检」进入键盘可用的访谈（与 VoiceDictationButton 同语义）。
                if settings.values[.authVoiceDictation] == "false" {
                    finished = true
                    onSkip()
                } else {
                    begin()
                }
            }
            .onDisappear {
                // 按钮路径已在 finishCheck 收尾（finished=true），此处不得再停播：
                // 新分支（访谈首问）的 onAppear 可能先于本视图 onDisappear 执行，
                // 无条件 stopSpeaking 会把首问朗读掐掉。返回键退出时才停。
                if !finished { app.stopSpeaking() }
                teardown()
                // 音频即用即弃（FR17.7/17.12）：返回键退出也必须删掉试听片段。
                if !finished { meter.discardRecording() }
            }
        }
    }

    private func begin() {
        level = 0
        tooLow = false
        playbackFailed = false
        lastAdequateAt = Date()
        meter.discardRecording()
        meter.onLevel = { rms in
            if abs(rms - level) >= 0.01 { level = rms }
            // 0.25s 节流：达标时刻只需支撑「持续过低」判定，逐 buffer
            // 写 @State 会让整个自检页每秒重算数十次（Efficiency 审查）。
            if rms >= meter.lowThreshold,
               Date().timeIntervalSince(lastAdequateAt) >= 0.25 {
                lastAdequateAt = Date()
            }
        }
        Task { @MainActor in
            guard await Self.ensureSpeechPermission() else {
                speechDenied = true
                return
            }
            speechDenied = false
            startMeter()
            startLowPoll()
        }
    }

    private func restart() {
        finishCheck()
        begin()
    }

    private static func ensureSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    private func finishAndPass() { finished = true; finishCheck(); onPass() }
    private func finishAndSkip() { finished = true; finishCheck(); onSkip() }

    /// 自检拆除单一出口（幂等）：停止试听并还原其会话 → 取消异步启动/轮询
    /// → 停引擎并还原采集会话。录音文件保留到 finishCheck 删除。
    private func teardown() {
        stopPlayback()
        startTask?.cancel()
        startTask = nil
        pollTask?.cancel()
        pollTask = nil
        meter.stop()
    }

    /// 按钮收尾：拆除采集、删除试听片段并停掉测试句朗读。
    private func finishCheck() {
        // 先停 TTS 再还原会话：AVSpeechSynthesizer 默认共用应用音频会话，
        // 在朗读中 setActive(false) 会触发「运行中 I/O 被停用」并吞错。
        app.stopSpeaking()
        teardown()
        meter.discardRecording()
    }

    /// 试听刚录到的片段：必须先停采集，否则播放声音会被同一 tap 再次录入，
    /// 且 playAndRecord 会话下输出路由可能落在听筒。
    private func playRecording() {
        guard let url = meter.recordingURL else { return }
        teardown()
        app.stopSpeaking()
        let prior = AudioSessionCapture.remember()
        do {
            try AudioSessionCapture.activatePlaybackSession()
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            playbackSession = prior
            isPlaying = true
            playbackFailed = false
            p.play()
            playbackTask?.cancel()
            playbackTask = Task { @MainActor in
                while !Task.isCancelled, let p = player, p.isPlaying {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
                guard !Task.isCancelled else { return }
                finishPlayback()
            }
        } catch {
            AudioSessionCapture.restore(prior)
            player = nil
            playbackSession = nil
            isPlaying = false
            playbackFailed = true
        }
    }

    private func stopPlayback() { finishPlayback() }

    private func finishPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        if let prior = playbackSession {
            AudioSessionCapture.restore(prior)
            playbackSession = nil
        }
    }

    /// 采集就绪后再朗读测试句。旧实现把 `app.speak` 挂在测试句卡片的 onAppear 上，
    /// 与 `.record` 会话激活同帧竞争：类别无输出路由时测试句被系统静音，用户不知道
    /// 该说什么，自检自然恒低（讨论 F-A7-10）。
    private func startMeter() {
        startTask?.cancel()
        startTask = Task { @MainActor in
            await meter.start()
            guard !Task.isCancelled, meter.isRunning else { return }
            // 宽限从「采集真正就绪」起算：权限弹窗/引擎启动耗时不得计入。
            lastAdequateAt = Date()
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
                // 采集未就绪（权限弹窗/启动中）不得判定——旧实现从 onAppear
                // 起算宽限，弹窗停留 3s 就必然先报「音量偏低」（Angle A #1）。
                if meter.isRunning {
                    let low = Date().timeIntervalSince(lastAdequateAt) >= 2.5
                    if low != tooLow { tooLow = low }
                } else if tooLow {
                    tooLow = false
                }
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

    /// 判定「音量过低」的 RMS 基准阈值（内置麦实测经验：耳语 ~0.01，正常 ~0.05-0.3）。
    /// 蓝牙 HFP/外接麦增益低，按路由下调，避免用户被指向错误的「靠近麦克风」。
    static let lowThreshold: Float = 0.03

    var lowThreshold: Float {
        switch AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType {
        case .bluetoothHFP, .bluetoothLE: return 0.012
        case .headsetMic, .usbAudio: return 0.02
        default: return Self.lowThreshold
        }
    }

    var testPhrase: String { L10n.voiceguide_micPhrase }
    var onLevel: (@MainActor (Float) -> Void)?
    private(set) var failure: MeterFailure?
    var isRunning: Bool { started }

    /// 当前输入路由的人类可读名称（内置/耳机/蓝牙/外接），供自检页明示。
    private(set) var inputDeviceName = ""
    /// 本次自检录到的临时片段（仅用于试听；离开页面即删）。
    private(set) var recordingURL: URL?
    var hasRecording: Bool { recordingURL != nil }

    private let engine = AVAudioEngine()
    private var started = false
    private var starting = false
    /// 启动代次：停止/重启会让旧启动任务（可能仍挂在权限弹窗上）作废，
    /// 不得在用户已重试后把旧引擎装回来或把 `starting` 清掉（Angle A #3）。
    private var startGeneration = 0
    private var tapInstalled = false
    /// 采集前的会话状态快照（拆除时对称还原；采集激活单一出口 AudioSessionCapture）
    private var sessionState: AudioSessionCapture.State?
    private var recorder: MicCheckRecorder?
    private var routeObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// 自检试听片段上限（20s）——上限内足够读完测试句，避免页面停留时无限增长。
    private static let maxRecordingSeconds: Double = 20

    /// 启动自检采集（async：首次先请求麦克风权限，用户未答复前不启引擎）。
    /// 结束后以 `failure` 区分未授权/会话失败；成功则 `isRunning == true`。
    func start() async {
        guard !started, !starting else { return }
        starting = true
        startGeneration &+= 1
        let generation = startGeneration
        failure = nil
        defer {
            // 旧代次不得清掉新代次的「启动中」标志（重试与权限弹窗重叠）。
            if startGeneration == generation { starting = false }
        }
        // 权限前置（FR17.6 / ui-ux §5.54「麦克风拒绝→手输兜底提示」）：
        // 旧实现直接 start 引擎，首次使用的系统权限弹窗由引擎隐式触发，
        // start 失败被 `try?` 吞掉且 started 已置位——授权后也永不重启，
        // 电平恒 0 → 永远「音量偏低」；用户若在此拒绝，后续听写同样被拒。
        guard await Self.ensureMicPermission() else {
            guard startGeneration == generation else { return }
            failure = .unauthorized
            onLevel?(0)
            return
        }
        guard !Task.isCancelled, startGeneration == generation else { return }
        // 自检需要同时朗读（输出）与采集（输入）：专用 playAndRecord 会话
        // （`.record` 类别会让测试句静音，见 activateMicCheckSession）。
        let prior = AudioSessionCapture.remember()
        do { try AudioSessionCapture.activateMicCheckSession() }
        catch {
            AudioSessionCapture.restore(prior)
            if startGeneration == generation { failure = .sessionFailed }
            return
        }
        guard startGeneration == generation else {
            AudioSessionCapture.restore(prior)
            return
        }
        sessionState = prior
        refreshInputDevice()
        observeRouteChanges()
        let input = engine.inputNode
        // 与 AudioCaptureController 同源：输入节点取 outputFormat，且装 tap 前
        // 校验格式——非法格式会让 installTap 抛 Objective-C 异常（Linux 型检
        // 看不见），旧实现的 inputFormat + 无校验在会话失败时正落此路径。
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failure = .sessionFailed
            stop()
            return
        }
        // 试听片段写到临时目录；创建失败不阻断电平自检（只失去回放能力）。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-mic-check-\(UUID().uuidString).caf")
        if let recorder = MicCheckRecorder(url: url, format: format,
                                           maxFrames: AVAudioFramePosition(format.sampleRate * Self.maxRecordingSeconds)) {
            self.recorder = recorder
            recordingURL = url
        }
        let recorder = self.recorder
        // 投递节流：48kHz/1024 ≈ 47 buffer/秒，每个 buffer 都 hop 主线程并
        // 触发视图重算过密——|Δ|<0.01 的微小抖动跳过，归零必达（结束即清零）
        var lastSent: Float = -1
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            recorder?.write(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = channel[i]; sum += s * s }
            let rms = sqrt(sum / Float(max(n, 1)))
            let clamped = min(max(rms, 0), 1)
            // 只报变化（含首次归零；持续静音不再每 buffer 都跳主线程）。
            guard abs(clamped - lastSent) >= 0.01 else { return }
            lastSent = clamped
            // tap 回调在音频线程；电平投递到主线程后按 MainActor 断言消费
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onLevel?(clamped) }
            }
        }
        tapInstalled = true
        // 停止/重试可能在权限弹窗期间发生——旧代次不得再启动引擎。
        guard startGeneration == generation else {
            stop()
            discardRecording()
            return
        }
        do { try engine.start() }
        catch {
            let isCurrent = startGeneration == generation
            stop()
            discardRecording()
            if isCurrent { failure = .sessionFailed }
            return
        }
        guard startGeneration == generation else {
            stop()
            discardRecording()
            return
        }
        started = true
        // 引擎启动后输入路由才最终稳定（外接/蓝牙切换可能发生在激活与启动之间）。
        refreshInputDevice()
    }

    func stop() {
        guard started || starting || tapInstalled || sessionState != nil || recorder != nil else { return }
        startGeneration &+= 1   // 作废仍在权限弹窗/启动中的旧任务
        starting = false
        started = false
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // 停写但不删文件：试听需要保留到 finishCheck/离开页面。
        recorder?.finish()
        recorder = nil
        for observer in [routeObserver, configObserver, interruptionObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        routeObserver = nil
        configObserver = nil
        interruptionObserver = nil
        // 采集拆除单一出口：对称还原采集前状态——只停用不还原会让共享会话
        // 停在 .playAndRecord，其后访谈提问的 TTS 朗读路由漂移。
        if let prior = sessionState {
            AudioSessionCapture.restore(prior)
            sessionState = nil
        }
        onLevel?(0)
    }

    /// 删除试听片段（通过/跳过/重试/返回的唯一清理出口；幂等）。
    func discardRecording() {
        recorder?.finish()
        recorder = nil
        if let url = recordingURL {
            do { try FileManager.default.removeItem(at: url) } catch { /* 已删除/文件系统竞态不阻断 */ }
        }
        recordingURL = nil
    }

    private func refreshInputDevice() {
        let port = AVAudioSession.sharedInstance().currentRoute.inputs.first
        inputDeviceName = port.map(Self.displayName(for:)) ?? ""
    }

    /// 路由变化只刷新设备名；引擎配置变化/中断会让 tap 静默停摆——
    /// 必须转为可见失败并给重试出口，否则界面继续按旧 lastAdequateAt
    /// 报「音量偏低」（Angle A #4）。
    private func observeRouteChanges() {
        let center = NotificationCenter.default
        if routeObserver == nil {
            routeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshInputDevice()
                    // 路由切换后会话可能失去输入（如蓝牙断连的瞬时窗口）。
                    if AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty {
                        self?.handleCaptureLost()
                    }
                }
            }
        }
        if configObserver == nil {
            configObserver = center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleCaptureLost() }
            }
        }
        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor [weak self] in self?.handleCaptureLost() }
            }
        }
    }

    /// 采集被系统夺走：停止并给出可见失败（重试按钮由 failure 驱动）。
    private func handleCaptureLost() {
        guard started || tapInstalled || sessionState != nil else { return }
        failure = .sessionFailed
        stop()
    }

    private static func displayName(for port: AVAudioSessionPortDescription) -> String {
        let name = port.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        switch port.portType {
        case .builtInMic: return L10n.voiceguide_micDeviceBuiltIn
        case .headsetMic: return L10n.voiceguide_micDeviceHeadset
        case .bluetoothHFP: return L10n.voiceguide_micDeviceBluetooth
        case .usbAudio: return L10n.voiceguide_micDeviceUSB
        case .carAudio: return L10n.voiceguide_micDeviceCar
        default: return L10n.voiceguide_micDeviceGeneric
        }
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

/// 自检片段录制器：只写临时 CAF，不接共享 `AudioLevelMonitor`（其单 handler
/// 属于听写模型，复用 `AudioFileRecorder` 会抢占电平订阅）。写盘失败只失去
/// 试听能力，绝不影响音量判定。`@unchecked Sendable` 与 `AudioFileRecorder`
/// 同口径：`AVAudioFile.write` 由单一音频线程调用，UI 侧仅在引擎停止后释放。
private final class MicCheckRecorder: @unchecked Sendable {
    private let file: AVAudioFile
    private let maxFrames: AVAudioFramePosition
    private var writtenFrames: AVAudioFramePosition = 0

    init?(url: URL, format: AVAudioFormat, maxFrames: AVAudioFramePosition) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forWriting: url, settings: format.settings) }
        catch { return nil }
        self.file = file
        self.maxFrames = maxFrames
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard writtenFrames < maxFrames else { return }
        do {
            try file.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // 试听是附加能力：磁盘满/格式不支持时保持电平自检可用。
        }
    }

    /// AVAudioFile 在释放时收尾文件头；工作线程已停止，主线程释放安全。
    func finish() {}
}
