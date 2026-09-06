import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Domain
import Infrastructure

/// SP-11 快速拍摄（首页四入口中的病历/报告/处方；症状走 observationCreate）。
///
/// TestFlight 实测修复记录：
/// 1. 三来源（拍照 / 相册 / 文件）——业界标准（备忘录「扫描文稿」、医疗文档
///    采集类 app）：单一入口内给全来源，文件支持 PDF/图片/Word（Word 走
///    元数据归档，文本解析待 FilesStore 接齐）。
/// 2. 无相机设备（模拟器等）时隐藏拍照按钮并给出可见说明——此前 CameraPicker
///    直接设 sourceType = .camera 在无相机设备上崩溃（「黄三角出错」实测来源）。
/// 3. 首页发起时以 sheet 呈现（HomeView 处理）——拍摄完回首页，不进 Tab 栈，
///    修复「返回落到健康档案页 + path 残留套娃」。
///
/// 拍摄后经 DocumentsState 走与资料库完全相同的生产管线：
/// SHA-256 去重 + OCR 文本随 meta 入库（FR5.6/FR6.1），同路径同语义。
struct QuickCaptureView: View {
    let kind: CaptureKind

    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var docs
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    /// FR5.2 四角选区+透视矫正（拍摄/相册/文件图片共用）：待选区的原始图片。
    @State private var pendingRegionImage: UIImage?
    @State private var regionOrigin = "import"
    /// 相机来源需要选区后再走遮挡步骤（FR5.4）；相册/文件图片没有遮挡步骤。
    @State private var regionNeedsOcclusion = false
    @State private var showRegionEditor = false
    /// FR5.4 遮挡编辑原图（入库前步骤；UIImage 非 Identifiable，sheet 用布尔呈现）
    @State private var pendingOcclusionImage: UIImage?
    /// 遮挡前的原始帧（未矫正/未遮挡，BR-002）——与遮挡后的展示版一同落盘。
    @State private var pendingOcclusionOriginal: UIImage?
    @State private var showOcclusion = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var fileImporterActive = false
    @State private var savedToast = false
    @State private var importFailed = false
    /// BR-007 敏感默认锁定：病历/报告/处方类照片默认按敏感资料入库
    @State private var markSensitive = true
    /// FR6.1 确认卡（此前 OCR 完成即以 D 级静默入库，无用户确认环节）：OCR 后
    /// 展示，用户逐条确认/改正才写入数据库；处方类文档带处方语义字段标签。
    @State private var pendingDraft: DocumentsState.ImportDraft?

    /// 无相机设备时隐藏拍照来源（防崩溃 + 不误导用户）
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // 扫描引导图（虚线取景框——视觉规范出处：§5.13 拍摄引导占位框，
            // 四角选区编辑器 ScanRegionEditorView 与之同源）
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .overlay(VLIcon.scanDocument.resizable().frame(width: 56, height: 56))
                .frame(maxWidth: 320, minHeight: 180)
            Text(title).font(.title2.bold())
            Text(L10n.homeCaptureHint)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // 三来源：拍照（有相机才显示）/ 相册 / 文件
            VStack(spacing: 12) {
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label(L10n.homeCaptureShoot, systemImage: "camera.fill")
                            .frame(maxWidth: 320, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-11.capture.shoot")
                } else {
                    Label(L10n.homeCaptureNoCamera, systemImage: "camera.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(L10n.homeCaptureLibrary, systemImage: "photo.on.rectangle")
                        .frame(maxWidth: 320, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("SP-11.capture.library")
                Button {
                    fileImporterActive = true
                } label: {
                    Label(L10n.homeCaptureFile, systemImage: "folder")
                        .frame(maxWidth: 320, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("SP-11.capture.file")
            }

            // BR-007 敏感默认锁定（审查修复：原所有来源 isSensitive=false，
            // 敏感标记只能事后补救）
            Toggle(isOn: $markSensitive) {
                Text(L10n.captureSensitiveToggle).font(.subheadline)
            }
            .padding(.horizontal, 24)
            .accessibilityIdentifier("SP-11.capture.sensitive")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.commonCancel) { dismiss() }
                    .accessibilityIdentifier("SP-11.capture.cancel")
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                handleImage(image)
            }
        }
        // FR5.2 四角选区+透视矫正：自动预测四角，用户可拖拽微调，确认后矫正为正视图。
        .sheet(isPresented: $showRegionEditor) {
            if let img = pendingRegionImage {
                ScanRegionEditorView(image: img) { original, rectified in
                    pendingRegionImage = nil
                    if regionNeedsOcclusion {
                        pendingOcclusionOriginal = original
                        pendingOcclusionImage = rectified
                        showOcclusion = true
                    } else {
                        Task { await commitRectified(original: original, processed: rectified) }
                    }
                } onSkip: {
                    pendingRegionImage = nil
                }
            }
        }
        .sheet(isPresented: $showOcclusion) {
            if let img = pendingOcclusionImage {
                OcclusionEditorView(originalImage: img) { processed in
                    let original = pendingOcclusionOriginal ?? img
                    pendingOcclusionImage = nil
                    pendingOcclusionOriginal = nil
                    showOcclusion = false
                    Task { await commitRectified(original: original, processed: processed) }
                }
            }
        }
        // FR6.1 确认卡：拍摄/相册/文件三来源共用同一个「确认后才入库」环节
        .sheet(item: $pendingDraft) { draft in
            DocumentImportConfirmView(draft: draft)
        }
        // FR5.6/§5.52 重复检测：此前本视图无重复裁决 sheet，命中重复时
        // pendingDuplicate 被置位但无 UI 展示，finishImport() 却仍误报「已保存」
        // ——现与 DocumentLibraryView 共用同一裁决 sheet。
        .sheet(isPresented: duplicateAlertBinding) {
            DuplicateCompareSheet(
                existing: docs.duplicateHits.first,
                newTitle: docs.pendingDuplicate?.title ?? L10n.docDuplicateNewFile) { resolution in
                Task {
                    if let draft = await docs.resolveDuplicate(resolution) {
                        pendingDraft = draft
                    } else {
                        finishImport()
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),   // try?-ok: 单项加载失败走错误路径可见，不阻塞后续
                   let image = UIImage(data: data) {
                    beginRegionSelect(image: image, needsOcclusion: false, origin: "photoLibrary")
                } else {
                    importFailed = true
                }
            }
        }
        .fileImporter(isPresented: $fileImporterActive,
                      allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp"]
                if imageExtensions.contains(url.pathExtension.lowercased()),
                   let data = try? Data(contentsOf: url), let image = UIImage(data: data) {   // try?-ok: 读取失败走错误路径可见
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    beginRegionSelect(image: image, needsOcclusion: false, origin: "import")
                } else {
                    Task {
                        _ = await docs.importDocument(patientId: app.currentPatientId, url: url,
                                                      docType: docTypeText, isSensitive: markSensitive)
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        finishImport()
                    }
                }
            case .failure:
                importFailed = true
            }
        }
        .alert(L10n.homeCaptureSaved, isPresented: $savedToast) {
            Button(L10n.docLibraryTitle) {
                router.navigate(to: .documentList)
            }
            Button(L10n.commonCancel, role: .cancel) { }
        }
        .alert(L10n.docImportFailed, isPresented: $importFailed) {
            Button(L10n.commonCancel, role: .cancel) { }
        }
    }

    private var title: String {
        switch kind {
        case .record: return L10n.homeCaptureRecord
        case .report: return L10n.homeCaptureReport
        case .prescription: return L10n.homeCapturePrescription
        case .symptom: return L10n.homeCaptureSymptom   // 症状入口走观察创建，防御分支
        }
    }

    private var docTypeText: String {
        switch kind {
        case .record: return L10n.docTypeRecord
        case .report: return L10n.docTypeReport
        case .prescription: return L10n.docTypePrescription
        case .symptom: return L10n.docTypeRecord
        }
    }

    /// 文件来源允许类型：PDF + 全部图片 + Word（docx）
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .image]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        return types
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(get: { docs.pendingDuplicate != nil },
                set: { if !$0 { Task { _ = await docs.resolveDuplicate(.keep); finishImport() } } })
    }

    private func handleImage(_ image: UIImage) {
        showCamera = false
        beginRegionSelect(image: image, needsOcclusion: true, origin: "camera")
    }

    /// FR5.2 拍摄/选取后先进入四角选区，成功后按来源决定是否还要过 FR5.4 遮挡步骤。
    private func beginRegionSelect(image: UIImage, needsOcclusion: Bool, origin: String) {
        regionOrigin = origin
        regionNeedsOcclusion = needsOcclusion
        pendingRegionImage = image
        showRegionEditor = true
    }

    /// 区域矫正（+ 可能的遮挡）完成后：跑 OCR 组装确认草稿，交给确认卡，
    /// 用户确认后才真正写库（BR-003）。
    private func commitRectified(original: UIImage, processed: UIImage) async {
        guard let originalData = original.jpegData(compressionQuality: 0.9),
              let processedData = processed.jpegData(compressionQuality: 0.85) else {
            importFailed = true
            return
        }
        if let draft = await docs.prepareImageDraft(
            patientId: app.currentPatientId, originalData: originalData, processedData: processedData,
            mimeType: "image/jpeg", docType: docTypeText, title: nil,
            isSensitive: markSensitive, origin: regionOrigin) {
            pendingDraft = draft
        } else {
            finishImport()
        }
    }

    private func finishImport() {
        if docs.lastImportError != nil {
            importFailed = true
        } else if docs.pendingDuplicate == nil {
            // 命中重复时交给重复裁决 sheet 处理，不在此提前报「已保存」
            savedToast = true
        }
    }
}
