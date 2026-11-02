import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

/// 聊天导入「待提交」页（2026-11-01 业主；mock `chat-import-staging.html` 第 1 帧）。
///
/// 拍摄/相册/文件选中后不立刻回聊天：先进入本页，可继续追加、删除、前移/后移；
/// 提交时才把有序字节交给聊天导入链（合并 → OCR → 气泡）。
/// 只在内存中暂存压缩字节；不写资料库、不产生气泡、不自动导出。
struct ChatImportStagingView: View {
    @ObservedObject var model: ChatImportStagingModel
    let onSubmit: ([ChatImportStagingModel.Item]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var presentation: StagingPresentation?
    @State private var alertText: String?
    @State private var reading = false
    @State private var readGeneration = UUID()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if model.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                    addTiles
                    privacyNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            bottomBar
        }
        .background(Color("bg-grouped", bundle: .main))
        .interactiveDismissDisabled()
        .presentationDetents([.fraction(0.87)])
        .presentationDragIndicator(.visible)
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhotos,
                      maxSelectionCount: 9, matching: .images)
        .onChangeCompat(of: pickedPhotos) { _, items in handlePickedPhotos(items) }
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true,
                      onCompletion: handleFiles)
        .fullScreenCover(item: $presentation) { active in
            switch active {
            case .camera:
                CameraPicker { image in handleCamera(image) }
            case .preview(let id, let image):
                ChatImageImportPreview(images: [image]) { images in
                    if let image = images.first,
                       let data = image.jpegData(compressionQuality: 0.95) {
                        if model.replace(id: id, data: data) == .tooLarge {
                            alertText = L10n.chatImportStagingTooLarge
                        }
                    }
                    presentation = nil
                }
            }
        }
        .alert(L10n.chatImportStagingNoticeTitle,
               isPresented: Binding(get: { alertText != nil },
                                    set: { if !$0 { alertText = nil } })) {
            Button(L10n.onboard_gotIt, role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
        .onAppear { consumeNotice() }
        .onChangeCompat(of: model.notice) { _, _ in consumeNotice() }
        .privacySensitive(scenePhase != .active)
    }

    /// 相机与图片检查共用一次 fullScreenCover 槽（iOS 16 同节点多 presentation 会互相覆盖）。
    private enum StagingPresentation: Identifiable {
        case camera
        case preview(id: UUID, image: UIImage)

        var id: String {
            switch self {
            case .camera: return "camera"
            case .preview(let id, _): return "preview-\(id.uuidString)"
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.chatImportStagingTitle)
                    .font(.title3.weight(.bold))
                Text(L10n.chatImportStagingHint(model.items.count, model.totalPages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            GradeBadge(grade: GradeBadge.gradeMachineUnconfirmed)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(model.items) { item in
                itemCell(item, ordinal: (model.items.firstIndex(where: { $0.id == item.id }) ?? 0) + 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.staging.grid")
    }

    private func itemCell(_ item: ChatImportStagingModel.Item, ordinal: Int) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button {
                    openPreview(item)
                } label: {
                    StagingThumbnail(item: item)
                        .frame(maxWidth: .infinity)
                        .frame(height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.chatImportStagingPreview(item.filename))
                .accessibilityIdentifier("chat.staging.item.\(item.id.uuidString)")

                Button {
                    model.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                .accessibilityLabel(L10n.commonDelete)
                .accessibilityIdentifier("chat.staging.remove.\(item.id.uuidString)")
            }
            .overlay(alignment: .topLeading) {
                Text(item.isPDF ? L10n.chatImportStagingPDFPages(item.pageCount)
                                : L10n.chatImportStagingImageBadge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color("brand-primary", bundle: .main), in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 2) {
                Text(L10n.chatImportStagingPageOrdinal(ordinal))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button(L10n.chatImportStagingMoveEarlier) { model.moveUp(id: item.id) }
                        .disabled(model.items.first?.id == item.id)
                    Button(L10n.chatImportStagingMoveLater) { model.moveDown(id: item.id) }
                        .disabled(model.items.last?.id == item.id)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.chatImportStagingReorder)
                .accessibilityIdentifier("chat.staging.reorder.\(item.id.uuidString)")
            }
            .padding(.horizontal, 5)
            .frame(minHeight: 44)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.chatImportStagingEmpty)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("chat.staging.empty")
    }

    private var addTiles: some View {
        HStack(spacing: 8) {
            if QuickCaptureView.cameraAvailable {
                addTile(L10n.chatImportStagingAddCamera, symbol: "camera.fill") {
                    presentation = .camera
                }
                .accessibilityIdentifier("chat.staging.add.camera")
            }
            addTile(L10n.chatImportStagingAddPhotos, symbol: "photo.on.rectangle") {
                showPhotos = true
            }
            .accessibilityIdentifier("chat.staging.add.photos")
            addTile(L10n.chatImportStagingAddFiles, symbol: "doc.fill") {
                showFiles = true
            }
            .accessibilityIdentifier("chat.staging.add.files")
        }
        .disabled(reading || model.items.count >= ChatImportStagingModel.maxItems)
        .overlay(alignment: .topTrailing) {
            if reading {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .accessibilityLabel(L10n.chatImportStagingReading)
            }
        }
    }

    private func addTile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color("brand-primary", bundle: .main).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color("brand-primary", bundle: .main).opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var privacyNote: some View {
        Text(L10n.chatImportStagingPrivacy)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(L10n.commonCancel) { cancel() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5))
                    .accessibilityIdentifier("chat.staging.cancel")
                Button(L10n.chatImportStagingSubmit(model.items.count)) { submit() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color("brand-primary", bundle: .main)
                        .opacity(model.canSubmit ? 1 : 0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(!model.canSubmit || reading)
                    .accessibilityIdentifier("chat.staging.submit")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.thinMaterial)
    }

    // MARK: - 选择

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedPhotos = []
        let token = beginRead()
        Task { @MainActor in
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          !data.isEmpty else { continue }
                    guard accept(data: data, filename: L10n.assistantAttachPhotos,
                                 isPDF: false, pageCount: 1, source: .photoLibrary,
                                 token: token) else { return }
                } catch {
                    finishRead(token, message: L10n.chatImportStagingReadFailed)
                    return
                }
            }
            finishRead(token)
        }
    }

    private func handleCamera(_ image: UIImage) {
        presentation = nil
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            alertText = L10n.chatImportStagingReadFailed
            return
        }
        let token = beginRead()
        _ = accept(data: data, filename: L10n.assistantAttachCamera,
                   isPDF: false, pageCount: 1, source: .camera, token: token)
        finishRead(token)
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let token = beginRead()
        Task { @MainActor in
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let isPDF = url.pathExtension.lowercased() == "pdf"
                    let pages = isPDF ? (PDFDocument(data: data)?.pageCount ?? 0) : 1
                    guard !isPDF || pages > 0 else {
                        finishRead(token, message: L10n.chatImportStagingReadFailed)
                        return
                    }
                    guard accept(data: data, filename: url.lastPathComponent,
                                 isPDF: isPDF, pageCount: pages, source: .fileImport,
                                 token: token) else { return }
                } catch {
                    finishRead(token, message: L10n.chatImportStagingReadFailed)
                    return
                }
            }
            finishRead(token)
        }
    }

    @discardableResult
    private func accept(data: Data, filename: String, isPDF: Bool, pageCount: Int,
                        source: ChatImportStagingModel.Source, token: UUID) -> Bool {
        guard token == readGeneration else { return false }
        switch model.add(data: data, filename: filename, isPDF: isPDF,
                         pageCount: pageCount, source: source) {
        case .added:
            return true
        case .tooManyItems:
            alertText = L10n.chatImportStagingTooManyItems
        case .tooManyPages:
            alertText = L10n.chatImportStagingTooManyPages
        case .tooLarge:
            alertText = L10n.chatImportStagingTooLarge
        case .empty:
            alertText = L10n.chatImportStagingReadFailed
        }
        return false
    }

    private func beginRead() -> UUID {
        let token = UUID()
        readGeneration = token
        reading = true
        return token
    }

    private func finishRead(_ token: UUID, message: String? = nil) {
        guard token == readGeneration else { return }
        reading = false
        if let message { alertText = message }
    }

    private func consumeNotice() {
        guard let notice = model.notice else { return }
        model.notice = nil
        alertText = notice
    }

    private func openPreview(_ item: ChatImportStagingModel.Item) {
        guard !item.isPDF, let image = UIImage(data: item.data) else { return }
        presentation = .preview(id: item.id, image: image)
    }

    private func submit() {
        guard model.canSubmit, !reading else { return }
        let items = model.items
        model.clear()
        onSubmit(items)
        dismiss()
    }

    private func cancel() {
        readGeneration = UUID()
        reading = false
        model.notice = nil
        model.clear()
        onCancel()
        dismiss()
    }
}

/// UIImage 跨执行器装箱（解码在后台；与聊天页 MergeImageBox 同纪律）。
private struct ThumbnailImageBox: @unchecked Sendable {
    let image: UIImage?
}

/// 缩略图：图片直接解码；PDF 取首页。只在内存中生成，不写缓存文件。
private struct StagingThumbnail: View {
    let item: ChatImportStagingModel.Item
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color("bg-grouped", bundle: .main)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: item.isPDF ? "doc.fill" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(item.isPDF
                         ? L10n.chatImportStagingPDFPages(item.pageCount)
                         : L10n.chatImportStagingImageBadge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }
            }
        }
        .clipped()
        .task(id: item.revision) { await load() }
    }

    private func load() async {
        if item.isPDF {
            guard let doc = PDFDocument(data: item.data),
                  let page = doc.page(at: 0) else { return }
            let rendered = page.thumbnail(of: CGSize(width: 240, height: 300), for: .mediaBox)
            guard !Task.isCancelled else { return }
            image = rendered
        } else {
            // 相册原图解码可能数百毫秒；20 张连续解码不得压在主线程。
            let data = item.data
            let box = await Task.detached(priority: .utility) {
                ThumbnailImageBox(image: UIImage(data: data))
            }.value
            guard !Task.isCancelled else { return }
            image = box.image
        }
    }
}
