import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Domain
import Perception

/// 设置 → 头像（2026-10-19 业主指令）：预设图标（无版权风险）+ 本地照片/文件上传。
/// 全部本机处理，零网络；自选照片 `.completeFileProtection` 存储。
struct AvatarSettingsView: View {
    @Environment(AvatarState.self) private var avatar
    @Environment(\.dismiss) private var dismiss

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var failed = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    HStack(spacing: 16) {
                        AvatarView(size: 72)
                            .accessibilityLabel(L10n.settings_avatarPreview)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.settings_avatarTitle)
                                .font(.headline)
                            Text(L10n.settings_avatarHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.settings_avatarReset) {
                            Task { await avatar.reset() }
                        }
                        .accessibilityIdentifier("SP-25.avatar.reset")
                    }
                    .frame(minHeight: 88)
                }

                Section(L10n.settings_avatarPresets) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AvatarState.presets, id: \.self) { symbol in
                            presetButton(symbol)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(L10n.settings_avatarLocal) {
                    Button {
                        showPhotos = true
                    } label: {
                        Label(L10n.settings_avatarPhoto, systemImage: "photo.on.rectangle")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("SP-25.avatar.photo")
                    Button {
                        showFiles = true
                    } label: {
                        Label(L10n.settings_avatarFile, systemImage: "folder")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("SP-25.avatar.file")
                } footer: {
                    Text(L10n.settings_avatarLocalFooter)
                }

                if failed {
                    Section {
                        Text(L10n.settings_avatarFailed)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                            .accessibilityIdentifier("SP-25.avatar.failed")
                    }
                }
            }
            .navigationTitle(L10n.settings_avatarTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { await avatar.load() }
            .photosPicker(isPresented: $showPhotos, selection: $pickedPhoto, matching: .images)
            .onChangeCompat(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            failed = true
                            return
                        }
                        try await avatar.setPhoto(data)
                        failed = false
                    } catch {
                        failed = true
                    }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    Task {
                        do {
                            let data = try Data(contentsOf: url)
                            try await avatar.setPhoto(data)
                            failed = false
                        } catch {
                            failed = true
                        }
                    }
                case .failure:
                    break
                }
            }
        }
    }

    /// 预设头像按钮（类型检查预算：cell 表达式拆出，CI 06:55 type-check timeout 修复）。
    private func presetButton(_ symbol: String) -> some View {
        Button {
            Task { await avatar.setSymbol(symbol) }
        } label: {
            presetLabel(symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityIdentifier("SP-25.avatar.symbol.\(symbol)")
    }

    private func presetLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Circle().fill(presetFill(symbol)))
            .clipShape(Circle())
            .foregroundStyle(Color("brand-primary", bundle: .main))
    }

    private func presetFill(_ symbol: String) -> Color {
        selected(symbol)
            ? Color("brand-primary", bundle: .main).opacity(0.20)
            : Color.secondary.opacity(0.10)
    }

    private func selected(_ symbol: String) -> Bool {
        avatar.image == nil && avatar.symbol == symbol
    }
}
