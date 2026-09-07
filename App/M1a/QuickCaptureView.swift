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
    /// 原始字节（BR-002 原件保真——第四轮全仓审查修复：原相册/文件来源读到的
    /// 原始 Data 被丢弃，落盘的「原件」是 0.9 质量 JPEG 重编码，校验值/内容
    /// 均与源文件不符；相机无源字节时用 1.0 质量编码兜底）
    @State private var pendingRegionOriginalData: Data?
    @State private var regionOrigin = "import"
    /// 相机来源需要选区后再走遮挡步骤（FR5.4）；相册/文件图片没有遮挡步骤。
    @State private var regionNeedsOcclusion = false
    @State private var showRegionEditor = false
    /// FR5.4 遮挡编辑原图（入库前步骤；UIImage 非 Identifiable，sheet 用布尔呈现）
    @State private var pendingOcclusionImage: UIImage?
    /// 遮挡前的原始帧（未矫正/未遮挡，BR-002）——与遮挡后的展示版一同落盘。
    @State private var pendingOcclusionOriginal: UIImage?
    @State private var pendingOcclusionOriginalData: Data?
    @State private var showOcclusion = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var fileImporterActive = false
    @State private var savedToast = false
    @State private var importFailed = false
    /// 重复裁决「已作出选择」标记（第五轮全仓审查修复）：sheet 保存按钮的
    /// onResolve 与 dismiss() 同一事务先后触发——dismiss 令 duplicateAlertBinding
    /// 的 setter 发出 .keep 任务，与选择任务竞速消费 pendingDuplicate：keep 先
    /// 到即清槽并弹「已保存」，而用户选的并存/替换草稿仍在 OCR 中——误报
    /// 已保存且裁决被静默降级为放弃。选择已作出时 setter 不得再发 keep。
    @State private var duplicateChoiceMade = false
    /// BR-007 敏感默认锁定：病历/报告/处方类照片默认按敏感资料入库
    @State private var markSensitive = true
    /// FR6.1 确认卡（此前 OCR 完成即以 D 级静默入库，无用户确认环节）：OCR 后
    /// 展示，用户逐条确认/改正才写入数据库；处方类文档带处方语义字段标签。
    @State private var pendingDraft: DocumentsState.ImportDraft?
    /// 相册加载代际号（第六轮全仓审查修复：连续选片竞速裁决）
    @State private var photoPickGeneration = 0
    /// 相机 cover 收起后再呈现选区 sheet 的延后标记（第六轮全仓审查修复）
    @State private var deferRegionEditorAfterCamera = false

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
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            // 第七轮全仓审查修复：选区 sheet 必须在 cover **完全收起后**呈现——
            // 原 onChange(showCamera) 只在 showCamera=false 的下一渲染帧触发，
            // 彼时 cover 仍在退场动画中，同事务 present 仍可撞转场冲突
            // （选区 sheet 不呈现、流程卡死——第六轮修复只延后了一个渲染帧，
            // 未跨过整个退场动画）。onDismiss 是系统给出的退场完成锚点。
            if deferRegionEditorAfterCamera {
                deferRegionEditorAfterCamera = false
                showRegionEditor = true
            }
        }) {
            CameraPicker { image in
                handleImage(image)
            }
        }
        // FR5.2 四角选区+透视矫正：自动预测四角，用户可拖拽微调，确认后矫正为正视图。
        .sheet(isPresented: $showRegionEditor, onDismiss: {
            // 第八轮全仓审查修复：选区→遮挡的过渡沿用 cover 退场完成锚点
            // 纪律——原 onChange(showRegionEditor) 只在关掉的下一渲染帧触发，
            // 彼时选区 sheet 仍在退场动画中（第七轮对 cover→选区过渡的同一
            // 结论：onChange「只跨一个渲染帧，未跨过整个退场动画」），遮挡
            // sheet 可能不呈现、矫正图滞留在 pendingOcclusionImage、流程卡死。
            // onDismiss 是系统给出的退场完成锚点。
            if pendingOcclusionImage != nil {
                showOcclusion = true
            }
        }) {
            if let img = pendingRegionImage {
                ScanRegionEditorView(image: img) { original, rectified in
                    let originalData = pendingRegionOriginalData
                    pendingRegionImage = nil
                    if regionNeedsOcclusion {
                        pendingOcclusionOriginal = original
                        pendingOcclusionOriginalData = originalData
                        pendingOcclusionImage = rectified
                    } else {
                        Task { await commitRectified(originalData: originalData, processed: rectified) }
                    }
                } onSkip: {
                    pendingRegionImage = nil
                    pendingRegionOriginalData = nil
                }
            }
        }
        // 相机拍摄完成 → 选区 sheet 的延后呈现已移至 fullScreenCover 的
        // onDismiss（退场完成锚点，第七轮修复——见 cover 声明处注释）
        .onChange(of: showOcclusion) { _, showing in
            if !showing {
                // 取消遮挡编辑器时清残留（第四轮全仓审查修复：原状态滞留，
                // 下次拍摄可能复用上一张的遮挡原图）
                pendingOcclusionImage = nil
                pendingOcclusionOriginal = nil
                pendingOcclusionOriginalData = nil
            }
        }
        .sheet(isPresented: $showOcclusion) {
            if let img = pendingOcclusionImage {
                OcclusionEditorView(originalImage: img) { processed in
                    let originalData = pendingOcclusionOriginalData
                        ?? pendingOcclusionOriginal?.jpegData(compressionQuality: 1.0)
                    pendingOcclusionImage = nil
                    pendingOcclusionOriginal = nil
                    pendingOcclusionOriginalData = nil
                    showOcclusion = false
                    Task { await commitRectified(originalData: originalData, processed: processed) }
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
                // 先挂草稿再释放裁决槽（clearPendingDuplicate 在 pendingDraft
                // 赋值之后）——否则槽空即触发 finishImport/「已保存」误报，
                // 且并存/替换草稿与 keep 任务竞速被静默丢弃
                duplicateChoiceMade = true
                Task {
                    let draft = await docs.resolveDuplicate(resolution)
                    pendingDraft = draft
                    docs.clearPendingDuplicate()
                    duplicateChoiceMade = false
                    if draft == nil {
                        finishImport()
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            // 第六轮全仓审查修复（竞速）：快速连续选片会并发两个
            // loadTransferable Task——慢的旧片后返回并覆写选区状态，展示图
            // 与「原件」字节分属两张照片（BR-002 原件保真断裂）。代际号
            // 使过期结果作废：只有最新一次选择的加载结果能进入选区。
            photoPickGeneration += 1
            let generation = photoPickGeneration
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),   // try?-ok: 单项加载失败走错误路径可见，不阻塞后续
                   let image = UIImage(data: data) {
                    guard generation == photoPickGeneration else { return }
                    // 原始字节贯穿选区/矫正链（BR-002 原件保真）
                    beginRegionSelect(image: image, originalData: data,
                                      needsOcclusion: false, origin: "photoLibrary")
                } else if generation == photoPickGeneration {
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
                // 扩展名白名单单一出处（第四轮全仓审查修复：原与
                // DocumentLibraryView 各持一份手写副本）
                if ImageInputRules.supportedImageExtensions.contains(url.pathExtension.lowercased()),
                   let data = try? Data(contentsOf: url), let image = UIImage(data: data) {   // try?-ok: 读取失败走错误路径可见
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    beginRegionSelect(image: image, originalData: data,
                                      needsOcclusion: false, origin: "import")
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
        // 第四轮全仓审查修复：确认卡内 commitDraft 失败（磁盘满/约束错误）
        // 只置 lastImportError 不抛出——本视图无 finishImport 兜底时失败
        // 静默（用户以为已保存）。监听错误态并弹可见告警（FR6.6）。
        // pendingDraft == nil 守卫（Phase 3 补漏）：确认卡打开时由其自带
        // 「保存失败」告警呈现，父级不再叠加「导入失败」——同一失败双弹窗。
        .onChange(of: docs.lastImportError) { _, err in
            if err != nil && pendingDraft == nil {
                importFailed = true
            }
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
                set: { if !$0 && !duplicateChoiceMade {
                    Task {
                        _ = await docs.resolveDuplicate(.keep)
                        finishImport()
                    }
                } })
    }

    private func handleImage(_ image: UIImage) {
        // 第六轮全仓审查修复：cover 关闭中不得同事务再 present sheet——
        // 与「选区→遮挡」跳转同族冲突（iOS 17 实测 sheet 可能不呈现、
        // 流程静默卡死）。第七轮升级为 cover onDismiss 锚点（退场完成）：
        // onChange(showCamera) 只跨一个渲染帧，仍在退场动画窗口内
        showCamera = false
        // 相机无源字节：1.0 质量编码兜底（BR-002 尽量保真；相机帧本身是
        // 传感器 JPEG，不再叠加 0.9 二次损失）
        regionOrigin = "camera"
        regionNeedsOcclusion = true
        pendingRegionImage = image
        pendingRegionOriginalData = image.jpegData(compressionQuality: 1.0)
        deferRegionEditorAfterCamera = true
    }

    /// FR5.2 拍摄/选取后先进入四角选区，成功后按来源决定是否还要过 FR5.4 遮挡步骤。
    private func beginRegionSelect(image: UIImage, originalData: Data?, needsOcclusion: Bool, origin: String) {
        regionOrigin = origin
        regionNeedsOcclusion = needsOcclusion
        pendingRegionImage = image
        pendingRegionOriginalData = originalData
        showRegionEditor = true
    }

    /// 区域矫正（+ 可能的遮挡）完成后：跑 OCR 组装确认草稿，交给确认卡，
    /// 用户确认后才真正写库（BR-003）。
    /// 原件 = 来源原始字节（BR-002 原件保真，第四轮全仓审查修复）；处理版
    /// 才是有损 JPEG 重编码。MIME 按字节嗅探（不再硬编码 image/jpeg）。
    private func commitRectified(originalData: Data?, processed: UIImage) async {
        guard let originalData = originalData ?? processed.jpegData(compressionQuality: 1.0),
              let processedData = processed.jpegData(compressionQuality: 0.85) else {
            importFailed = true
            return
        }
        let mime = ImageInputRules.sniffMimeType(of: originalData)
        if let draft = await docs.prepareImageDraft(
            patientId: app.currentPatientId, originalData: originalData, processedData: processedData,
            mimeType: mime, docType: docTypeText, title: nil,
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
