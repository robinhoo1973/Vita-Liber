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
    @State private var pickedItem: PhotosPickerItem?
    @State private var fileImporterActive = false
    @State private var savedToast = false
    @State private var importFailed = false

    /// 无相机设备时隐藏拍照来源（防崩溃 + 不误导用户）
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // 扫描引导图（虚线取景框呼应 onboarding 样张页视觉语言）
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
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {   // try?-ok: 单项加载失败走错误路径可见，不阻塞后续
                    await docs.importImage(patientId: app.currentPatientId, data: data,
                                           mimeType: "image/jpeg", docType: docTypeText,
                                           title: nil, isSensitive: false)
                    finishImport()
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
                Task {
                    await docs.importDocument(patientId: app.currentPatientId, url: url,
                                              docType: docTypeText)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    finishImport()
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

    private func handleImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            showCamera = false
            importFailed = true
            return
        }
        showCamera = false
        Task {
            await docs.importImage(patientId: app.currentPatientId, data: data,
                                   mimeType: "image/jpeg", docType: docTypeText,
                                   title: nil, isSensitive: false)
            finishImport()
        }
    }

    private func finishImport() {
        if docs.lastImportError != nil {
            importFailed = true
        } else {
            savedToast = true
        }
    }
}
