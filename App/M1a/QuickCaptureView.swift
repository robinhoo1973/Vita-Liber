import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Domain
import Infrastructure

/// Camera, photos and files all finish in the same retained import review session.
struct QuickCaptureView: View {
    let kind: CaptureKind?
    var patientId: UUID? = nil
    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var markSensitive = true
    @State private var selectionSessionID: UUID?
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var fileImporterActive = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var showRegionEditor = false
    @State private var regionImage: UIImage?
    @State private var showOcclusion = false
    @State private var occlusionImage: UIImage?
    @State private var regionAfterCamera = false
    @State private var reviewEnabled = true
    @State private var importFailed = false
    @State private var permissionDenied = false
    @State private var processedInput: Data?
    @State private var captureSheetTransition = false

    private var selection: DocumentsState.ImportSession? {
        guard let session = docs.activeImport, session.id == selectionSessionID else { return nil }
        return session
    }
    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    private var reviewCanPresent: Bool {
        let step = docs.activeImport?.captureStep
        return reviewEnabled && (step == nil || step == .review)
            && !showCamera && !showPhotos && !fileImporterActive && !showRegionEditor && !showOcclusion
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .overlay(VLIcon.scanDocument.resizable().frame(width: 56, height: 56))
                    .frame(maxWidth: 320, minHeight: 180)
                Text(title).font(.title2.bold())
                OCRReviewOwnerRow(patientId: docs.activeImport?.patientId ?? patientId ?? app.currentPatientId)
                Text(L10n.ocrReviewDocumentHint).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    if cameraAvailable {
                        Button { startCamera() } label: {
                            Label(L10n.homeCaptureShoot, systemImage: "camera.fill").frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("SP-11.capture.shoot")
                    } else {
                        Label(L10n.homeCaptureNoCamera, systemImage: "camera.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        if beginSelection(step: .photos) { showPhotos = true }
                    } label: {
                        Label(L10n.homeCaptureLibrary, systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(.bordered)
                    .accessibilityIdentifier("SP-11.capture.library")
                    Button {
                        if beginSelection(step: .file) { fileImporterActive = true }
                    } label: {
                        Label(L10n.homeCaptureFile, systemImage: "folder").frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(.bordered)
                    .accessibilityIdentifier("SP-11.capture.file")
                    Toggle(L10n.captureSensitiveToggle, isOn: $markSensitive)
                        .accessibilityIdentifier("SP-11.capture.sensitive")
                }
                .disabled(!docs.importSlotFree)
                if docs.activeImport != nil {
                    if docs.activeImport?.isPreparing == true { ProgressView() }
                    Button(L10n.pendingCardResume) { recoverSelection() }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
        }
        .background(Color("bg-grouped", bundle: .main))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.commonCancel) {
                    if let session = selection { docs.cancelImport(sessionID: session.id); _ = docs.finishImportPresentation(sessionID: session.id) }
                    dismiss()
                }
                .disabled(docs.activeImport?.isSaving == true || docs.activeImport?.isPreparing == true || docs.activeImport?.source != nil)
                .accessibilityIdentifier("SP-11.capture.cancel")
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            captureSheetTransition = false
            guard scenePhase == .active else { return }
            if regionAfterCamera {
                regionAfterCamera = false
                captureSheetTransition = true
                showRegionEditor = true
            } else { cancelSelection() }
        }) {
            CameraPicker { image in
                guard let session = selection, let data = image.jpegData(compressionQuality: 1) else { failSelection(); return }
                session.captureOriginalData = data; session.captureOrigin = "camera"
                session.captureStep = .region
                regionImage = image
                regionAfterCamera = true
                showCamera = false
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item, let session = selection else { return }
            session.isPreparing = true
            pickedItem = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        throw DocumentsState.ImportError.unreadableMedia
                    }
                    session.isPreparing = false
                    session.captureOriginalData = data; session.captureOrigin = "photoLibrary"
                    session.captureStep = .region
                    regionImage = image; captureSheetTransition = true; showRegionEditor = true
                } catch {
                    session.isPreparing = false
                    failSelection()
                }
            }
        }
        .onChange(of: showPhotos) { _, showing in
            if scenePhase == .active, !showing, pickedItem == nil, selection?.isPreparing == false,
               selection?.captureOriginalData == nil { cancelSelection() }
        }
        .fileImporter(isPresented: $fileImporterActive, allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
            guard let session = selection else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else { cancelSelection(); return }
                let scoped = url.startAccessingSecurityScopedResource()
                if ImageInputRules.supportedImageExtensions.contains(url.pathExtension.lowercased()) {
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        guard let image = UIImage(data: data) else { throw DocumentsState.ImportError.unreadableMedia }
                        session.captureOriginalData = data; session.captureOrigin = "import"
                        session.captureStep = .region
                        regionImage = image; captureSheetTransition = true; showRegionEditor = true
                    } catch { failSelection() }
                } else {
                    reviewEnabled = true
                    session.captureStep = .review
                    Task {
                        // PDF result is consumed, not discarded or reported as an already-saved file.
                        session.draft = await docs.importDocument(patientId: session.patientId, url: url,
                            docType: docTypeHint, isSensitive: session.captureSensitive)
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                }
            case .failure(let error):
                if (error as NSError).code == NSUserCancelledError { cancelSelection() }
                else { failSelection() }
            }
        }
        .sheet(isPresented: $showRegionEditor, onDismiss: {
            captureSheetTransition = false
            guard scenePhase == .active else { return }
            if occlusionImage != nil { captureSheetTransition = true; showOcclusion = true }
            else if processedInput != nil { startOCR() }
            else { cancelSelection() }
        }) {
            if let regionImage {
                ScanRegionEditorView(image: regionImage) { _, corrected in
                    selection?.captureProcessedData = corrected.jpegData(compressionQuality: 0.85)
                    if selection?.captureOrigin == "camera" {
                        occlusionImage = corrected; selection?.captureStep = .occlusion
                    } else {
                        processedInput = selection?.captureProcessedData; selection?.captureStep = .review
                    }
                } onSkip: {
                    processedInput = nil; occlusionImage = nil
                    selection?.captureProcessedData = nil
                }
                .interactiveDismissDisabled()
            } else {
                ContentUnavailableView(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
            }
        }
        .sheet(isPresented: $showOcclusion, onDismiss: {
            captureSheetTransition = false
            guard scenePhase == .active else { return }
            occlusionImage = nil
            if processedInput != nil { startOCR() }
            else { cancelSelection() }
        }) {
            if let occlusionImage {
                OcclusionEditorView(originalImage: occlusionImage) { processed in
                    processedInput = processed.jpegData(compressionQuality: 0.85)
                    selection?.captureProcessedData = processedInput
                    selection?.captureStep = .review
                }
                .interactiveDismissDisabled()
            }
        }
        .ocrImportReviewHost(enabled: reviewCanPresent, advanceQueuedImports: false) { outcome in
            selectionSessionID = nil
            regionImage = nil; processedInput = nil
            if outcome != .cancelled { dismiss() }
        }
        .alert(L10n.docImportFailedTitle, isPresented: $importFailed) {
            if permissionDenied {
                Button(L10n.homeNotifOpen) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button(L10n.commonCancel, role: .cancel) {}
        } message: { Text(L10n.docImportFailed) }
        .onAppear { recoverSelection() }
        .onChange(of: docs.activeImport?.captureStep) { _, _ in
            if !captureSheetTransition && !showCamera && !showRegionEditor && !showOcclusion && !showPhotos && !fileImporterActive { recoverSelection() }
        }
    }

    private func beginSelection(step: DocumentsState.CaptureStep) -> Bool {
        guard let session = docs.beginImport(patientId: patientId ?? app.currentPatientId) else { return false }
        session.captureSensitive = markSensitive
        session.captureStep = step
        selectionSessionID = session.id
        reviewEnabled = false; permissionDenied = false
        processedInput = nil; regionImage = nil; occlusionImage = nil
        return true
    }

    private func startCamera() {
        guard beginSelection(step: .camera), let session = selection else { return }
        session.isPreparing = true
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            session.isPreparing = false
            if allowed { captureSheetTransition = true; showCamera = true }
            else { permissionDenied = true; failSelection() }
        }
    }

    private func startOCR() {
        guard let session = selection, !session.isPreparing, let original = session.captureOriginalData,
              let processed = processedInput ?? session.captureProcessedData else { failSelection(); return }
        processedInput = nil
        session.captureStep = .review
        reviewEnabled = true
        Task {
            session.draft = await docs.prepareImageDraft(patientId: session.patientId, originalData: original,
                processedData: processed, mimeType: ImageInputRules.sniffMimeType(of: original),
                docType: docTypeHint, title: nil, isSensitive: session.captureSensitive, origin: session.captureOrigin)
        }
    }

    private func recoverSelection() {
        guard let session = docs.activeImport else { return }
        selectionSessionID = session.id
        guard !captureSheetTransition else { return }
        guard session.draft == nil, session.duplicate == nil, !session.isPreparing else {
            reviewEnabled = true
            return
        }
        guard !showRegionEditor && !showOcclusion && !showCamera && !showPhotos && !fileImporterActive else { return }
        switch session.captureStep {
        case .camera:
            reviewEnabled = false
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { captureSheetTransition = true; showCamera = true }
        case .photos: reviewEnabled = false; showPhotos = true
        case .file: reviewEnabled = false; fileImporterActive = true
        case .region:
            if let data = session.captureOriginalData, let image = UIImage(data: data) {
                reviewEnabled = false; regionImage = image; captureSheetTransition = true; showRegionEditor = true
            }
        case .occlusion:
            if let data = session.captureProcessedData, let image = UIImage(data: data) {
                reviewEnabled = false; occlusionImage = image; captureSheetTransition = true; showOcclusion = true
            }
        case .review:
            reviewEnabled = true
            if session.captureProcessedData != nil { startOCR() }
        case nil: reviewEnabled = true
        }
    }

    private func cancelSelection() {
        guard let session = selection else { return }
        docs.cancelImport(sessionID: session.id)
        _ = docs.finishImportPresentation(sessionID: session.id)
        selectionSessionID = nil; regionImage = nil; processedInput = nil
        reviewEnabled = true
    }

    private func failSelection() { cancelSelection(); importFailed = true }

    private var title: String {
        switch kind {
        case .record: return L10n.homeCaptureRecord
        case .report: return L10n.homeCaptureReport
        case .prescription: return L10n.homeCapturePrescription
        case .symptom: return L10n.homeCaptureSymptom
        case nil: return L10n.homeCaptureAny
        }
    }

    private var docTypeHint: String? {
        switch kind {
        case .record: return L10n.docTypeRecord
        case .report: return L10n.docTypeReport
        case .prescription: return L10n.docTypePrescription
        case .symptom, nil: return nil
        }
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .image]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        return types
    }
}
