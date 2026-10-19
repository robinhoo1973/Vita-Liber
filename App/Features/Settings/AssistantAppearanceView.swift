import SwiftUI
import Domain
import Perception

/// 助手外观（2026-10-19 设计稿 09）：仅预设图标，禁止真人照片——
/// AI 身份必须与真人/医生明确区分。选择即时生效，仅本机保存。
struct AssistantAppearanceView: View {
    @Environment(AvatarState.self) private var avatar

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    VStack(spacing: 8) {
                        AssistantAvatarView(size: 112)
                        Text(L10n.assistantName)
                            .font(.headline)
                        Text(L10n.settings_assistantHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AvatarState.assistantPresets, id: \.self) { symbol in
                            button(symbol)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(L10n.settings_assistantPick)
                } footer: {
                    Text(L10n.settings_assistantFooter)
                }

                Section {
                    Button(L10n.settings_assistantReset) {
                        Task { await avatar.setAssistantSymbol(AvatarState.defaultAssistantSymbol) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("SP-25.assistant.reset")
                }
            }
            .navigationTitle(L10n.settings_assistantAppearance)
            .navigationBarTitleDisplayMode(.inline)
            .task { await avatar.load() }
        }
    }

    private func button(_ symbol: String) -> some View {
        Button {
            Task { await avatar.setAssistantSymbol(symbol) }
        } label: {
            label(symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityIdentifier("SP-25.assistant.symbol.\(symbol)")
    }

    private func label(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Circle().fill(fill(symbol)))
            .clipShape(Circle())
            .foregroundStyle(Color("semantic-warning", bundle: .main))
    }

    private func fill(_ symbol: String) -> Color {
        avatar.assistantSymbol == symbol
            ? Color("semantic-warning", bundle: .main).opacity(0.20)
            : Color.secondary.opacity(0.10)
    }
}
