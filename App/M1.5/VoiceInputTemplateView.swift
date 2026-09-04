import SwiftUI
import AVFoundation
import os
import Domain
import Protocols

/// **FR17.13 标准语音输入模板（唯一实现）**
///
/// 语音指导每步（FR17.11）/ 语音速记（FR17.9）/ 语音提醒设定（FR17.10）/
/// 观察语音速记（FR8.9）四处确认**一律**复用本文件的 `VoiceConfirmSheet`，
/// 禁止各功能自建独立确认逻辑。L0 门禁 [9/9] 对此做静态断言：
/// 四处入口须各有 `// FR17.13-entry:` 标记且调用 `VoiceInputTemplate.confirmationSet`；
/// 同时 `OcrConfirmationSet` 只允许在 Domain 内构造，App 层无法自行拼装确认集。
///
/// 决策半场在 Domain（`ReadbackPolicy`）——本文件只负责把决策渲染成界面，
/// 不含任何业务判断（tech-spec §1.1 规则 4）。

// MARK: - 音频路由监听（耳机感知）

/// FR17.13：探测输出路由，并在录入过程中拔/插耳机时**即时**切换回读策略。
@MainActor
@Observable
final class AudioRouteMonitor {
    private(set) var route: AudioRoute = .speaker
    /// 路由变化时的轻提示文案（Toast），消费后置 nil
    var routeChangeToast: String?

    private let logger = Logger(subsystem: "com.vitaliber", category: "audioroute")
    private var observer: NSObjectProtocol?

    init() { refresh() }

    func start() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let old = self.route
                    self.refresh()
                    if old != self.route {
                        self.routeChangeToast = self.route == .headphones
                            ? L10n.voiceRouteHeadphonesOn
                            : L10n.voiceRouteHeadphonesOff
                    }
                }
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
        ]
        route = outputs.contains { headphonePorts.contains($0.portType) } ? .headphones : .speaker
    }
}

// MARK: - 统一确认卡（四处入口共用）

/// 语音草稿确认卡。**唯一**的语音确认 UI。
struct VoiceConfirmSheet: View {
    let set: OcrConfirmationSet
    let decision: ReadbackDecision
    /// 点 [🔊 朗读] 或自动回读时调用（TTS 由调用方注入，便于测试替身）
    var onSpeak: ((String) -> Void)?
    var onConfirm: (OcrConfirmationSet) -> Void
    var onRetry: () -> Void
    var onCancel: () -> Void

    @State private var askAnswered = false
    @State private var didAutoSpeak = false

    /// 回读脚本 = 已确认字段（BR-003：未确认内容不得被当作事实播报）。
    /// 确认卡呈现时字段尚未确认，故按「即将保存的取值」构造预览脚本：
    /// 走 Domain 的同一函数，先在本地副本上确认再取脚本，保证与保存后播报一致。
    private var script: String? {
        var preview = set
        for i in preview.fields.indices { _ = preview.fields[i].confirm() }
        return ReadbackPolicy.readbackScript(preview)
    }

    private var showsAsk: Bool {
        if case .askFirst = decision { return !askAnswered }
        return false
    }

    private var bystanderWarning: Bool {
        if case .readAloud(let warn) = decision { return warn }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                VLIcon.waveform.resizable().frame(width: 22, height: 22)
                Text(L10n.voiceConfirmTitle).font(.headline)
                Spacer()
            }

            // 字段列表：一律「待确认」态呈现（BR-003 未确认不入正式区）
            ForEach(set.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.displayLabel).font(.caption).foregroundStyle(.secondary)
                    Text(field.value).font(.body)
                    HStack(spacing: 6) {
                        Text(L10n.voiceConfirmPending)
                            .font(.caption2)
                            .foregroundStyle(Color("grade-d", bundle: .main))
                        if ConfidenceTier.tier(field.confidence) == .low {
                            Label(L10n.voiceConfirmLowConfidence, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(Color("grade-d", bundle: .main))
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color("bg-grouped", bundle: .main)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color("grade-d", bundle: .main),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("FR17.13.confirm.field")
            }

            if bystanderWarning {
                Label(L10n.voiceBystanderWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("FR17.13.bystanderWarning")
            }

            if showsAsk {
                // 三态偏好 .ask：先问一次再决定回读与否
                HStack(spacing: 12) {
                    Button {
                        askAnswered = true
                        if let script { onSpeak?(script) }
                    } label: {
                        Label(L10n.voiceAskSpeak, systemImage: "speaker.wave.2")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("FR17.13.ask.speak")
                    Button {
                        askAnswered = true
                    } label: {
                        Label(L10n.voiceAskScreen, systemImage: "speaker.slash")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("FR17.13.ask.screen")
                }
            } else if case .screenConfirm(let offerSpeak) = decision, offerSpeak {
                // 无耳机回读出口（无障碍出口，不受偏好关闭——FR17.13/F18）
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if let script { onSpeak?(script) }
                    } label: {
                        Label(L10n.voiceSpeakAloud, systemImage: "speaker.wave.2").frame(minHeight: 44)
                    }
                    .accessibilityLabel("朗读当前草稿")
                    .accessibilityIdentifier("FR17.13.speakButton")
                    Text(L10n.voiceScreenCheckHint)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(L10n.voiceConfirmCancel, action: onCancel)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.13.cancel")
                Button(L10n.voiceConfirmRetry, action: onRetry)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.13.retry")
                Spacer()
                Button(L10n.voiceConfirmSave) {
                    var confirmed = set
                    for i in confirmed.fields.indices { _ = confirmed.fields[i].confirm() }
                    onConfirm(confirmed)
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("FR17.13.confirm")
            }
        }
        .padding(20)
        .accessibilityIdentifier("FR17.13.sheet")
        .onAppear {
            // 有耳机（或关怀模式 always）→ 自动完整回读一次
            guard !didAutoSpeak, case .readAloud = decision, let script else { return }
            didAutoSpeak = true
            onSpeak?(script)
        }
    }
}

// MARK: - FR17.12 语音指导隐私与耳机提示

/// 进入语音指导模式前的一次性须知卡；确认后写入 ConsentRecord（F20.5 判定重展）。
struct VoicePrivacyHeadphoneCard: View {
    var onAccept: () -> Void
    var onUseTouch: () -> Void

    private var points: [String] {
        [L10n.voicePrivacyPoint1, L10n.voicePrivacyPoint2,
         L10n.voicePrivacyPoint3, L10n.voicePrivacyPoint4]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                VLIcon.headphone.resizable().frame(width: 28, height: 28)
                Text(L10n.voicePrivacyTitle).font(.headline)
            }
            ForEach(points, id: \.self) { p in
                HStack(alignment: .top, spacing: 8) {
                    VLIcon.checkCircle.resizable().frame(width: 16, height: 16)
                    Text(p).font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                Button(L10n.voicePrivacyUseTouch, action: onUseTouch)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.12.useTouch")
                Spacer()
                Button(L10n.voicePrivacyAccept, action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.12.accept")
            }
        }
        .padding(20)
        .accessibilityIdentifier("FR17.12.card")
    }
}

// MARK: - 语音受限修改拒绝卡（BR-003/006）

/// 剂量 / 频次 / 停用 —— 语音一律拒绝，改指触屏路径。
struct VoiceModificationRejectionCard: View {
    let rejection: VoiceModificationGuard.Rejection
    var onGoToPlan: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VLIcon.ban.resizable().frame(width: 24, height: 24)
                Text(rejection.title).font(.headline)
            }
            Text(rejection.body).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("知道了", action: onDismiss)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.11.reject.dismiss")
                Spacer()
                Button(rejection.actionLabel, action: onGoToPlan)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("FR17.11.reject.goToPlan")
            }
        }
        .padding(20)
        .accessibilityIdentifier("FR17.11.rejectionCard")
    }
}
