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
    /// 语音识别授权请求本身也是异步的：返回键退出时若用户仍停在系统
    /// 授权弹窗，旧实现返回后会继续开麦（视图已消失、teardown 已跑过）。
    @State private var permissionTask: Task<Void, Never>?
    /// 通过/跳过按钮已收尾——onDisappear 不得再停播（否则会掐掉访谈首问的 TTS）
    @State private var finished = false
    /// 自检录音试听（FR17.11）：录到的片段只用于本页回放，离开即删（FR17.7）。
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackFailed = false
    @State private var playbackDelegate = MicCheckPlaybackDelegate()
    @State private var playbackSession: AudioSessionCapture.State?
    /// 语音识别 TCC 与麦克风 TCC 是两件事：自检通过但识别未授权，首步听写仍失败。
    @State private var speechDenied = false
    /// TTS 测试句播完、开始录用户声音后才置 true（试听片段不得含 App 朗读）。
    @State private var listening = false

    /// 关怀模式触控目标（常规 44 / 关怀 64，CLAUDE.md UI 纪律）。
    private var touchTarget: CGFloat {
        (app.careMode ? CareModeMetrics.care : .standard).touchTarget
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    if !meter.inputDeviceName.isEmpty { deviceChip }
                    levelRing
                    phraseCard
                    statusArea
                    if meter.hasRecording { replayRow }
                    actions
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
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

    // MARK: - 自检版面

    private var hero: some View {
        VStack(spacing: 10) {
            Text(L10n.voiceguide_micTitle)
                .font(.title2.bold())
            Text(L10n.voiceguide_micPrompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var deviceChip: some View {
        Label(L10n.voiceguideMicInputDevice(meter.inputDeviceName), systemImage: "mic")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color("bg-grouped", bundle: .main), in: Capsule())
            .accessibilityIdentifier("voice.mic.inputDevice")
    }

    private var levelRing: some View {
        ZStack {
            Circle()
                .stroke(Color("bg-grouped", bundle: .main), lineWidth: 8)
                .frame(width: 128, height: 128)
            Circle()
                .trim(from: 0, to: max(0.02, min(CGFloat(level * 4), 1)))
                .stroke(levelRingColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 128, height: 128)
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color("brand-primary", bundle: .main).opacity(0.08))
                .frame(width: 96, height: 96)
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(levelRingColor)
        }
        .accessibilityHidden(true)
    }

    private var levelRingColor: Color {
        tooLow ? Color("semantic-warning", bundle: .main)
               : Color("brand-primary", bundle: .main)
    }

    private var phraseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.voiceguide_micTestPhrase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "quote.opening")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(meter.testPhrase)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(listening ? L10n.voiceguide_micListening : L10n.voiceguide_micListenFirst)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .glassCard(cornerRadius: VLCornerRadius.compact)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let failure = meter.failure {
            statusBanner(failureMessage(failure), symbol: "exclamationmark.triangle",
                         identifier: "voice.mic.failure")
            if failure == .unauthorized { settingsButton(identifier: "voice.mic.openSettings") }
        } else if speechDenied {
            statusBanner(L10n.voiceguide_speechUnavailable, symbol: "exclamationmark.triangle",
                         identifier: "voice.mic.speechDenied")
            settingsButton(identifier: "voice.mic.speechSettings")
        } else if tooLow {
            statusBanner(L10n.voiceguide_micTooLow, symbol: "arrow.down.circle",
                         identifier: "voice.mic.tooLow")
        }
        if meter.failure != nil || tooLow || speechDenied
            || (!meter.isRunning && meter.hasRecording) {
            Button(L10n.voiceguide_micRetry) { restart() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: touchTarget)
                .accessibilityIdentifier("voice.mic.retry")
        }
    }

    private func statusBanner(_ text: String, symbol: String, identifier: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(Color("semantic-warning", bundle: .main))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color("semantic-warning", bundle: .main).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
            .accessibilityIdentifier(identifier)
    }

    private func settingsButton(identifier: String) -> some View {
        Button(L10n.helpPermOpenSettings) { SystemLinks.openSettings() }
            .frame(maxWidth: .infinity, minHeight: touchTarget)
            .accessibilityIdentifier(identifier)
    }

    private var replayRow: some View {
        VStack(spacing: 6) {
            Button {
                if isPlaying { stopPlayback() } else { playRecording() }
            } label: {
                Label(isPlaying ? L10n.voiceguide_micPlaying : L10n.voiceguide_micPlay,
                      systemImage: isPlaying ? "stop.circle" : "play.circle")
                    .frame(maxWidth: .infinity, minHeight: touchTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("voice.mic.play")
            if playbackFailed {
                Text(L10n.voiceguide_micPlaybackFailed)
                    .font(.caption)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("voice.mic.playbackFailed")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(L10n.voiceguide_micPass) { finishAndPass() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: touchTarget)
                .accessibilityIdentifier("voice.mic.pass")
            Button(L10n.voiceguide_micSkip) { finishAndSkip() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: touchTarget)
        }
    }

    private func begin() {
        level = 0
        tooLow = false
        playbackFailed = false
        listening = false
        lastAdequateAt = Date()
        finished = false
        meter.discardRecording()
        meter.onLevel = { rms in
            // TTS 测试句播放期间不呈现电平，也不计入达标——试听/通过必须来自用户声音。
            guard !app.isSpeaking else {
                if level != 0 { level = 0 }
                return
            }
            if abs(rms - level) >= 0.01 { level = rms }
            // 0.25s 节流：达标时刻只需支撑「持续过低」判定，逐 buffer
            // 写 @State 会让整个自检页每秒重算数十次（Efficiency 审查）。
            if rms >= meter.lowThreshold,
               Date().timeIntervalSince(lastAdequateAt) >= 0.25 {
                lastAdequateAt = Date()
            }
        }
        permissionTask?.cancel()
        permissionTask = Task { @MainActor in
            let allowed = await Self.ensureSpeechPermission()
            guard !Task.isCancelled else { return }
            guard allowed else {
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
        permissionTask?.cancel()
        permissionTask = nil
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
            p.delegate = playbackDelegate
            playbackDelegate.onFinish = { finishPlayback() }
            p.prepareToPlay()
            player = p
            playbackSession = prior
            isPlaying = true
            playbackFailed = false
            p.play()
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
            // 先播测试句，播完才开录：录音片段只含用户声音，试听不会重放 TTS。
            app.speak(meter.testPhrase)
            let deadline = Date().addingTimeInterval(8)
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }   // 等合成器真正进入 speaking
            while app.isSpeaking, Date() < deadline {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard !Task.isCancelled, meter.isRunning else { return }
            meter.beginRecording()
            lastAdequateAt = Date()
            listening = true
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
                if meter.isRunning, listening {
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

    /// 采集引擎/会话/观察者统一委托 Infrastructure 控制器（2026-10-21）：
    /// 自检只是多一个 `.playAndRecord` 会话模式，不再复制一份 AVAudioEngine
    /// 生命周期。试听片段写入与电平计算走同一个 buffer（无二次 tap）。
    private let capture = AudioCaptureController()
    private let sink = LevelCaptureSink()
    private let relay = LevelRelay()
    private var started = false
    private var starting = false
    /// 启动代次：停止/重启会让旧启动任务（可能仍挂在权限弹窗上）作废，
    /// 不得在用户已重试后把旧引擎装回来或把 `starting` 清掉（Angle A #3）。
    private var startGeneration = 0
    private var recorder: AudioFileRecorder?
    private var inputFormat: AVAudioFormat?
    private var routeObserver: NSObjectProtocol?
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
        refreshInputDevice()
        observeRouteChanges()
        relay.meter = self
        sink.setLevelHandler { [relay] level in relay.deliver(level) }
        var configuration = AudioCaptureController.Configuration.standard
        configuration.sessionMode = .micCheck
        do {
            try capture.start(
                configuration: configuration,
                onFormat: { [weak self] format in self?.inputFormat = format },
                onBuffer: { [sink] buffer, _ in sink.consume(buffer) },
                onFailure: { [relay] in relay.deliverFailure() },
                isStopped: { false })
        } catch {
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

    /// TTS 测试句结束后开始写试听片段；创建失败只失去回放能力。
    func beginRecording() {
        guard started, recorder == nil, let format = inputFormat else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-mic-check-\(UUID().uuidString).caf")
        guard let recorder = AudioFileRecorder(
            url: url, format: format, emitsLevel: false,
            maxFrames: AVAudioFramePosition(format.sampleRate * Self.maxRecordingSeconds)) else {
            return
        }
        self.recorder = recorder
        sink.setRecorder(recorder)
        recordingURL = url
    }

    func stop() {
        guard started || starting || inputFormat != nil || recorder != nil else { return }
        startGeneration &+= 1   // 作废仍在权限弹窗/启动中的旧任务
        starting = false
        started = false
        capture.stop()          // 引擎/tap/会话快照还原的单一出口
        sink.setRecorder(nil)
        // 停写但不删文件：试听需要保留到 finishCheck/离开页面。
        recorder?.finish()
        recorder = nil
        inputFormat = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        onLevel?(0)
    }

    /// 删除试听片段（通过/跳过/重试/返回的唯一清理出口；幂等）。
    func discardRecording() {
        recorder?.finish()
        recorder = nil
        sink.setRecorder(nil)
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
    }

    /// 采集被系统夺走：停止并给出可见失败（重试按钮由 failure 驱动）。
    func handleCaptureLost() {
        guard started || inputFormat != nil else { return }
        failure = .sessionFailed
        stop()
    }

    /// 采集 sink 已 hop 回主线程；这里只把电平交给视图，不再碰音频线程。
    func acceptLevel(_ value: Float) {
        onLevel?(value)
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

/// 采集缓冲 → 试听文件 + 归一化电平原语（音频线程）。
/// 录音器与 handler 都可能被主线程替换，统一加锁；电平节流在音频线程完成，
/// 主线程只收到 |Δ|≥0.01 的变化。
private final class LevelCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: AudioFileRecorder?
    private var handler: (@Sendable (Float) -> Void)?
    private var lastSent: Float = -1

    func setRecorder(_ recorder: AudioFileRecorder?) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) {
        lock.lock()
        self.handler = handler
        lastSent = -1
        lock.unlock()
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let recorder = self.recorder
        let handler = self.handler
        lock.unlock()
        recorder?.write(buffer)
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { let sample = channel[index]; sum += sample * sample }
        let rms = min(max(sqrt(sum / Float(count)), 0), 1)
        lock.lock()
        let changed = abs(rms - lastSent) >= 0.01
        if changed { lastSent = rms }
        lock.unlock()
        if changed { handler?(rms) }
    }
}

/// 音频线程 → 主线程的单跳转（不持有 meter；视图销毁即自动断开）。
private final class LevelRelay: @unchecked Sendable {
    weak var meter: VoiceLevelMeter?

    func deliver(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.meter?.acceptLevel(level) }
        }
    }

    func deliverFailure() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.meter?.handleCaptureLost() }
        }
    }
}

/// 试听结束回调（AVAudioPlayer.delegate 是 weak，由视图侧强持有）。
private final class MicCheckPlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor () -> Void)?
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
    nonisolated func audioPlayerDecodeErrorDidFinish(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}


