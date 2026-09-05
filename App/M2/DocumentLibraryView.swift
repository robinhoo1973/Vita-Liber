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
    private var loadingPatientId: UUID?

    init(store: DocumentStore, pipeline: OCRPipeline) {
        self.store = store
        self.pipeline = pipeline
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
            // 机器识别未确认 = grade 'D'（BR-003：检索/AI 事实链排除，确认后升 C）
            var ocrText: String?
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
            _ = try await store.save(patientId: patientId, docType: docType,
                                     sha256: sha, mimeType: mimeType, origin: origin,
                                     isSensitive: isSensitive, metaJSON: nil, title: title,
                                     ocrText: ocrText, grade: "D")
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
            // Word/其他格式：元数据入库（文件名/哈希），文本解析待升级
            do {
                let data = try Data(contentsOf: url)
                _ = try await store.save(patientId: patientId, docType: docType,
                                         sha256: "file:" + Self.hash(data),
                                         mimeType: url.pathExtension, origin: "import",
                                         isSensitive: isSensitive,
                                         metaJSON: "{\"pendingParse\":\"docx\"}",
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
            // 逐页流式：单页渲染→识别→释放（页位图不整体驻留内存）
            try await decoder.decodePDFPages(data, scale: 2.0, maxPages: 50) { page in
                // ADR-026：PDF 逐页识别同样经统一编排层
                let result = (try? await pipeline.run(imageData: page.bitmapData))   // try?-ok: 单页失败继续下一页（FR6.6 汇总时标注）
                if let result, !result.failed, result.hasText {
                    texts.append(result.lines.joined(separator: "\n"))
                } else {
                    // 引擎失败与无文字分别标注（FR6.6：失败必须可见，不静默）
                    failedPages += 1
                    texts.append("")
                }
            }
            let joined = texts.filter { !$0.isEmpty }.joined(separator: "\n---\n")
            let metaPayload = ["engine": "vision", "page_count": pages.count,
                               "failed_pages": failedPages] as [String: Any]
            let metaJSON = String(data: try JSONSerialization.data(withJSONObject: metaPayload, options: []),
                                  encoding: .utf8)
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
    func resolveDuplicate(keepBoth: Bool) async {
        defer { pendingDuplicate = nil; duplicateHits = [] }
        guard keepBoth, let pending = pendingDuplicate, let patientId = loadingPatientId else { return }
        do {
            _ = try await store.save(patientId: patientId, docType: pending.docType,
                                     sha256: pending.sha256, mimeType: pending.mimeType,
                                     origin: pending.origin, isSensitive: pending.isSensitive,
                                     metaJSON: nil, title: pending.title, grade: "D")
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

    /// ADR-025：去重哈希走经审计的 CryptoKit（原 Domain 自研 SHA-256 引擎
    /// 已随 dev-pm V3.8 登记的端口迁移移除——生产路径零自研 crypto）
    static func hash(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        // FR5.6 重复检测：并排对比提示（绝不自动删除）
        .alert(L10n.docDuplicateTitle, isPresented: duplicateAlertBinding) {
            Button(L10n.docDuplicateKeepBoth) {
                Task { await state.resolveDuplicate(keepBoth: true) }
            }
            Button(L10n.docDuplicateDiscard, role: .cancel) {
                Task { await state.resolveDuplicate(keepBoth: false) }
            }
        } message: {
            Text(L10n.docDuplicateHint(state.duplicateHits.count))
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
        // FR5.1 文件导入（PDF/图片）
        .fileImporter(isPresented: $fileImporterActive,
                      allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            Task {
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
                set: { if !$0 { Task { await state.resolveDuplicate(keepBoth: false) } } })
    }
}

/// FR5.1 手工新建（第五入口）：标题 + 类型 + 备注
private struct ManualDocumentSheet: View {
    let onCreate: (String, String, String) -> Void
    @State private var title = ""
    @State private var type = DocumentStore.docTypeLabels[0]
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.docManualTitle, text: $title)
                Picker(L10n.docManualType, selection: $type) {
                    ForEach(DocumentStore.docTypeLabels, id: \.self) { Text($0) }
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
                            Text("D")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color("grade-d", bundle: .main)))
                                .foregroundStyle(.white)
                                .accessibilityLabel(L10n.docGradeUnconfirmed)
                        }
                        if doc.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(doc.title ?? L10n.docLibraryUntitled)
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

/// 列表（独立子视图：ForEach+行子视图，body 只留一次调用）
private struct DocumentListView: View {
    @Environment(DocumentsState.self) private var state

    var body: some View {
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
