import SwiftUI
import Perception
import Domain

/// SP-65 聊天内语音输入（2026-10-18）：复用既有 `VoiceDictationButton`
/// 转写栈（权限/引擎/连续会话/急救前置全部沿用），只把最终文本交回输入框。
/// 不在本页做意图判定或确认——文本回到聊天后仍走同一条 B1 流程。
struct AssistantVoiceInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onUse: (String, URL?) -> Void
    /// 急救时由聊天壳负责关闭自身并进 SOS（本 sheet 只负责先收起）。
    let onEmergency: () -> Void

    init(onUse: @escaping (String, URL?) -> Void, onEmergency: @escaping () -> Void) {
        self.onUse = onUse
        self.onEmergency = onEmergency
    }

    /// 兼容旧调用（无语音消息音频）：只回传文本。
    init(onUse: @escaping (String) -> Void, onEmergency: @escaping () -> Void) {
        self.init(onUse: { text, _ in onUse(text) }, onEmergency: onEmergency)
    }

    @State private var draft = ""
    @State private var dictationBusy = false
    /// 聊天语音消息录音（2026-10-19）：每次按压新文件，最近一次 URL 随「使用」回传。
    @State private var lastAudioURL: URL?
    @State private var temporaryAudioURLs: [URL] = []

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.assistantVoiceHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.25)))
                        .accessibilityIdentifier("assistant.voiceInput")
                    HStack(spacing: 16) {
                        VoiceDictationButton(
                            onTranscript: { text, _ in
                                draft = draft.isEmpty ? text : draft + " " + text
                            },
                            onEmergencyAction: { _ in
                                // 急救前置：先收起本 sheet，再由聊天壳关闭自身并进 SOS。
                                dismiss()
                                onEmergency()
                            },
                            isBusy: $dictationBusy,
                            recordingURLProvider: {
                let url = ChatAudioStore.makeTemporaryURL()
                if let url { temporaryAudioURLs.append(url) }
                return url
            },
                            lastRecordingURL: $lastAudioURL)
                        .accessibilityIdentifier("assistant.voiceDictation")
                        Spacer()
                    }
                }
                .padding(16)
                .navigationTitle(L10n.assistantVoiceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.assistantVoiceUse) {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            onUse(text, lastAudioURL)
                            dismiss()
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("assistant.voiceUse")
                    }
                }
            }
            .onDisappear {
                // 未采用的临时录音全部清理；已采用的文件 chat 已移走。
                for url in temporaryAudioURLs { ChatAudioStore.removeTemporary(url) }
                temporaryAudioURLs.removeAll()
            }
        }
    }
}