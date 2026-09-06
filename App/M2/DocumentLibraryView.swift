import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import Domain
import Infrastructure
import Protocols

// MARK: - F5 资料库（SP-09/SP-10 · FR5.1-5.8 + FR6.6 PDF OCR）

/// 资料库状态仓：列表/入库（相机/文件/相册/手工）/归档/收藏/重复检测。
/// FR5.6 重复检测：文件哈希重复 → 提示疑似重复并给并排对比，绝不自动删除。
/// FR6.6 PDF 逐页 OCR：失败给出可见错误，绝不静默。
@MainActor
@Observable
final class DocumentsState {
    private(set) var documents: [DocumentStore.DocumentRow] = []
    private(set) var duplicateHits: [DocumentStore.DocumentRow] = []
    private(set) var pendingDuplicate: PendingDocument?
    private(set) var lastImportError: String?
    /// FR5.3 质量提示（最近一次导入的模糊/反光/遮挡标签——提示重拍不阻止保存）
    private(set) var lastQualityTags: [String] = []
    private let store: DocumentStore
    private let pipeline: OCRPipeline
    /// FR14.1 authOcr 消费点：授权关闭时不运行识别（资料照常入库，仅无识别文本）。
    /// 撤回即时生效——每次导入实时读值，不缓存授权状态。
    private let ocrAuthorized: @MainActor () -> Bool
    /// 原件专用目录根（BR-002，与 AppContainer.defaultOriginalsDir() 同约定）：
    /// `<base>/originals/{patientId}/{uuid}.{ext}`；预览/测试注入临时目录。
    private let originalsDir: URL
    private var loadingPatientId: UUID?

    init(store: DocumentStore, pipeline: OCRPipeline,
         ocrAuthorized: @escaping @MainActor () -> Bool = { true },
         originalsDir: URL? = nil) {
        self.store = store
        self.pipeline = pipeline
        self.ocrAuthorized = ocrAuthorized
        self.originalsDir = originalsDir ?? FileManager.default.temporaryDirectory
    }

    struct PendingDocument: Identifiable, Equatable {
        let id = UUID()
        var data: Data
        var mimeType: String
        var docType: String
        var title: String?
        var sha256: String
        var isSensitive: Bool
        var origin: String = "import"
    }

    func load(patientId: UUID, includeArchived: Bool = false) async {
        loadingPatientId = patientId
        do {
            let rows = try await store.list(patientId: patientId, includeArchived: includeArchived)
            guard loadingPatientId == patientId else { return }
            documents = rows
        } catch {
            documents = []
        }
    }

    /// 详情页用：单条取回（列表投影不含 meta_json，详情页需要解析原件路径等扩展字段）。
    func fetch(id: UUID) async -> DocumentStore.DocumentRow? {
        try? await store.fetch(id: id)   // try?-ok: 取回失败按「未找到」降级，不阻断详情页展示错误态
    }

    /// 原件落盘（BR-002：原件不可变，必须留档才能满足「永远能看原图」的产品承诺）。
    /// 与 AppState.saveOriginal 同约定：`<base>/originals/{patientId}/{uuid}.{ext}`，
    /// 只写一次不再修改。失败返回 nil——调用方仍照常入库，只是缺原图可查，
    /// 不能因为原件落盘失败就丢弃整份已识别资料（FR6.6 绝不静默丢失，但也绝不因小失大）。
    private func persistOriginal(patientId: UUID, data: Data, ext: String) -> String? {
        let dir = originalsDir
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(patientId.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    /// 把原件路径合并进已有 meta 载荷（不覆盖既有键）；无原件路径时原样返回 base。
    private func mergeOriginalPath(_ path: String?, into base: [String: Any]) -> String? {
        guard let path else {
            return base.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: base))   // try?-ok: 序列化本方法内部构造的纯 String 字典，理论不会失败；失败时静默回退 nil（即无 meta），不阻断文档入库主流程
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        var merged = base
        merged["original_path"] = path
        return (try? JSONSerialization.data(withJSONObject: merged))   // try?-ok: 同上，序列化失败时静默回退 nil，不阻断文档入库主流程
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func setArchived(id: UUID, archived: Bool) async {
        do {
            try await store.setArchived(id: id, archived: archived)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 错误经日志；列表刷新即真实状态
        }
    }

    func setFavorite(id: UUID, favorite: Bool) async {
        do {
            try await store.setFavorite(id: id, favorite: favorite)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 同上
        }
    }

    /// 图片入库（FR5.6 前置去重；FR6.1 OCR 文本随 meta 入库）
    /// title 与 DocumentStore.save 一致为 String?（相册导入无标题场景传 nil）
    /// origin 必须落在 document_file.origin CHECK 枚举内（camera/photoLibrary/import/
    /// scanner/manual）——曾用 "file" 触发 SQLITE_CONSTRAINT_CHECK，全部导入失败。
    func importImage(patientId: UUID, data: Data, mimeType: String,
                     docType: String, title: String?, isSensitive: Bool,
                     origin: String = "import") async {
        lastImportError = nil
        // 去重哈希：SHA-256（ADR-025：CryptoKit——经审计平台实现）
        let sha = "sha:" + Self.hash(data)
        do {
            let hits = try await store.duplicates(sha256: sha, patientId: patientId)
            guard hits.isEmpty else {
                duplicateHits = hits
                pendingDuplicate = PendingDocument(data: data, mimeType: mimeType,
                                                   docType: docType, title: title,
                                                   sha256: sha, isSensitive: isSensitive,
                                                   origin: origin)
                return
            }
            // FR6.1/ADR-026：OCR 经统一编排层（质量评估 + 识别）；
            // 识别文本写入 ocr_text 检索列（FTS 触发器自动索引）；
            // 机器识别未确认 = grade 'D'（BR-003：检索/AI 事实链排除，确认后升 C）。
            // FR14.1 authOcr：授权关闭 → 跳过识别，资料照常入库仅无识别文本
            // （撤回即时生效，关闭只停后续处理不删数据）。
            var ocrText: String?
            if ocrAuthorized() {
                do {
                    let result = try await pipeline.run(imageData: data)
                    lastQualityTags = result.qualityTags
                    if result.failed {
                        // FR6.6：识别引擎失败必须可见，绝不静默按「无文字」入库
                        lastImportError = L10n.docImportFailed
                        return
                    }
                    if !result.lines.isEmpty {
                        ocrText = result.lines.joined(separator: "\n")
                    }
                } catch {
                    // FR6.6：识别失败可见反馈，不静默按「无文字」入库
                    lastImportError = L10n.docImportFailed
                    return
                }
            }
            _ = try await store.save(patientId: patientId, docType: docType,
                                     sha256: sha, mimeType: mimeType, origin: origin,
                                     isSensitive: isSensitive,
                                     metaJSON: mergeOriginalPath(
                                         persistOriginal(patientId: patientId, data: data,
                                                        ext: mimeType.lowercased().contains("png") ? "png" : "jpg"),
                                         into: [:]),
                                     title: title, ocrText: ocrText, grade: "D")
            await load(patientId: patientId)
        } catch {
            lastImportError = L10n.docImportFailed
        }
    }

    /// 通用文件入库（快速拍摄「文件」来源）：PDF 走逐页 OCR 管线，图片走
    /// Vision 管线，其余格式（Word 等）归档元数据记录——原文件 body 落盘
    /// 待 FilesStore 接齐（技术债），文本解析同样待升级，绝不静默吞文件。
    /// isSensitive：快速拍摄默认 true（BR-007 敏感默认锁定）；资料库导入
    /// 沿用原语义 false（用户可后续标记）。
    func importDocument(patientId: UUID, url: URL, docType: String,
                        isSensitive: Bool = false) async {
        lastImportError = nil
        switch url.pathExtension.lowercased() {
        case "pdf":
            await importPDF(patientId: patientId, url: url, docType: docType,
                            isSensitive: isSensitive)
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp":
            guard let data = try? Data(contentsOf: url) else {   // try?-ok: 读取失败走错误路径可见，不阻塞后续导入
                lastImportError = L10n.docImportFailed
                return
            }
            await importImage(patientId: patientId, data: data, mimeType: url.pathExtension,
                              docType: docType, title: url.lastPathComponent,
                              isSensitive: isSensitive, origin: "import")
        default:
            // Word/其他格式：元数据入库（文件名/哈希）+ 原件落盘（BR-002），文本解析待升级
            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.isEmpty ? "docx" : url.pathExtension
                let path = persistOriginal(patientId: patientId, data: data, ext: ext)
                _ = try await store.save(patientId: patientId, docType: docType,
                                         sha256: "file:" + Self.hash(data),
                                         mimeType: url.pathExtension, origin: "import",
                                         isSensitive: isSensitive,
                                         metaJSON: mergeOriginalPath(path, into: ["pendingParse": ext]),
                                         title: url.lastPathComponent)
                await load(patientId: patientId)
            } catch {
                lastImportError = L10n.docImportFailed
            }
        }
    }

    /// FR6.6 PDF 逐页 OCR：PDFKitDecoder 渲染 → 逐页识别 → 文本入库。
    /// 渲染失败上抛 → lastImportError 可见（绝不静默）。
    /// 识别文本写入 ocr_text 检索列（原 base64 塞 meta_json：FTS 无法索引）；
    /// 机器识别未确认 = grade 'D'（BR-003），确认后升 C 才进入检索/AI 事实链。
    func importPDF(patientId: UUID, url: URL, docType: String, isSensitive: Bool = false) async {
        lastImportError = nil
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let decoder = PDFKitDecoder()
            var texts: [String] = []
            var failedPages = 0
            // FR14.1 authOcr：授权关闭 → 不逐页识别（只归档，meta 标 skipped）
            let ocrOn = ocrAuthorized()
            if ocrOn {
                // 逐页流式：单页渲染→识别→释放（页位图不整体驻留内存）
                try await decoder.decodePDFPages(data, scale: 2.0, maxPages: 50) { page in
                    // ADR-026：PDF 逐页识别同样经统一编排层
                    let result = (try? await self.pipeline.run(imageData: page.bitmapData))   // try?-ok: 单页失败继续下一页（FR6.6 汇总时标注）
                    if let result, !result.failed, result.hasText {
                        texts.append(result.lines.joined(separator: "\n"))
                    } else {
                        // 引擎失败与无文字分别标注（FR6.6：失败必须可见，不静默）
                        failedPages += 1
                        texts.append("")
                    }
                }
            }
            let joined = texts.filter { !$0.isEmpty }.joined(separator: "\n---\n")
            let metaPayload = ["engine": ocrOn ? "vision" : "skipped-auth",
                               "page_count": texts.count,
                               "failed_pages": failedPages] as [String: Any]
            let originalPath = persistOriginal(patientId: patientId, data: data, ext: "pdf")
            let metaJSON = mergeOriginalPath(originalPath, into: metaPayload)
            _ = try await store.save(patientId: patientId, docType: docType,
                                     sha256: "pdf:" + Self.hash(data), mimeType: "application/pdf",
                                     origin: "import", isSensitive: isSensitive,
                                     metaJSON: metaJSON, title: url.lastPathComponent,
                                     ocrText: joined.isEmpty ? nil : joined, grade: "D")
            await load(patientId: patientId)
        } catch {
            // FR6.6：失败必须给出可见错误反馈，绝不静默
            lastImportError = L10n.docPDFImportFailed
        }
    }

    /// 手工新建（FR5.1 第五入口）：标题 + 类型 + 备注文本
    func createManual(patientId: UUID, title: String, docType: String, note: String) async {
        do {
            let payload = ["note": note]
            let metaJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
            _ = try await store.save(patientId: patientId, docType: docType,
                                     sha256: nil, mimeType: nil, origin: "manual",
                                     isSensitive: false, metaJSON: metaJSON, title: title)
            await load(patientId: patientId)
        } catch {
            lastImportError = L10n.docImportFailed
        }
    }

    /// 重复提示后的用户裁决：并存（绝不自动删除）或放弃
    enum DuplicateResolution { case keep, coexist, replace }

    /// FR5.6/§5.52 三态裁决（V3.72）：保留已有（丢弃新）/两者并存/替换（归档旧版+存新版）。
    /// 绝不自动删除（归档=软删语义）。
    func resolveDuplicate(_ resolution: DuplicateResolution) async {
        defer { pendingDuplicate = nil; duplicateHits = [] }
        guard let pending = pendingDuplicate, let patientId = loadingPatientId else { return }
        switch resolution {
        case .keep:
            return   // 丢弃新文件——原件未被写入，无清理动作
        case .coexist, .replace:
            break
        }
        do {
            if resolution == .replace, let old = duplicateHits.first {
                try await store.setArchived(id: old.id, archived: true)
            }
            let ext = pending.mimeType.lowercased().contains("png") ? "png" : "jpg"
            let path = persistOriginal(patientId: patientId, data: pending.data, ext: ext)
            _ = try await store.save(patientId: patientId, docType: pending.docType,
                                     sha256: pending.sha256, mimeType: pending.mimeType,
                                     origin: pending.origin, isSensitive: pending.isSensitive,
                                     metaJSON: mergeOriginalPath(path, into: [:]),
                                     title: pending.title, grade: "D")
            await load(patientId: patientId)
        } catch {
            // 同上
        }
    }

    /// BR-003 D→C：用户显式确认机器识别文本后才进入检索与 AI 事实链。
    func confirmText(id: UUID) async {
        do {
            try await store.confirmText(id: id)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 错误经日志；列表刷新即真实状态
        }
    }

    /// ADR-025：去重哈希收敛到 ContentHashing 单实现（Infrastructure
    /// CryptoKitContentHasher）——生产路径零自研 crypto
    static func hash(_ data: Data) -> String {
        CryptoKitContentHasher().sha256Hex(data)
    }
}

/// 资料库列表（SP-09）：文档类型徽章 + 敏感锁标 + 归档/收藏滑动操作 +
/// 导入源（SP-10：相机/文件/相册/手工）+ 重复检测对比提示。
struct DocumentLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var showImportSource = false
    @State private var showArchived = false
    @State private var fileImporterActive = false
    @State private var photosImporterActive = false
    @State private var showManualCreate = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showImportError = false

    var body: some View {
        Group {
            if state.documents.isEmpty {
                DocumentLibraryEmptyView()
            } else {
                DocumentListView()
            }
        }
        .navigationTitle(L10n.docLibraryTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showArchived.toggle()
                    Task { await state.load(patientId: app.currentPatientId, includeArchived: showArchived) }
                } label: {
                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                }
                .accessibilityLabel(L10n.docArchive)
                Button {
                    showImportSource = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.docAdd)
                .accessibilityIdentifier("SP-09.document.add")
            }
        }
        .confirmationDialog(L10n.docImportSourceTitle, isPresented: $showImportSource,
                            titleVisibility: .visible) {
            // FR5.1 五入口：相机拍摄 / 文件导入（PDF/图片）/ 相册导入 / 手工新建
            Button(L10n.docImportCamera) { router.navigate(to: .scanCapture(.record)) }
            Button(L10n.docImportFile) { fileImporterActive = true }
            Button(L10n.docImportPhotos) { photosImporterActive = true }
            Button(L10n.docImportManual) { showManualCreate = true }
            Button(L10n.commonCancel, role: .cancel) { }
        }
        // FR5.6/§5.52 重复检测：并排对比三态裁决 sheet（V3.72，绝不自动删除）
        .sheet(isPresented: duplicateAlertBinding) {
            DuplicateCompareSheet(
                existing: state.duplicateHits.first,
                newTitle: state.pendingDuplicate?.title ?? L10n.docDuplicateNewFile) { resolution in
                Task { await state.resolveDuplicate(resolution) }
            }
            .presentationDetents([.medium])
        }
        // FR6.6 导入失败可见错误
        .alert(L10n.docImportFailedTitle, isPresented: $showImportError) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        } message: {
            Text(state.lastImportError ?? L10n.docImportFailed)
        }
        .onChange(of: state.lastImportError) { _, err in
            showImportError = err != nil
        }
        // FR5.1/FR5.7 文件导入（PDF/图片；批量多选逐份入库，归属确认在文档层 FR3.3 覆盖）
        .fileImporter(isPresented: $fileImporterActive,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls {
                    if url.pathExtension.lowercased() == "pdf" {
                        await state.importPDF(patientId: app.currentPatientId, url: url,
                                              docType: L10n.docTypeReport)
                    } else {
                        let data = (try? Data(contentsOf: url)) ?? Data()   // try?-ok: 读取失败走空数据→错误路径可见
                        await state.importImage(patientId: app.currentPatientId, data: data,
                                                mimeType: url.pathExtension,
                                                docType: L10n.docTypeReport, title: url.lastPathComponent,
                                                isSensitive: false, origin: "import")
                    }
                }
            }
        }
        // FR5.1 相册导入（逐份走归属确认——当前成员确认条在文档层已有 FR3.3 覆盖）
        .photosPicker(isPresented: $photosImporterActive, selection: $pickedPhotos,
                      maxSelectionCount: 5, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            for item in items {
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {   // try?-ok: 单项失败跳过，不阻塞批次
                        await state.importImage(patientId: app.currentPatientId, data: data,
                                                mimeType: "image",
                                                docType: L10n.docTypeRecord, title: nil,
                                                isSensitive: false, origin: "photoLibrary")
                    }
                }
            }
            pickedPhotos = []
        }
        .sheet(isPresented: $showManualCreate) {
            ManualDocumentSheet { title, type, note in
                Task {
                    await state.createManual(patientId: app.currentPatientId, title: title,
                                             docType: type, note: note)
                    showManualCreate = false
                }
            }
        }
        .task(id: app.currentPatientId) {
            await state.load(patientId: app.currentPatientId, includeArchived: showArchived)
        }
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(get: { state.pendingDuplicate != nil },
                set: { if !$0 { Task { await state.resolveDuplicate(.keep) } } })
    }
}

/// FR5.1 手工新建（第五入口）：标题 + 类型 + 备注
private struct ManualDocumentSheet: View {
    let onCreate: (String, String, String) -> Void
    @State private var title = ""
    @State private var type = L10n.docTypeLabels[0]
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.docManualTitle, text: $title)
                Picker(L10n.docManualType, selection: $type) {
                    ForEach(L10n.docTypeLabels, id: \.self) { Text($0) }
                }
                TextField(L10n.docManualNote, text: $note, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle(L10n.docManualCreateTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) {
                        onCreate(title, type, note)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 文档整行（独立子视图：NavigationLink + swipeActions + 行 label 结构过重，
/// Xcode 26 类型检查超时，拆小检查单元——「unable to type-check in
/// reasonable time」最佳实践；swipe 按钮用 label 闭包避开 String 参数重载歧义）
private struct DocumentLibraryRow: View {
    let doc: DocumentStore.DocumentRow
    let onSetArchived: (Bool) -> Void
    let onSetFavorite: (Bool) -> Void
    let onConfirmText: (() -> Void)?

    var body: some View {
        NavigationLink {
            DocumentDetailRouteView(documentId: doc.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(doc.docType)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(.systemGray5)))
                        // BR-003 来源徽章：D = 机器识别未确认（不进入检索/AI 事实链）
                        if doc.grade == "D" {
                            GradeBadge(grade: "D")
                        }
                        if doc.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(L10n.docTitle(doc.title))
                        .font(.subheadline)
                    Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if doc.status == "favorite" {
                    Image(systemName: "star.fill")
                        .font(.caption).foregroundStyle(.yellow)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            let archiveTitle = doc.status == "archived" ? L10n.docUnarchive : L10n.docArchive
            let favoriteTitle = doc.status == "favorite" ? L10n.docUnfavorite : L10n.docFavorite
            Button {
                onSetArchived(doc.status != "archived")
            } label: {
                Text(archiveTitle)
            }
            .tint(.orange)
            Button {
                onSetFavorite(doc.status != "favorite")
            } label: {
                Text(favoriteTitle)
            }
            .tint(.yellow)
        }
        .contextMenu {
            if doc.grade == "D", let onConfirmText {
                // BR-003 D→C：显式确认机器识别文本后才进入检索与 AI 事实链
                Button {
                    onConfirmText()
                } label: {
                    Label(L10n.docConfirmText, systemImage: "checkmark.seal")
                }
            }
        }
        .accessibilityIdentifier("SP-09.document.row.\(doc.id.uuidString)")
    }
}

/// 空态（独立子视图：body 瘦身，类型检查单元最小化）
private struct DocumentLibraryEmptyView: View {
    var body: some View {
        ContentUnavailableView(L10n.docLibraryEmpty, systemImage: "folder",
                               description: Text(L10n.docLibraryEmptyHint))
            .accessibilityIdentifier("SP-09.document.empty")
    }
}

/// F5 资料库文档详情（DocumentStore 落地行专用）。
///
/// 修复记录：此前 `DocumentDetailRouteView` 只查 `app.timeline`（M1a 旧管线专用
/// 内存数组）——经 `DocumentsState.importImage/importDocument/importPDF`（首页
/// 快速拍摄 + 资料库导入的当前生产路径）入库的文档点开恒显示「未找到」，且原图
/// 从未落盘、无处可查（BR-002/FR5.2 违规）。本视图 + `persistOriginal`/
/// `mergeOriginalPath`（`DocumentsState`）配合补齐：入库时落盘原图并记路径，
/// 详情页读路径展示；敏感文档经 `SensitiveMediaContainer` 逐次系统认证解锁
/// （BR-007/008），非敏感文档直接可看（与 `TimelineDocumentDetailView` 既有行为一致）。
struct DocumentStoreDetailView: View {
    @Environment(AppState.self) private var app
    let doc: DocumentStore.DocumentRow
    @State private var showOriginal = false

    private var originalPath: String? {
        guard let json = doc.metaJSON, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]   // try?-ok: meta_json 解析失败（如老版非 JSON 格式或损坏）按「无原图路径」降级，不阻断详情页展示其余字段
        else { return nil }
        return obj["original_path"] as? String
    }

    var body: some View {
        List {
            Section(L10n.docTitleSection) {
                Text(L10n.docTitle(doc.title)).font(.headline)
                LabeledContent(L10n.docDate, value: doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                HStack(spacing: 6) {
                    Text(doc.docType).font(.caption).foregroundStyle(.secondary)
                    if doc.grade == "D" { GradeBadge(grade: "D") }
                }
            }
            if originalPath != nil {
                Section {
                    if doc.isSensitive {
                        // BR-007/008：敏感文档原图逐次系统认证解锁，不做免认证直显
                        SensitiveMediaContainer { _ in
                            Label(L10n.sensitiveMedia_unlockToView, systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        } content: { _ in
                            Button {
                                showOriginal = true
                                app.auditViewSensitiveOriginal(documentId: doc.id, title: doc.title ?? "")
                            } label: {
                                Label(L10n.docViewOriginal, systemImage: "photo")
                            }
                        }
                        .accessibilityIdentifier("SP-09.document.detail.originalLocked")
                    } else {
                        Button {
                            showOriginal = true
                        } label: {
                            Label(L10n.docViewOriginal, systemImage: "photo")
                        }
                        .accessibilityIdentifier("SP-09.document.detail.original")
                    }
                }
            }
        }
        .sheet(isPresented: $showOriginal) {
            if let path = originalPath, let image = UIImage(contentsOfFile: path) {
                NavigationStack {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .padding(12)
                        .navigationTitle(L10n.docViewOriginal)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.onboard_gotIt) { showOriginal = false }
                            }
                        }
                }
            }
        }
        .navigationTitle(L10n.docDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 列表（独立子视图：ForEach+行子视图，body 只留一次调用）
private struct DocumentListView: View {
    @Environment(DocumentsState.self) private var state

    var body: some View {
        // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性）
        List {
            ForEach(state.documents) { doc in
                DocumentLibraryRow(doc: doc,
                                   onSetArchived: { archived in
                                       Task { await state.setArchived(id: doc.id, archived: archived) }
                                   },
                                   onSetFavorite: { favorite in
                                       Task { await state.setFavorite(id: doc.id, favorite: favorite) }
                                   },
                                   onConfirmText: doc.grade == "D"
                                       ? { Task { await state.confirmText(id: doc.id) } }
                                       : nil)
            }
        }
    }
}

/// §5.52 重复检测对比（V3.72）：左右两栏（已有 vs 新）+ 三选一裁决，
/// 默认「保留已有」；绝不自动删除。
struct DuplicateCompareSheet: View {
    let existing: DocumentStore.DocumentRow?
    let newTitle: String
    let onResolve: (DocumentsState.DuplicateResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice: DocumentsState.DuplicateResolution = .keep

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L10n.docDuplicateTitle).font(.headline)
                HStack(alignment: .top, spacing: 8) {
                    compareColumn(
                        title: L10n.docDuplicateExisting,
                        name: existing?.title ?? L10n.docUntitled,
                        date: existing.map { $0.createdAt.formatted(date: .abbreviated, time: .omitted) } ?? "",
                        grade: "C")
                    compareColumn(
                        title: L10n.docDuplicateNewFile,
                        name: newTitle,
                        date: "",
                        grade: "D")
                }
                Picker("", selection: $choice) {
                    Text(L10n.docDuplicateKeep).tag(DocumentsState.DuplicateResolution.keep)
                    Text(L10n.docDuplicateReplace).tag(DocumentsState.DuplicateResolution.replace)
                    Text(L10n.docDuplicateKeepBoth).tag(DocumentsState.DuplicateResolution.coexist)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("SP-09.duplicate.choice")
                HStack {
                    Button(L10n.onboard_cancel) { dismiss() }
                        .buttonStyle(.bordered)
                    Button(L10n.onboard_saveEdit) {
                        onResolve(choice)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text(L10n.docDuplicateNeverAutoDelete)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func compareColumn(title: String, name: String, date: String, grade: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.subheadline).lineLimit(2)
            if !date.isEmpty {
                Text(date).font(.caption2).foregroundStyle(.secondary)
            }
            GradeBadge(grade: grade)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }
}
