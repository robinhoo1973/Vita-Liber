import SwiftUI
import UIKit
import Domain
import Infrastructure

/// SP-11 快速拍摄（首页四入口中的病历/报告/处方；症状走 observationCreate）。
///
/// TestFlight 实测修复记录：
/// 1. 入口按钮点击无反应 —— 根因① AppRouter.navigate 只 append 不切 Tab
///    （跨 Tab 路由用户留在原页）；根因② 本路由被列入「尚未落地」降级，
///    目的地静默渲染档案模块根。现已接真实相机流。
/// 2. 业界标准交互（备忘录「扫描文稿」/ 医疗文档采集类 app）：点入口即出
///    全屏相机，拍摄后自动入库，绝不要求用户先选来源再拍。
///
/// 拍摄后经 DocumentsState.importImage 走与资料库完全相同的生产管线：
/// SHA-256 去重 + OCR 文本随 meta 入库（FR5.6/FR6.1），同路径同语义。
struct QuickCaptureView: View {
    let kind: CaptureKind

    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var docs
    @Environment(AppRouter.self) private var router

    @State private var showCamera = false
    @State private var savedToast = false
    @State private var importFailed = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // 扫描引导图（虚线取景框呼应 onboarding 样张页视觉语言）
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .overlay(VLIcon.scanDocument.resizable().frame(width: 56, height: 56))
                .frame(maxWidth: 320, minHeight: 240)
            Text(title).font(.title2.bold())
            Text(L10n.homeCaptureHint)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showCamera = true
            } label: {
                Label(L10n.homeCaptureShoot, systemImage: "camera.fill")
                    .frame(maxWidth: 320, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("SP-11.capture.shoot")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                handleCapture(image)
            }
        }
        .alert(L10n.homeCaptureSaved, isPresented: $savedToast) {
            Button(L10n.docLibraryTitle) {
                router.navigate(to: .documentList)
            }
            Button(L10n.commonCancel, role: .cancel) { }
        } message: {
            Text(L10n.homeCaptureHint)
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

    private func handleCapture(_ image: UIImage) {
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
            if docs.lastImportError != nil {
                importFailed = true
            } else {
                savedToast = true
            }
        }
    }
}
