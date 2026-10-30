import SwiftUI
import Domain
import Infrastructure
import Perception

/// 语音消息详情（2026-10-30 业主；mock v4 `chat-input-workbuddy.html` 第 7 帧）。
///
/// 结构对齐 mock：上=播放器卡（进度条、已播/总时长、±15 秒、倍速、播放键），
/// 下=双 tab「转写 / 摘要」。
/// - 转写：本机 ASR 原文；不完整转写显式标注（与气泡同一文案）。
/// - 摘要：**确定性摘录**，只取转写前两句，不生成任何新事实（BR-006：
///   不得做诊断/因果/分诊/剂量结论；页脚明示仅摘录原文）。
/// 播放仍走应用级 `VoicePlaybackCoordinator` 单出口——本页不开第二个播放器。
struct ChatVoiceDetailView: View {
    let messageID: UUID
    let audioFilename: String?
    let transcript: String?
    let incomplete: Bool

    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case transcript, summary
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcript: return L10n.chatVoiceTabTranscript
            case .summary: return L10n.chatVoiceTabSummary
            }
        }
    }

    @State private var tab: Tab = .transcript

    private var player: VoicePlaybackCoordinator { app.voicePlayback }

    private var audioURL: URL? {
        guard let audioFilename,
              let url = ChatAudioStore.fileURL(audioFilename),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var isCurrent: Bool { player.playingID == messageID }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        playerCard
                        tabPicker
                        tabContent
                        Text(L10n.chatVoiceSummaryNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
                .navigationTitle(L10n.chatVoiceDetailTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.assistantClose) { dismiss() }
                    }
                }
                .privacySensitive(scenePhase != .active)
                // 离开详情不停播：播放器是应用级单出口，气泡仍显示暂停键。
                // 但页面消失时刷一次进度，避免回来看到旧 ticker 末值。
                .onDisappear { player.refreshProgress() }
            }
        }
    }

    // MARK: - 播放器卡

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .accessibilityHidden(true)
                Text(L10n.assistantVoiceMessage)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if incomplete {
                    Text(L10n.voiceDictationIncomplete)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
            }
            progressBar
            HStack(spacing: 8) {
                Text(Self.timeText(isCurrent ? player.elapsed : 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(Self.timeText(isCurrent ? player.duration : 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            controls
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            let total = isCurrent ? max(player.duration, 0.01) : 1
            let fraction = isCurrent ? min(max(player.elapsed / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color("brand-primary", bundle: .main))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                player.seek(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!isCurrent || audioURL == nil)
            .accessibilityLabel(L10n.chatVoiceBack15)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isCurrent && player.isAudible
                    ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .frame(minWidth: 56, minHeight: 56)
            }
            .disabled(audioURL == nil)
            .accessibilityLabel(isCurrent && player.isAudible ? L10n.chatVoicePause : L10n.chatVoicePlay)
            .accessibilityIdentifier("chat.voice.play")

            Button {
                player.seek(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!isCurrent || audioURL == nil)
            .accessibilityLabel(L10n.chatVoiceForward15)

            Spacer(minLength: 0)

            Button {
                player.cycleRate()
            } label: {
                Text(Self.rateText(player.rate))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel(L10n.chatVoiceRate)
            .accessibilityValue(Self.rateText(player.rate))
            .accessibilityIdentifier("chat.voice.rate")
        }
    }

    // MARK: - Tab

    private var tabPicker: some View {
        Picker(L10n.chatVoiceDetailTitle, selection: $tab) {
            ForEach(Tab.allCases) { candidate in
                Text(candidate.label).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .accessibilityIdentifier("chat.voice.tabs")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .transcript:
            transcriptContent
        case .summary:
            summaryContent
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if audioURL == nil {
            // 音频文件缺失不阻断转写阅读：转写是已落库事实，仍完整展示。
            Text(L10n.chatVoiceUnavailable)
                .font(.caption)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let text = normalizedTranscript {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("chat.voice.transcript")
        } else {
            emptyNote(L10n.chatVoiceTranscriptEmpty)
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = extractiveSummary {
            Text(summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("chat.voice.summary")
        } else {
            emptyNote(L10n.chatVoiceSummaryEmpty)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 动作

    private func togglePlayback() {
        if isCurrent {
            player.togglePause()
            return
        }
        guard let url = audioURL else { return }
        // 与 TTS 双向互斥（与气泡同一纪律）。
        app.stopSpeaking()
        if !player.play(url: url, id: messageID) {
            // 播放失败提示走父页面气泡上下文；详情页内保持静默失败态
            //（按钮仍可重试），不伪造成功。
            return
        }
    }

    // MARK: - 摘录

    private var normalizedTranscript: String? {
        let trimmed = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 确定性摘录：前两句（以 。！？!? 或换行切分），总长 ≤ 80 字。
    /// 只摘录，不生成——不新增任何事实（BR-006）。
    private var extractiveSummary: String? {
        guard let text = normalizedTranscript else { return nil }
        let normalized = text.replacingOccurrences(of: "\n", with: "。")
        var sentences: [String] = []
        var buffer = ""
        for character in normalized {
            buffer.append(character)
            if "。！？!?".contains(character) {
                let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                buffer = ""
                if sentences.count == 2 { break }
            }
        }
        // 末句可能没有句末标点：补进摘录，不能只取到标点前的半句。
        if sentences.count < 2 {
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { sentences.append(tail) }
        }
        guard !sentences.isEmpty else { return nil }
        let joined = sentences.joined()
        return String(joined.prefix(80))
    }

    // MARK: - 格式化

    static func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func rateText(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))X" : String(format: "%.1fX", rate)
    }
}
