import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Domain
import Perception

/// 设置 → 头像（2026-10-19 业主指令，设计稿 06/08）。
/// 顶部居中预览（预设/自选共用）→ 预设网格 → 上传入口（来源选择在裁剪页）。
struct AvatarSettingsView: View {
    @Environment(AvatarState.self) private var avatar

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    VStack(spacing: 8) {
                        AvatarView(size: 112)
                            .accessibilityLabel(L10n.settings_avatarPreview)
                        Text(avatar.image == nil
                             ? L10n.settings_avatarPresetHint
                             : L10n.settings_avatarCustomHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    NavigationLink {
                        AvatarCropView()
                    } label: {
                        Label(L10n.settings_avatarUpload, systemImage: "camera")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("SP-25.avatar.upload")
                }

                Section {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AvatarState.presets, id: \.self) { symbol in
                            presetButton(symbol)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(L10n.settings_avatarPresets)
                } footer: {
                    Text(L10n.settings_avatarLocalFooter)
                }
            }
            .navigationTitle(L10n.settings_avatarTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { await avatar.load() }
        }
    }

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
        avatar.image == nil && avatar.symbol == symbol
            ? Color("brand-primary", bundle: .main).opacity(0.20)
            : Color.secondary.opacity(0.10)
    }
}

/// 裁剪与调整（设计稿 08）：来源选择（拍照/相册/文件）在本页；
/// 圆形裁剪、缩放、拖拽，保存 512×512 JPEG（本机、受保护）。
struct AvatarCropView: View {
    @Environment(AvatarState.self) private var avatar
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var failed = false

    private let canvas: CGFloat = 280

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 16) {
                if let image {
                    cropSection(image)
                } else {
                    sourceSection
                }
                if failed {
                    Text(L10n.settings_avatarFailed)
                        .font(.caption)
                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(L10n.settings_avatarCropTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.settings_avatarDone) { save() }
                        .disabled(image == nil)
                        .accessibilityIdentifier("SP-25.avatar.crop.done")
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { picked in
                    showCamera = false
                    apply(picked)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $pickedPhoto, matching: .images)
            .onChangeCompat(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),   // try?-ok: 读取失败统一提示
                          let picked = UIImage(data: data) else {
                        failed = true
                        return
                    }
                    apply(picked)
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), let picked = UIImage(data: data) else {   // try?-ok: 读取失败统一提示
                    failed = true
                    return
                }
                apply(picked)
            }
        }
    }

    private var sourceSection: some View {
        VStack(spacing: 12) {
            Text(L10n.settings_avatarChooseSource)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            sourceButton(L10n.settings_avatarCamera, systemImage: "camera") { showCamera = true }
            sourceButton(L10n.settings_avatarPhoto, systemImage: "photo.on.rectangle") { showPhotos = true }
            sourceButton(L10n.settings_avatarFile, systemImage: "folder") { showFiles = true }
        }
    }

    private func sourceButton(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func cropSection(_ image: UIImage) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: canvas, height: canvas)
                    .scaleEffect(zoom)
                    .offset(x: offset.width + dragOffset.width,
                            y: offset.height + dragOffset.height)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .gesture(
                        DragGesture()
                            .onChanged { value in dragOffset = value.translation }
                            .onEnded { value in
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                                dragOffset = .zero
                            })
            }
            .frame(width: canvas, height: canvas)
            .background(Circle().fill(Color.black.opacity(0.85)))
            .clipShape(Circle())

            HStack(spacing: 10) {
                Text(L10n.settings_avatarZoom).font(.caption).foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...3)
            }

            HStack(spacing: 16) {
                preview(image, size: 44)
                preview(image, size: 28)
                Spacer()
                Button(L10n.settings_avatarReselect) {
                    self.image = nil
                    zoom = 1
                    offset = .zero
                }
                .font(.caption)
                .frame(minHeight: 44)
            }
            Text(L10n.settings_avatarCropHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func preview(_ image: UIImage, size: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(zoom)
            .offset(x: offset.width * size / canvas, y: offset.height * size / canvas)
            .clipShape(Circle())
    }

    private func apply(_ picked: UIImage) {
        image = picked
        zoom = 1
        offset = .zero
        failed = false
    }

    private func save() {
        guard let image, let data = render(image) else {
            failed = true
            return
        }
        Task {
            do {
                try await avatar.setPhoto(data)
                dismiss()
            } catch {
                failed = true
            }
        }
    }

    /// 将当前缩放/位移映射到 512×512 圆形输出。
    private func render(_ image: UIImage) -> Data? {
        let output: CGFloat = 512
        let ratio = output / canvas
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format)
        return renderer.jpegData(withCompressionQuality: 0.9) { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: output, height: output)).addClip()
            let base = max(output / image.size.width, output / image.size.height)
            let scale = base * zoom
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (output - drawSize.width) / 2 + (offset.width + dragOffset.width) * ratio,
                y: (output - drawSize.height) / 2 + (offset.height + dragOffset.height) * ratio)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
