import SwiftUI
import Domain
import Infrastructure

/// FR17.15 生产设置：选择直接写入voiceEngine，下一次按压从同一键解析。
struct ASREngineSettingsSection: View {
    @Environment(AppSettingsStore.self) private var settings
    var accessibilityPrefix = "SP-25"

    var body: some View {
        Section {
            ForEach(VoiceEngineChoice.allCases, id: \.self) { choice in
                let availability = TranscriptionEngineBuilder.availability(of: choice)
                Button {
                    Task { await settings.set(choice.rawValue, for: .voiceEngine) }
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.voiceEngineName(choice))
                            Text(L10n.voiceEngineHint(choice)).font(.caption).foregroundStyle(.secondary)
                            if let model = ASRModelCatalog.model(for: choice) {
                                Text(model.license + " · " + L10n.asrBundledOffline)
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let bytes = ASRModelAssets().byteCount(choice) {
                                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if let note = L10n.asrAvailability(availability) {
                                Text(note).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if VoiceEngineChoice.resolve(settings.values[.voiceEngine]) == choice {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color("brand-primary", bundle: .main))
                        }
                    }.frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix).engine.\(choice.rawValue)")
            }
        } header: { Text(L10n.voiceLabEngineSection) }
          footer: { Text(L10n.asrSelectionHint) }
    }
}
