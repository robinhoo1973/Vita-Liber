import SwiftUI
import AVFoundation
import Domain

/// 语音访谈前置音量自检（TestFlight 实测修复：语音完善个人信息无音量检测、
/// 无语音输出指导）。
///
/// 业界标准做法（Apple HIG 语音交互 / 医疗语音助手类 app）：
/// - 进入录音流程前先做 mic check——朗读一句测试句，实时显示音量条；
/// - 音量持续过低给出靠近麦克风的提示，允许重试；无障碍用户可跳过（保留手输）；
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
    @State private var tooLow = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44))
                .foregroundStyle(tooLow ? Color("semantic-warning", bundle: .main)
                                       : Color("brand-primary", bundle: .main))
            Text(L10n.voiceguide_micTitle).font(.title3.bold())
            Text(L10n.voiceguide_micPrompt)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // 测试句卡片（自动朗读一次）
            Text(meter.testPhrase)
                .font(.headline)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
                .onAppear { app.speak(meter.testPhrase) }

            // 实时音量条（RMS 归一化；达标段绿、不足段警示色）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule()
                        .fill(tooLow ? Color("semantic-warning", bundle: .main)
                                     : Color("semantic-success", bundle: .main))
                        .frame(width: max(8, geo.size.width * CGFloat(min(level * 4, 1.0))))
                }
                .frame(height: 10)
            }
            .frame(maxWidth: 280, minHeight: 10)

            if tooLow {
                Label(L10n.voiceguide_micTooLow, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityIdentifier("voice.mic.tooLow")
            }

            HStack(spacing: 16) {
                Button(L10n.voiceguide_micSkip) { stopAndSkip() }
                    .frame(minHeight: 44)
                Button(L10n.voiceguide_micPass) { stopAndPass() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("voice.mic.pass")
            }
            .padding(.horizontal, 24)
            Spacer()
        }
        .padding(.top, 32)
        .onAppear {
            meter.onLevel = { rms in
                level = rms
                tooLow = rms < VoiceLevelMeter.lowThreshold
            }
            meter.start()
        }
        .onDisappear { meter.stop() }
    }

    private func stopAndPass() { meter.stop(); onPass() }
    private func stopAndSkip() { meter.stop(); onSkip() }
}

/// 麦克风实时电平（AVAudioEngine tap，RMS 归一化 0..1）。
/// 阈值取经验值：正常说话 RMS 通常 >0.03；低于该值判定「音量过低」。
@MainActor
@Observable
final class VoiceLevelMeter {
    /// 判定「音量过低」的 RMS 阈值（实测经验值：耳语 ~0.01，正常 ~0.05-0.3）
    static let lowThreshold: Float = 0.03

    var testPhrase: String { L10n.voiceguide_micPhrase }
    var onLevel: (@MainActor (Float) -> Void)?

    private let engine = AVAudioEngine()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])   // try?-ok: 会话配置失败即无电平，不阻断跳过/手输路径（§7 降级语义）
        try? session.setActive(true)   // try?-ok: 激活失败同上——音量条静默无数据，访谈仍可继续
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = channel[i]; sum += s * s }
            let rms = sqrt(sum / Float(max(n, 1)))
            let clamped = min(max(rms, 0), 1)
            // tap 回调在音频线程；电平投递到主线程后按 MainActor 断言消费
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onLevel?(clamped) }
            }
        }
        try? engine.start()   // try?-ok: 引擎启动失败即无电平，不阻断跳过/手输路径（§7 降级语义）
    }

    func stop() {
        guard started else { return }
        started = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)   // try?-ok: 归还会话失败仅影响他 App 恢复，本页生命周期已结束
    }
}
