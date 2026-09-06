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
    /// SP-53 队列数据源：跨成员聚合的 D 级文档（成员筛选在视图层做——
    /// 此前队列复用 docs.documents（仅当前成员），选其他成员恒空态）。
    private(set) var pendingDocuments: [DocumentStore.DocumentRow] = []
    private(set) var duplicateHits: [DocumentStore.DocumentRow] = []
    private(set) var pendingDuplicate: PendingDocument?
    private(set) var lastImportError: String?
    private let store: DocumentStore
    private let pipeline: OCRPipeline
    /// PDF 解码（ADR-027：经 EAL 注入，调用方不直接实例化具体引擎——
    /// 第四轮全仓审查修复：importPDF 曾直接 new PDFKitDecoder() 绕过注册表）。
    private let decoder: any ImageDecoding
    /// F9 处方落库（只有确认后才会被调用，未注入时（预览/测试）静默跳过）。
    private let prescriptionStore: PrescriptionStore?
    /// “处方单”文档类型标签（与 L10n.docTypePrescription 同源）——命中时启用处方语义字段标签。
    private let prescriptionDocTypeLabel: String
    /// FR14.1 authOcr 消费点：授权关闭时不运行识别（资料照常入库，仅无识别文本）。
    /// 撤回即时生效——每次导入实时读值，不缓存授权状态。
    private let ocrAuthorized: @MainActor () -> Bool
    /// 原件专用目录根（BR-002，与 AppContainer.defaultOriginalsDir() 同约定）：
    /// `<base>/originals/{patientId}/{uuid}.{ext}`；预览/测试注入临时目录。
    private let originalsDir: URL
    private var loadingPatientId: UUID?

    init(store: DocumentStore, pipeline: OCRPipeline,
         decoder: (any ImageDecoding)? = nil,
         ocrAuthorized: @escaping @MainActor () -> Bool = { true },
         originalsDir: URL? = nil, prescriptionStore: PrescriptionStore? = nil,
         prescriptionDocTypeLabel: String = L10n.docTypePrescription) {
        self.store = store
        self.pipeline = pipeline
        self.decoder = decoder ?? EngineRegistry.shared.resolve(ImageDecodingFactory.self)
        self.ocrAuthorized = ocrAuthorized
        self.originalsDir = originalsDir ?? FileManager.default.temporaryDirectory
        self.prescriptionStore = prescriptionStore
        self.prescriptionDocTypeLabel = prescriptionDocTypeLabel
    }

    struct PendingDocument: Identifiable, Equatable {
        let id = UUID()
        /// 导入时的所属成员（第四轮全仓审查修复：裁决落库必须用它，绝不用
        /// loadingPatientId——导入后、裁决前切换成员时后者已指向他人，
        /// 或从未 load 时为 nil → 并存/替换静默丢弃且误报「已保存」）。
        var patientId: UUID
        var originalData: Data
        var processedData: Data
        var mimeType: String
        var docType: String
        var title: String?
        var sha256: String
        var isSensitive: Bool
        var origin: String = "import"
    }

    /// 确认卡的载体：已查重+跑过 OCR 的待确认草稿——尚未写库，等用户逐条确认
    /// （BR-003：机器识别字段必须确认才生效）。
    struct ImportDraft: Identifiable {
        let id = UUID()
        var patientId: UUID
        var docType: String
        var title: String?
        var isSensitive: Bool
        var origin: String
        var sha256: String
        /// 拍摄/选取的原始帧（未经矫正/遮挡，BR-002）。
        var originalData: Data
        /// 矫正+遮挡后的展示版（OCR 与入库用）。
        var processedData: Data
        var mimeType: String
        var qualityTags: [String]
        var confirmationSet: OcrConfirmationSet
        var isPrescription: Bool
        /// 「替换」裁决的旧文档（第四轮全仓审查修复：旧版归档延后到新版本
        /// 确认入库**之后**——此前 resolveDuplicate 先归档旧版再弹确认卡，
        /// 用户取消 = 旧版已从活跃列表消失 + 新版未入库，资料凭空少一份）
        var replaceDocumentId: UUID?
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

    /// SP-53 待确认队列：跨成员聚合 D 级文档（成员筛选视图层做）。
    func loadPending(patientIds: [UUID]) async {
        do {
            pendingDocuments = try await store.listPending(patientIds: patientIds)
        } catch {
            pendingDocuments = []
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

    /// 图片入库第一阶段：查重 + OCR（在矫正/遮挡后的图像上跑），**不写库**。
    /// 命中重复时写入 pendingDuplicate（由调用方展示并徕裁决），返回 nil；
    /// 否则返回待确认草稿，由调用方展示 `DocumentImportConfirmView` 让用户逐条确认。
    /// origin 必须落在 document_file.origin CHECK 枚举内（camera/photoLibrary/import/
    /// scanner/manual）——曾用 "file" 触发 SQLITE_CONSTRAINT_CHECK，全部导入失败。
    func prepareImageDraft(patientId: UUID, originalData: Data, processedData: Data, mimeType: String,
                           docType: String, title: String?, isSensitive: Bool,
                           origin: String = "import") async -> ImportDraft? {
        lastImportError = nil
        // 去重哈希注定到矫正/遮挡后的展示版——同一张原始照片选不同区域/不同遮挡视为不同文档
        let sha = "sha:" + Self.hash(processedData)
        do {
            let hits = try await store.duplicates(sha256: sha, patientId: patientId)
            guard hits.isEmpty else {
                duplicateHits = hits
                pendingDuplicate = PendingDocument(patientId: patientId, originalData: originalData, processedData: processedData,
                                                   mimeType: mimeType, docType: docType, title: title,
                                                   sha256: sha, isSensitive: isSensitive, origin: origin)
                return nil
            }
        } catch {
            lastImportError = L10n.docImportFailed
            return nil
        }
        return await buildDraft(patientId: patientId, originalData: originalData, processedData: processedData,
                                mimeType: mimeType, docType: docType, title: title,
                                isSensitive: isSensitive, origin: origin, sha256: sha)
    }

    /// OCR 跑完后组装待确认草稿：处方文档类型用处方语义标签（药品名/剂量/频次/医院/医生），
    /// 其余类型用通用 line_N 标签。FR6.1/ADR-026：OCR 经统一编排层（质量评估+识别）；
    /// FR14.1 authOcr：授权关闭 → 跳过识别，草稿无候选字段但仍可确认保存（只是无识别文本）。
    private func buildDraft(patientId: UUID, originalData: Data, processedData: Data, mimeType: String,
                            docType: String, title: String?, isSensitive: Bool, origin: String,
                            sha256: String, replaceDocumentId: UUID? = nil) async -> ImportDraft? {
        // BR 判定走 Domain 纯函数（第四轮全仓审查修复：原内联 docType == label
        // 绕过 PrescriptionFieldMapper，口径演进时两处漂移）
        let isPrescription = PrescriptionFieldMapper.isPrescriptionDocType(docType, prescriptionLabel: prescriptionDocTypeLabel)
        var fields: [CandidateField] = []
        var tags: [String] = []
        if ocrAuthorized() {
            do {
                let result = try await pipeline.run(imageData: processedData)
                tags = result.qualityTags
                if result.failed {
                    // FR6.6：识别引擎失败必须可见，绝不静默按「无文字」入库
                    lastImportError = L10n.docImportFailed
                    return nil
                }
                if isPrescription {
                    fields = PrescriptionFieldMapper.draftFields(from: result.lines, labels: Self.prescriptionLabels)
                } else {
                    fields = result.lines.enumerated().map { idx, line in
                        CandidateField(key: "line_\(idx)",
                                       displayLabel: String(format: L10n.ocrFieldLine, idx + 1),
                                       rawText: line, confidence: 0.6)
                    }
                }
            } catch {
                lastImportError = L10n.docImportFailed
                return nil
            }
        }
        return ImportDraft(patientId: patientId, docType: docType, title: title, isSensitive: isSensitive,
                           origin: origin, sha256: sha256, originalData: originalData, processedData: processedData,
                           mimeType: mimeType, qualityTags: tags,
                           confirmationSet: OcrConfirmationSet(fields: fields),   // confirm-ok: F6/F9 图片入库 OCR 确认集是合法产出方（非语音路径），FR17.13 只约束语音草稿确认
                           isPrescription: isPrescription, replaceDocumentId: replaceDocumentId)
    }

    private static let prescriptionLabels = PrescriptionFieldMapper.Labels(
        hospital: L10n.prescriptionFieldHospital, doctor: L10n.prescriptionFieldDoctor,
        frequency: L10n.prescriptionFieldFrequency, dosage: L10n.prescriptionFieldDosage,
        drugName: L10n.prescriptionFieldDrugName, other: L10n.prescriptionFieldOther)

    /// 用户在 `DocumentImportConfirmView` 确认全部字段后调用：原件+处理版双落盘，
    /// document_file 直接以 grade='C' 写入（确认已完成，不再经 D），处方文档额外落
    /// 一条 prescription 行（复用现有 hospital/doctor/advice_text 列，不新增迁移）。
    func commitDraft(_ draft: ImportDraft) async {
        // 错误态归零：保存失败必须可见、成功必须清除残留（第四轮全仓审查
        // 修复——确认卡以 lastImportError 判成功/失败并决定是否 dismiss）
        lastImportError = nil
        // 原件扩展名按真实 MIME 映射（第四轮全仓审查修复：原仅判 "png" 其余
        // 一律 .jpg——HEIC/GIF/WebP 原件以 .jpg 落盘，扩展名与内容不符，
        // BR-002 原图语义受损）
        let ext = ImageInputRules.fileExtension(for: draft.mimeType)
        let originalPath = persistOriginal(patientId: draft.patientId, data: draft.originalData, ext: ext)
        let processedPath = persistOriginal(patientId: draft.patientId, data: draft.processedData, ext: ext)
        var meta: [String: Any] = [:]
        if let originalPath { meta["original_path"] = originalPath }
        if let processedPath { meta["processed_path"] = processedPath }
        let metaJSON = meta.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: meta))   // try?-ok: 序列化本方法内部构造的纯 String 字典，理论不会失败；失败时静默回退 nil，不阻断确认保存主流程
            .flatMap { String(data: $0, encoding: .utf8) }
        let ocrText = draft.confirmationSet.confirmedFields.map(\.value).joined(separator: "\n")
        do {
            let docId = try await store.save(patientId: draft.patientId, docType: draft.docType,
                                             sha256: draft.sha256, mimeType: draft.mimeType, origin: draft.origin,
                                             isSensitive: draft.isSensitive, metaJSON: metaJSON, title: draft.title,
                                             ocrText: ocrText.isEmpty ? nil : ocrText, grade: "C")
            if draft.isPrescription, let prescriptionStore {
                let (hospital, doctor, adviceText) = PrescriptionFieldMapper.buildAdviceText(confirmed: draft.confirmationSet.confirmedFields,
                                                                                             labels: Self.prescriptionLabels)
                try? await prescriptionStore.create(patientId: draft.patientId, documentFileId: docId,   // try?-ok: 处方行写入失败不回滚 document_file（主记录已入库），鼓励用户到资料库重新确认后重试，不能因副表失败丢主文档
                                                     hospital: hospital, doctor: doctor, adviceText: adviceText)
            }
            // FR6.1 识别留痕：已确认字段逐行落 ocr_result（原文块+置信度+引擎版本，
            // 可追溯可重放）。V3.39 起此处是唯一写入口——旧 AppState 引擎已删除；
            // 留痕副表失败不回滚主记录（与处方副表同策略）。
            if !draft.confirmationSet.confirmedFields.isEmpty {
                try? await store.saveOCRResult(documentId: docId,   // try?-ok: 留痕失败不阻断主入库，主记录已落盘
                                               fields: draft.confirmationSet.confirmedFields,
                                               engineVersion: "ocr-pipeline")
            }
            // 「替换」语义：新版本已确认入库，此时才归档旧版（第四轮全仓审查
            // 修复——此前先归档后确认，取消确认卡 = 旧版已归档+新版未入库，
            // 用户资料凭空少一份）。归档失败不阻断：列表刷新即真实状态。
            if let replaceId = draft.replaceDocumentId {
                try? await store.setArchived(id: replaceId, archived: true)   // try?-ok: 归档旧版失败不阻断主入库流程，下次列表刷新自愈
            }
            await load(patientId: draft.patientId)
        } catch {
            lastImportError = L10n.docImportFailed
        }
    }

    /// 通用文件入库（快速拍摄「文件」来源）：PDF 走逐页 OCR 管线，图片走
    /// Vision 管线（未经四角选区，直接以原图=处理版组草稿，同样需确认后才入库），
    /// 其余格式（Word 等）归档元数据记录——原文件 body 解析待升级，绝不静默吞文件。
    /// isSensitive：快速拍摄默认 true（BR-007 敏感默认锁定）；资料库导入
    /// 沿用原语义 false（用户可后续标记）。
    func importDocument(patientId: UUID, url: URL, docType: String,
                        isSensitive: Bool = false) async -> ImportDraft? {
        lastImportError = nil
        switch url.pathExtension.lowercased() {
        case "pdf":
            await importPDF(patientId: patientId, url: url, docType: docType, isSensitive: isSensitive)
            return nil
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp":
            guard let data = try? Data(contentsOf: url) else {   // try?-ok: 读取失败走错误路径可见，不阻塞后续导入
                lastImportError = L10n.docImportFailed
                return nil
            }
            // MIME 按字节嗅探（第四轮全仓审查修复：原把扩展名直接当 MIME 传，
            // 扩展名与内容脱钩后 fileExtension(for:) 映射恒回落 .jpg）
            let mime = ImageInputRules.sniffMimeType(of: data,
                                                     fallback: "image/\(url.pathExtension.lowercased())")
            return await prepareImageDraft(patientId: patientId, originalData: data, processedData: data,
                                           mimeType: mime, docType: docType,
                                           title: url.lastPathComponent, isSensitive: isSensitive, origin: "import")
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
            return nil
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
            var texts: [String] = []
            var failedPages = 0
            // FR14.1 authOcr：授权关闭 → 不逐页识别（只归档，meta 标 skipped）
            let ocrOn = ocrAuthorized()
            if ocrOn {
                // 逐页流式：单页渲染→识别→释放（页位图不整体驻留内存）。
                // 解码器经 EAL 注入（ADR-027：调用方不直接实例化具体引擎——
                // 第四轮全仓审查修复，测试可替身、注册表解码工厂不再死代码）。
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
    /// 绝不自动删除（归档=软删语义）。并存/替换同样经确认卡（返回草稿而非直接写库）。
    func resolveDuplicate(_ resolution: DuplicateResolution) async -> ImportDraft? {
        defer { pendingDuplicate = nil; duplicateHits = [] }
        // 第四轮全仓审查修复（5WHY）：归属用 pending 自带的 patientId（导入时
        // 固化），绝不用 loadingPatientId——导入后裁决前切换成员/从未 load
        // 时，草稿会被挂到错误成员名下或被静默丢弃且误报「已保存」。
        guard let pending = pendingDuplicate else { return nil }
        let patientId = pending.patientId
        switch resolution {
        case .keep:
            return nil   // 丢弃新文件——原件未被写入，无清理动作
        case .coexist, .replace:
            break
        }
        // 「替换」的归档动作延后到确认卡入库之后（见 ImportDraft.replaceDocumentId）
        return await buildDraft(patientId: patientId, originalData: pending.originalData,
                                processedData: pending.processedData, mimeType: pending.mimeType,
                                docType: pending.docType, title: pending.title,
                                isSensitive: pending.isSensitive, origin: pending.origin, sha256: pending.sha256,
                                replaceDocumentId: resolution == .replace ? duplicateHits.first?.id : nil)
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

    /// 列表主体与导入入口动作拆为独立计算属性（CI 34037986523 实证：
    /// 巨型 body 表达式超出 Swift 类型推断预算——「unable to type-check
    /// in reasonable time」。拆分为显式类型边界后各段独立推断）。
    private var importContent: some View {
        Group {
            if state.documents.isEmpty {
                DocumentLibraryEmptyView()
            } else {
                DocumentListView()
            }
        }
    }

    /// FR5.1 五入口确认弹窗内容：相机拍摄 / 文件导入（PDF/图片）/ 相册导入 / 手工新建
    @ViewBuilder private var importSourceActions: some View {
        Button(L10n.docImportCamera) { router.navigate(to: .scanCapture(.record)) }
        Button(L10n.docImportFile) { fileImporterActive = true }
        Button(L10n.docImportPhotos) { photosImporterActive = true }
        Button(L10n.docImportManual) { showManualCreate = true }
        Button(L10n.commonCancel, role: .cancel) { }
    }

    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var showImportSource = false
    @State private var showArchived = false
    @State private var fileImporterActive = false
    /// 文件多选串行队列（与 photoQueue 同纪律：单槽占用时暂停）
    @State private var fileQueue: [URL] = []
    @State private var photosImporterActive = false
    @State private var showManualCreate = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// 相册多选串行队列（第四轮全仓审查修复：防并发 Task 覆盖单槽状态）
    @State private var photoQueue: [PhotosPickerItem] = []
    @State private var showImportError = false
    /// FR6.1 确认卡（此前导入即以 D 级静默入库，无用户确认环节）：OCR 后展示，
    /// 用户逐条确认/改正才写入数据库。
    @State private var pendingDraft: DocumentsState.ImportDraft?

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
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

    var body: some View {
        importContent
            .navigationTitle(L10n.docLibraryTitle)
            .toolbar {
                libraryToolbar
            }
            .confirmationDialog(L10n.docImportSourceTitle, isPresented: $showImportSource,
                                titleVisibility: .visible) {
                importSourceActions
            }
        // FR5.6/§5.52 重复检测：并排对比三态裁决 sheet（V3.72，绝不自动删除）
        .sheet(isPresented: duplicateAlertBinding) {
            DuplicateCompareSheet(
                existing: state.duplicateHits.first,
                newTitle: state.pendingDuplicate?.title ?? L10n.docDuplicateNewFile) { resolution in
                Task { pendingDraft = await state.resolveDuplicate(resolution) }
            }
            .presentationDetents([.medium])
        }
        // FR6.1 确认卡：并存/替换与直接导入共用同一个确认环节
        .sheet(item: $pendingDraft) { draft in
            DocumentImportConfirmView(draft: draft)
        }
        // FR6.6 导入失败可见错误
        .alert(L10n.docImportFailedTitle, isPresented: $showImportError) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        } message: {
            Text(state.lastImportError ?? L10n.docImportFailed)
        }
        .onChange(of: state.lastImportError) { _, err in
            handleImportErrorChange(err)
        }
        // FR5.1/FR5.7 文件导入（PDF/图片；批量多选逐份入库，归属确认在文档层 FR3.3 覆盖）。
        .fileImporter(isPresented: $fileImporterActive,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            enqueueFiles(result)
        }
        // FR5.1 相册导入（逐份走归属确认——当前成员确认条在文档层已有 FR3.3 覆盖）
        .photosPicker(isPresented: $photosImporterActive, selection: $pickedPhotos,
                      maxSelectionCount: 5, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            enqueuePhotos(items)
        }
        // 单槽（确认卡/重复裁决 sheet）释放即续跑串行队列——两个 onChange
        // 合并为一个 Bool 观察，缩减 body 推断负载（CI 34038910193 实证）
        .onChange(of: queueSlotFree) { _, free in
            if free { resumeQueues() }
        }
        .sheet(isPresented: $showManualCreate) {
            ManualDocumentSheet { title, type, note in
                createManual(title: title, type: type, note: note)
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

    /// 单槽占用态：确认卡或重复裁决 sheet 任一打开即占用（串行队列暂停条件）
    private var queueSlotFree: Bool {
        state.pendingDuplicate == nil && pendingDraft == nil
    }

    private func handleImportErrorChange(_ err: String?) {
        // pendingDraft 打开时由确认卡自带「保存失败」告警呈现（Phase 3
        // 补漏：父级不叠加，同一失败不得双弹窗）
        showImportError = err != nil && pendingDraft == nil
    }

    /// 文件导入入队：追加而非替换（Phase 3 补漏：前一批未处理完时重开不丢件）
    private func enqueueFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        fileQueue.append(contentsOf: urls)
        processFileQueue()
    }

    /// 相册导入入队：串行队列（第四轮全仓审查修复）——多选命中多份重复时
    /// 后完成者不再覆盖先完成者；单槽占用时暂停，sheet 关掉后 onChange 续跑。
    private func enqueuePhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoQueue.append(contentsOf: items)
        pickedPhotos = []
        processPhotoQueue()
    }

    private func resumeQueues() {
        processPhotoQueue()
        processFileQueue()
    }

    private func createManual(title: String, type: String, note: String) {
        Task {
            await state.createManual(patientId: app.currentPatientId, title: title,
                                     docType: type, note: note)
            showManualCreate = false
        }
    }

    /// 相册多选串行推进：单槽（确认卡/重复裁决 sheet）被占用时暂停，
    /// 关掉后续跑（onChange 驱动）。一张处理完再下一张——多选命中多份
    /// 重复时逐一呈现，绝不静默丢弃（第四轮全仓审查修复）。
    private func processPhotoQueue() {
        guard !photoQueue.isEmpty else { return }
        guard state.pendingDuplicate == nil else { return }
        guard pendingDraft == nil else { return }
        let item = photoQueue.removeFirst()
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {   // try?-ok: 单项失败跳过，不阻塞批次（错误经 lastImportError 可见）
                // MIME 按字节嗅探（第四轮全仓审查修复：相册 HEIC 曾硬编码
                // image/jpeg 导致原件扩展名与内容不符）
                let mime = ImageInputRules.sniffMimeType(of: data)
                if let draft = await state.prepareImageDraft(
                    patientId: app.currentPatientId, originalData: data, processedData: data,
                    mimeType: mime, docType: L10n.docTypeRecord, title: nil,
                    isSensitive: false, origin: "photoLibrary") {
                    pendingDraft = draft
                }
            }
            processPhotoQueue()
        }
    }

    /// 文件多选串行推进（与 processPhotoQueue 同纪律）
    private func processFileQueue() {
        guard !fileQueue.isEmpty else { return }
        guard state.pendingDuplicate == nil else { return }
        guard pendingDraft == nil else { return }
        let url = fileQueue.removeFirst()
        Task {
            if url.pathExtension.lowercased() == "pdf" {
                await state.importPDF(patientId: app.currentPatientId, url: url,
                                      docType: L10n.docTypeReport)
            } else if let draft = await state.importDocument(patientId: app.currentPatientId, url: url,
                                                              docType: L10n.docTypeReport) {
                pendingDraft = draft
            }
            processFileQueue()
        }
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
/// 修复记录：此前 `DocumentDetailRouteView` 先查 `app.timeline`（M1a 旧管线专用
/// 内存数组，V3.39 已随向导简化删除）——经 `DocumentsState`（首页快速拍摄 +
/// 资料库导入的当前生产路径）入库的文档点开恒显示「未找到」，且原图
/// 从未落盘、无处可查（BR-002/FR5.2 违规）。本视图 + `persistOriginal`/
/// `mergeOriginalPath`（`DocumentsState`）配合补齐：入库时落盘原图并记路径，
/// 详情页读路径展示；敏感文档经 `SensitiveMediaContainer` 逐次系统认证解锁
/// （BR-007/008），非敏感文档直接可看（与 `TimelineDocumentDetailView` 既有行为一致）。
struct DocumentStoreDetailView: View {
    @Environment(AppState.self) private var app
    let doc: DocumentStore.DocumentRow
    @State private var showOriginal = false
    @State private var showIssueSheet = false

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
            if let path = originalPath {
                if doc.isSensitive {
                    // BR-007/008：敏感原图经 SensitiveMediaOriginalView——认证后
                    // 拉取字节、逐次解锁、退后台重锁、ImageIO 降采样（第四轮
                    // 全仓审查修复：原手写 sheet 全分辨率直显且无快照重锁）
                    SensitiveMediaOriginalView(imageData: nil, caption: L10n.docTitle(doc.title),
                                               originalLoader: { try? Data(contentsOf: URL(fileURLWithPath: path)) })   // try?-ok: 读取失败按「不可查看」降级
                } else {
                    // 非敏感原图也走 ImageIO 降采样（§5.10 大图 OOM 纪律）
                    NavigationStack {
                        // 裸修饰符位于 ViewBuilder 内 if 之后会以 View 类型为基解析
                        // 失败（CI 34037986523 实证）——Group 包裹后修饰符挂 Group 结果
                        Group {
                            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),   // try?-ok: 读取失败按「不可查看」降级
                               let image = ImageIOImageLoader.downsample(data: data, maxDimension: 2048) {
                                Image(uiImage: image)
                                    .resizable().scaledToFit()
                                    .padding(12)
                            }
                        }
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
        }
        .navigationTitle(L10n.docDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // FR6.7 报告识别问题（第四轮全仓审查修复：入口随旧详情页删除后
            // 全链路静默消失——reportRecognitionIssue 成为零调用死 API，
            // 用户无法反馈 OCR 错识；§5.53 表单随本页重建）
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showIssueSheet = true
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .accessibilityLabel(L10n.docReportIssue)
                .accessibilityIdentifier("SP-09.document.detail.reportIssue")
            }
        }
        .sheet(isPresented: $showIssueSheet) {
            ReportIssueSheet(documentId: doc.id, fields: []) { kind, fieldKey, note in
                app.reportRecognitionIssue(documentId: doc.id,
                                           meta: "kind=\(kind);field=\(fieldKey);note=\(note)")
            }
        }
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
        .frame(maxWidth: 672)   // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性）
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
                        // 第四轮全仓审查修复：原硬编码 "C"——已存在的 D 级未确认
                        // 文档在对比页被按已确认事实呈现（D 当事实渲染点）
                        grade: existing?.grade ?? "C")
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

/// §5.53 识别错误反馈表单（V3.72）：错误类型四分类 + 错误字段 + 备注；
/// 提交即落审计并 Toast 已记录（FR22.5 最小化：默认只附脱敏信息）。
/// 第四轮全仓审查修复：随旧 TimelineDocumentDetailView 删除的 FR6.7 入口
/// 重建于 SP-09 文档详情页——错误类型/字段/备注随 meta 落审计。
struct ReportIssueSheet: View {
    let documentId: UUID
    let fields: [CandidateField]
    let onSubmit: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "fieldWrong"
    @State private var fieldKey: String?
    @State private var note = ""
    @State private var submitted = false

    private let kinds = [
        ("fieldWrong", L10n.reportIssueFieldWrong),
        ("missingField", L10n.reportIssueMissing),
        ("layout", L10n.reportIssueLayout),
        ("engine", L10n.reportIssueEngine),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.reportIssueKind) {
                    Picker("", selection: $kind) {
                        ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                    .pickerStyle(.inline)
                }
                if !fields.isEmpty {
                    Section(L10n.reportIssueField) {
                        Picker("", selection: $fieldKey) {
                            Text(L10n.reportIssueFieldAll).tag(String?.none)
                            ForEach(fields) { f in
                                Text(f.displayLabel).tag(String?.some(f.key))
                            }
                        }
                    }
                }
                Section(L10n.reportIssueNote) {
                    TextField(L10n.reportIssueNoteHint, text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text(L10n.reportIssueMinimal)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.docReportIssue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.onboard_cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reportIssueSubmit) {
                        onSubmit(kind, fieldKey ?? "", note)
                        submitted = true
                    }
                }
            }
            .alert(L10n.reportIssueSubmitted, isPresented: $submitted) {
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            }
        }
    }
}
