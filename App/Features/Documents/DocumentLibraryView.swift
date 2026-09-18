import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Domain
import Infrastructure
import Protocols
import Perception

/// F5/F6: one retained import owns preparation, document review and every page card.
@MainActor
@Perceptible
final class DocumentsState {
    private(set) var documents: [DocumentStore.DocumentRow] = []
    private(set) var pendingDocuments: [DocumentStore.DocumentRow] = []
    private(set) var lastImportError: String?
    private(set) var pendingLoadError: String?
    private(set) var pendingVersion: UInt64 = 0
    private(set) var activeImport: ImportSession?
    private(set) var queuedImports: [QueuedImport] = []
    var pendingReviews: [String: PendingReview] = [:]
    /// 子项目 D · D4-2「资料建议」：卡确认保存成功后采集的 D 级建议批（非空即弹表单；`presenterKey` 决定由哪个宿主呈现）。
    /// 只经 `offerProfileSuggestions` / `acceptProfileSuggestion` / `dismissProfileSuggestions` / `clearProfileSuggestions` 变更。
    var profileSuggestionBatch: ProfileSuggestionBatch?

    private let store: DocumentStore
    let pendingCardStore: PendingCardStore?
    let cardStore: OCRCardStore?
    let suggestionStore: ProfileSuggestionStore?
    let scheduler: (any ReminderScheduling)?
    let dataChange: AppDataChangeCenter?
    private let pipeline: OCRPipeline
    private let decoder: any ImageDecoding
    private let ocrAuthorized: @MainActor () -> Bool
    private let aiAuthorization: @MainActor () -> (allowed: Bool, revision: UInt64)
    private let originalsDir: URL
    private let understandingEngine: any TextUnderstanding
    private let codeIndex: (any CodeIndex & UnitIndex)?
    private let problemStore: HealthProblemStore?
    private var loadingPatientId: UUID?
    private var lastIncludeArchived = false

    enum ImportOutcome: Equatable { case saved, deferred, cancelled }
    enum CaptureStep: Equatable { case camera, photos, file, region, occlusion, review }

    struct ImportSource {
        let documentId: UUID
        let patientId: UUID
        let pages: [PageAnalysis]
    }

    @MainActor @Perceptible
    final class ImportSession: Identifiable {
        let id = UUID()
        let patientId: UUID
        var draft: ImportDraft?
        var duplicate: PendingDocument?
        var duplicateHits: [DocumentStore.DocumentRow] = []
        fileprivate(set) var source: ImportSource?
        var cards: [MatchedCard] = []
        var selectedCardID: UUID?
        var cardOrder: [UUID] = []
        var totalCards = 0
        var preparedCards: [MatchedCard]?
        var committedCards: Set<UUID> = []
        var documentReviewFinished = false
        /// 共用信息步（业主 2026-09-17 定）是否已处理完；未处理完不得进入卡级（只能稍后处理）。
        var sharedFieldsSettled = false
        var isPreparing = false
        var isSaving = false
        var isBulkDeferring = false
        var errorMessage: String?
        var notificationError: String?
        var outcome: ImportOutcome?
        var hadDeferrals = false
        var presenterID: UUID?
        var healthProblemOfferHandled = false
        var captureOriginalData: Data?
        var captureProcessedData: Data?
        var captureStep: CaptureStep?
        var captureOrigin = "import"
        var captureSensitive = true
        /// v27（子项目 J）：文档稳定键随会话携带（`MatchedCard` 无该字段）——关联区据此裁决主卡草稿的枢纽与 kind
        ///（体检报告上的检验/检查 → 体检枢纽；急诊病历 → emergency）。commitDraft 时写入。
        var documentTypeKey: String?

        init(patientId: UUID) { self.patientId = patientId }
    }

    @MainActor @Perceptible
    final class PendingReview: Identifiable {
        let pending: PendingCard
        var id: String { pending.id }
        var card: MatchedCard
        var pageCount: Int
        var sharedCommitted: Bool
        var isSaving = false
        var errorMessage: String?
        var notificationError: String?
        var completed = false
        var writtenCount = 0

        init(pending: PendingCard, card: MatchedCard, pageCount: Int, sharedCommitted: Bool) {
            self.pending = pending; self.card = card
            self.pageCount = pageCount; self.sharedCommitted = sharedCommitted
        }
    }

    struct QueuedImport: Identifiable {
        enum Input { case file(URL), photo(PhotosPickerItem) }
        let id = UUID()
        let patientId: UUID
        let isSensitive: Bool
        let input: Input
    }

    /// 一张已确认卡产出的「资料建议」批（BR-003：D 级、逐项显式接受才落库；本结构不持久化）。
    struct ProfileSuggestionBatch: Identifiable, Equatable {
        let id = UUID()
        /// 呈现宿主键：`session-<导入会话 id>` / `pending-<待办卡 id>`——只由产出它的宿主呈现，避免双宿主同时弹表单。
        let presenterKey: String
        let cardId: UUID
        let patientId: UUID
        let documentId: UUID
        var suggestions: [ProfileSuggestion]
    }

    struct PendingDocument: Identifiable, Sendable {
        let id = UUID()
        let patientId: UUID
        let originalData: Data
        let processedData: Data
        let mimeType: String
        let docType: String?
        let title: String?
        let sha256: String
        let isSensitive: Bool
        let origin: String
    }

    @MainActor struct ImportDraft: Identifiable {
        let id = UUID()
        let patientId: UUID
        var docType: String
        var docTypeResolved = true
        var docTypeLowConfidence = false
        var docTypeManuallyChosen = false
        var documentTypeKey: String?
        var documentTypeCandidates: [String] = []
        var title: String?
        var isSensitive: Bool
        let origin: String
        let sha256: String
        let originalData: Data
        let processedData: Data
        let mimeType: String
        var qualityTags: [String]
        var pages: [PageAnalysis]
        var replaceDocumentId: UUID?
        var existingDocumentId: UUID?
        var retainedMeta: [String: Any] = [:]
        var previousCards: [MatchedCard] = []

        var isPrescription: Bool { docType == L10n.docTypePrescription }
        var allFields: [FieldDraft] { pages.flatMap(\.fields) }
        var allReviewed: Bool {
            // 审查修复：allSatisfy 对空集合恒真——0 页（损坏 PDF/非 OCR 路径）
            // 或 0 字段的导入被记「全部已确认」、以 C 级（用户确认事实）
            // 落库——来源造假（BR-003 来源语义）。零内容 ≠ 已审阅：
            // 页与字段都非空才算「有内容可审」，其余一律 D 级草稿。
            !pages.isEmpty
                && !allFields.isEmpty
                && pages.allSatisfy { $0.status == "ok" }
                && allFields.allSatisfy { $0.isConfirmed || $0.grade == .rejected }
        }
        var entityCards: [MatchedCard] {
            // H8 记忆化曾尝试 didSet 失效 + mutating get（CI 34656855831 访问
            // 级别错 / 34658068843 let 常量无法调用 mutating getter），class-box
            // 缓存又与值语义拷贝共享陈旧缓存——正确性优先，恢复纯计算：
            // 每次求值重跑 matchPages，成本有界（页数 ≤ 数十、模板匹配为
            // 常数级字段比较），审查轮5 已按「接受的演进项」登记。
            DocumentsState.reconcileCards(
                DocumentsState.matchPages(pages, manualTypeKey: docTypeManuallyChosen
                    ? (DocumentsState.docTypeKey(forLabel: docType) ?? documentTypeKey) : nil),
                previous: previousCards)
        }
    }

    private struct ReviewSnapshot: Codable {
        var pages: [PageAnalysis]
        var docType: String
        var docTypeResolved: Bool
        var docTypeManuallyChosen: Bool
        var documentTypeKey: String?
        var cards: [MatchedCard]
    }

    var documentStore: DocumentStore { store }
    var pendingDuplicate: PendingDocument? { activeImport?.duplicate }
    var duplicateHits: [DocumentStore.DocumentRow] { activeImport?.duplicateHits ?? [] }
    var entityQueue: [MatchedCard] { activeImport?.cards ?? [] }
    var entityQueueDocumentId: UUID? { activeImport?.source?.documentId }
    var entityQueuePatientId: UUID? { activeImport?.source?.patientId }
    var entityQueuePageTexts: [Int: String] {
        Dictionary(uniqueKeysWithValues: (activeImport?.source?.pages ?? []).map { ($0.index, $0.text) })
    }
    var entityQueueTotal: Int { activeImport?.totalCards ?? 0 }
    var canSkipForLater: Bool { pendingCardStore != nil }
    var importSlotFree: Bool { activeImport == nil }

    init(store: DocumentStore, pipeline: OCRPipeline,
         decoder: (any ImageDecoding)? = nil,
          ocrAuthorized: @escaping @MainActor () -> Bool = { true },
          aiAuthorization: @escaping @MainActor () -> (allowed: Bool, revision: UInt64) = { (false, 0) },
         originalsDir: URL? = nil, prescriptionStore: PrescriptionStore? = nil,
         prescriptionDocTypeLabel: String = L10n.docTypePrescription,
         understandingEngine: (any TextUnderstanding)? = nil,
         codeIndex: (any CodeIndex & UnitIndex)? = nil,
         problemStore: HealthProblemStore? = nil,
         dataChange: AppDataChangeCenter? = nil,
         pendingCards: PendingCardStore? = nil,
         scheduler: (any ReminderScheduling)? = nil, cardStore: OCRCardStore? = nil,
         suggestionStore: ProfileSuggestionStore? = nil) {
        self.store = store; self.pipeline = pipeline
        self.decoder = decoder ?? EngineRegistry.shared.resolve(ImageDecodingFactory.self)
        self.ocrAuthorized = ocrAuthorized
        self.aiAuthorization = aiAuthorization
        self.originalsDir = originalsDir ?? FileManager.default.temporaryDirectory
        self.understandingEngine = understandingEngine ?? EngineRegistry.shared.resolve(TextUnderstandingFactory.self)
        self.codeIndex = codeIndex; self.problemStore = problemStore
        self.dataChange = dataChange; self.pendingCardStore = pendingCards
        self.scheduler = scheduler; self.cardStore = cardStore
        self.suggestionStore = suggestionStore
    }

    @discardableResult
    func beginImport(patientId: UUID) -> ImportSession? {
        guard activeImport == nil else { return nil }
        let session = ImportSession(patientId: patientId)
        activeImport = session
        lastImportError = nil
        return session
    }

    private func preparationSession(patientId: UUID) -> ImportSession? {
        let session = activeImport ?? beginImport(patientId: patientId)
        guard let session, session.patientId == patientId, session.draft == nil,
              session.source == nil, session.duplicate == nil, !session.isPreparing,
              session.outcome == nil else { return nil }
        session.isPreparing = true
        session.errorMessage = nil
        lastImportError = nil
        return session
    }

    func cancelImport(sessionID: UUID) {
        guard let session = activeImport, session.id == sessionID,
              !session.isSaving, !session.isPreparing, session.source == nil else { return }
        session.outcome = .cancelled
    }

    /// Only a finished presenter's actual onDismiss releases the next batch item.
    @discardableResult
    func finishImportPresentation(sessionID: UUID) -> Bool {
        guard let session = activeImport, session.id == sessionID,
              session.outcome != nil, !session.isSaving, !session.isPreparing, !session.isBulkDeferring else { return false }
        activeImport = nil
        return true
    }

    func releaseImportPresenter(sessionID: UUID, presenterID: UUID) {
        guard let session = activeImport, session.id == sessionID,
              session.presenterID == presenterID else { return }
        session.presenterID = nil
    }

    func finishEntityQueueIfNeeded() {
        guard let session = activeImport, session.documentReviewFinished, session.cards.isEmpty else { return }
        session.outcome = session.hadDeferrals ? .deferred : .saved
    }

    @discardableResult
    // MARK: - 共用信息步（跨卡字段，业主 2026-09-17 定：确认流程改两步）

    /// 本会话需要在本步处理的共用字段（Domain 单一事实源 `SharedFieldPool.rows`）。
    /// 由「被 ≥2 张卡携带」∨「必填且低置信/缺失（多卡时）」决定；为空则本步不出现。
    func sharedFieldRows(for session: ImportSession) -> [SharedFieldPool.Row] {
        SharedFieldPool.rows(cards: session.cards)
    }

    /// 本步离场（继续）：把确认后的值回填给每个承载方，并标记完成——
    /// 卡级步骤因此不再复核这些字段（业主：不能进入卡级处理）。
    @discardableResult
    func settleSharedFields(_ rows: [SharedFieldPool.Row], sessionID: UUID) -> Bool {
        guard let session = activeImport, session.id == sessionID, !session.isSaving,
              SharedFieldPool.isSettled(rows) else { return false }
        session.cards = SharedFieldPool.project(rows, into: session.cards)
        session.sharedFieldsSettled = true
        return true
    }

    /// 本步的「稍后处理」：先回填（用户的修正是成果，不能丢）再整批落待办——
    /// 复用既有延后路径，不新增持久化语义。
    func deferFromSharedFields(_ rows: [SharedFieldPool.Row], sessionID: UUID) async -> Bool {
        guard applySharedFieldsWithoutGate(rows, sessionID: sessionID) else { return false }
        return await deferRemainingEntityCards()
    }

    /// 未处理完也照常回填（延后场景）：闸门只挡「进入卡级」，不挡「落待办」。
    @discardableResult
    private func applySharedFieldsWithoutGate(_ rows: [SharedFieldPool.Row], sessionID: UUID) -> Bool {
        guard let session = activeImport, session.id == sessionID, !session.isSaving else { return false }
        session.cards = SharedFieldPool.project(rows, into: session.cards)
        return true
    }

    func updateEntityCard(_ card: MatchedCard) -> Bool {
        guard let session = activeImport, !session.isSaving, !session.isBulkDeferring,
              let index = session.cards.firstIndex(where: { $0.id == card.id }),
              session.cards[index].pageIndex == card.pageIndex,
              session.cards[index].kind == card.kind else { return false }
        session.cards[index] = card
        return true
    }

    func dequeueEntityCard(_ card: MatchedCard) {
        guard let session = activeImport, let index = session.cards.firstIndex(where: { $0.id == card.id }) else { return }
        session.cards.remove(at: index)
        if session.selectedCardID == card.id {
            session.selectedCardID = session.cards.isEmpty ? nil : session.cards[min(index, session.cards.count - 1)].id
        }
        finishEntityQueueIfNeeded()
    }

    func selectEntityCard(_ id: UUID) {
        guard let session = activeImport, !session.isSaving, !session.isBulkDeferring,
              session.cards.contains(where: { $0.id == id }) else { return }
        session.selectedCardID = id
    }

    func setImportError(_ message: String?) { lastImportError = message }

    func pendingDidChange() {
        pendingVersion &+= 1
        dataChange?.documentSaved()
    }

    func enqueueFiles(_ urls: [URL], patientId: UUID) {
        queuedImports += urls.map { QueuedImport(patientId: patientId, isSensitive: true, input: .file($0)) }
        processNextImport()
    }

    func enqueuePhotos(_ items: [PhotosPickerItem], patientId: UUID) {
        queuedImports += items.map { QueuedImport(patientId: patientId, isSensitive: true, input: .photo($0)) }
        processNextImport()
    }

    func processNextImport() {
        guard activeImport == nil, !queuedImports.isEmpty else { return }
        let input = queuedImports.removeFirst()
        guard let session = beginImport(patientId: input.patientId) else { return }
        Task {
            do {
                switch input.input {
                case .file(let url):
                    // Both PDF and image callers consume the same returned draft.
                    session.draft = await importDocument(patientId: input.patientId, url: url,
                                                        docType: nil, isSensitive: input.isSensitive)
                case .photo(let item):
                    session.isPreparing = true
                    let data = try await item.loadTransferable(type: Data.self)
                    session.isPreparing = false
                    guard let data else { throw ImportError.unreadableMedia }
                    session.draft = await prepareImageDraft(patientId: input.patientId, originalData: data,
                        processedData: data, mimeType: ImageInputRules.sniffMimeType(of: data),
                        docType: nil, title: nil, isSensitive: input.isSensitive, origin: "photoLibrary")
                }
            } catch {
                session.isPreparing = false
                session.errorMessage = L10n.docImportFailed
                lastImportError = session.errorMessage
            }
        }
    }

    func load(patientId: UUID, includeArchived: Bool = false) async {
        // BR-001 成员隔离（同族修复，TimelineViewState 同款）：**换成员立即
        // 清屏**——失败或取消时旧成员的文档列表（含敏感文档标题）不得在
        // 新成员名下渲染。同一成员重载失败保留旧列表（假空态 doctrine）。
        if loadingPatientId != patientId {
            loadingPatientId = patientId
            documents = []
        }
        lastIncludeArchived = includeArchived
        do {
            let rows = try await store.list(patientId: patientId, includeArchived: includeArchived)
            guard loadingPatientId == patientId else { return }
            documents = rows
            lastImportError = nil
        } catch {
            guard loadingPatientId == patientId else { return }
            lastImportError = L10n.docImportFailed
        }
    }

    func loadPending(patientIds: [UUID]) async {
        pendingLoadError = nil
        do { pendingDocuments = try await store.listPending(patientIds: patientIds) }
        catch { pendingLoadError = L10n.docImportFailed }
    }

    func fetch(id: UUID) async -> DocumentStore.DocumentRow? {
        do { return try await store.fetch(id: id) }
        catch { lastImportError = L10n.docImportFailed; return nil }
    }

    func setArchived(id: UUID, archived: Bool) async {
        do {
            try await store.setArchived(id: id, archived: archived)
            if let patient = loadingPatientId { await load(patientId: patient, includeArchived: lastIncludeArchived) }
        } catch { lastImportError = L10n.docImportFailed }
    }

    func setFavorite(id: UUID, favorite: Bool) async {
        do {
            try await store.setFavorite(id: id, favorite: favorite)
            if let patient = loadingPatientId { await load(patientId: patient, includeArchived: lastIncludeArchived) }
        } catch { lastImportError = L10n.docImportFailed }
    }

    private func persistOriginal(patientId: UUID, data: Data, ext: String) throws -> String {
        guard !data.isEmpty else { throw ImportError.unreadableMedia }
        let directory = originalsDir.appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(patientId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    func prepareImageDraft(patientId: UUID, originalData: Data, processedData: Data, mimeType: String,
                           docType: String?, title: String?, isSensitive: Bool = true,
                           origin: String = "import") async -> ImportDraft? {
        guard let session = preparationSession(patientId: patientId) else { return nil }
        defer { session.isPreparing = false }
        let pending = PendingDocument(patientId: patientId, originalData: originalData, processedData: processedData,
            mimeType: mimeType, docType: docType, title: title, sha256: "sha:" + Self.hash(processedData),
            isSensitive: isSensitive, origin: origin)
        return await prepare(pending, in: session, checkDuplicates: true)
    }

    func importDocument(patientId: UUID, url: URL, docType: String?, isSensitive: Bool = true) async -> ImportDraft? {
        if url.pathExtension.lowercased() == "pdf" {
            return await importPDF(patientId: patientId, url: url, docType: docType, isSensitive: isSensitive)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if ImageInputRules.supports(pathExtension: url.pathExtension) {
                return await prepareImageDraft(patientId: patientId, originalData: data, processedData: data,
                    mimeType: ImageInputRules.sniffMimeType(of: data), docType: docType,
                    title: url.lastPathComponent, isSensitive: isSensitive)
            }
            // Non-OCR files retain the original and still require metadata review.
            guard let session = preparationSession(patientId: patientId) else { return nil }
            defer { session.isPreparing = false }
            let pending = PendingDocument(patientId: patientId, originalData: data, processedData: data,
                mimeType: url.pathExtension.lowercased(), docType: docType, title: url.lastPathComponent,
                sha256: "file:" + Self.hash(data), isSensitive: isSensitive, origin: "import")
            let draft = assembleDraft(pending, pages: [], qualityTags: [])
            session.draft = draft
            return draft
        } catch {
            lastImportError = L10n.docImportFailed
            activeImport?.errorMessage = lastImportError
            return nil
        }
    }

    func importPDF(patientId: UUID, url: URL, docType: String?, isSensitive: Bool = true) async -> ImportDraft? {
        guard let session = preparationSession(patientId: patientId) else { return nil }
        defer { session.isPreparing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let pending = PendingDocument(patientId: patientId, originalData: data, processedData: data,
                mimeType: "application/pdf", docType: docType, title: url.lastPathComponent,
                sha256: "pdf:" + Self.hash(data), isSensitive: isSensitive, origin: "import")
            return await prepare(pending, in: session, checkDuplicates: true)
        } catch {
            session.errorMessage = L10n.docPDFImportFailed; lastImportError = session.errorMessage
            return nil
        }
    }

    private func prepare(_ input: PendingDocument, in session: ImportSession, checkDuplicates: Bool) async -> ImportDraft? {
        do {
            if checkDuplicates {
                let hits = try await store.duplicates(sha256: input.sha256, patientId: input.patientId)
                if !hits.isEmpty {
                    session.duplicateHits = hits.sorted { first, second in
                        let firstActive = ["active", "favorite"].contains(first.status)
                        let secondActive = ["active", "favorite"].contains(second.status)
                        if firstActive != secondActive { return firstActive }
                        if first.createdAt != second.createdAt { return first.createdAt > second.createdAt }
                        return first.id.uuidString < second.id.uuidString
                    }
                    session.duplicate = input
                    return nil
                }
            }
            var pages: [PageAnalysis] = []
            var tags: [String] = []
            if input.mimeType == "application/pdf" {
                let count = try DocumentSourceRenderer.pageCount(data: input.originalData, mimeType: input.mimeType)
                // The decoder's existing 50-page bound is explicit: all later indexes remain skipped.
                let limit = min(count, 50)
                let results = PDFAnalyses()
                if ocrAuthorized() {
                    do {
                        try await decoder.decodePDFPages(input.originalData, scale: 2, maxPages: limit) { page in
                            let analysis = await self.analyze(imageData: page.bitmapData, index: page.pageIndex, hint: input.docType)
                            await results.append(analysis)
                        }
                    } catch {
                        // Previously rendered pages survive a later render failure.
                    }
                }
                let recognized = await results.pages
                let byIndex = Dictionary(recognized.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
                pages = (0..<count).map { index in
                    byIndex[index] ?? PageAnalysis(index: index, lines: [],
                        status: !ocrAuthorized() || index >= limit ? "skipped" : "failed", fields: [])
                }
            } else {
                let page = await analyze(imageData: input.processedData, index: 0, hint: input.docType)
                pages = [page]
                tags = page.qualityTags
            }
            let draft = assembleDraft(input, pages: pages, qualityTags: tags)
            session.draft = draft
            return draft
        } catch {
            session.errorMessage = L10n.docImportFailed; lastImportError = session.errorMessage
            return nil
        }
    }

    private actor PDFAnalyses {
        var pages: [PageAnalysis] = []
        func append(_ page: PageAnalysis) { pages.append(page) }
    }

    private func analyze(imageData: Data, index: Int, hint: String?) async -> PageAnalysis {
        guard ocrAuthorized() else { return .init(index: index, lines: [], status: "skipped", fields: []) }
        do {
            let result = try await pipeline.run(imageData: imageData)
            guard !result.failed else { return .init(index: index, lines: result.lines, status: "failed", fields: []) }
            let authorization = aiAuthorization()
            let input = TextUnderstandingInput(text: result.lines.joined(separator: "\n"), lines: result.lines,
                source: .ocr(documentTypeHint: hint), allowsGenerativeProcessing: authorization.allowed)
            var understanding = try await understandingEngine.understand(input)
            let confidence = result.confidence.isFinite ? min(1, max(0, result.confidence)) : 0
            var fields = Self.extractPageFields(lines: result.lines, understood: understanding.fields,
                                                confidence: confidence)
            // 审查修复（撤销清洗 + 无重复 NL）：只在「理解期间授权被撤回/代际
            // 变化且字段含生成轨产出」时重跑——以无生成授权重跑**注入引擎**
            // （FallbackTextUnderstanding 的门控自然切到 NL 轨；不再直接构造
            // 具体实现，测试可注入桩）。授权本就关闭时首跑即 NL，条件不成立、
            // 零额外开销（旧实现每页无条件重跑 NL 一遍并丢弃结果，双倍成本）。
            let authorizationChanged = authorization.revision != aiAuthorization().revision || !aiAuthorization().allowed
            if authorizationChanged, fields.contains(where: { $0.source == .foundationModels }) {
                var gated = input
                gated.allowsGenerativeProcessing = false
                understanding = try await understandingEngine.understand(gated)
                fields = Self.extractPageFields(lines: result.lines, understood: understanding.fields, confidence: confidence)
            }
            if let codeIndex {
                fields = await UnderstandingCodeResolution.resolve(fields, locale: Locale(identifier: "zh_Hans"),
                                                                     index: codeIndex, units: codeIndex)
            }
            guard ocrAuthorized(), !Task.isCancelled else { return .init(index: index, lines: result.lines, status: "skipped", fields: []) }
            return .init(index: index, lines: result.lines, fields: fields,
                         documentTypeKey: understanding.suggestedTarget, confidence: confidence,
                         qualityTags: result.qualityTags, typeConfidence: understanding.targetConfidence)
        } catch {
            return .init(index: index, lines: [], status: "failed", fields: [])
        }
    }

    private func assembleDraft(_ input: PendingDocument, pages: [PageAnalysis], qualityTags: [String]) -> ImportDraft {
        let keys = pages.compactMap(\.documentTypeKey)
        let first = keys.first
        let label = input.docType ?? first.flatMap(Self.docTypeLabel(forStableKey:))
        var draft = ImportDraft(patientId: input.patientId, docType: label ?? Self.unresolvedDocTypePlaceholder,
            title: input.title, isSensitive: input.isSensitive, origin: input.origin, sha256: input.sha256,
            originalData: input.originalData, processedData: input.processedData, mimeType: input.mimeType,
            qualityTags: qualityTags, pages: pages)
        draft.docTypeResolved = label != nil
        draft.documentTypeKey = first
        draft.docTypeLowConfidence = pages.contains { ($0.typeConfidence ?? 0) < 0.75 && !$0.fields.isEmpty }
        var seen = Set<String>()
        draft.documentTypeCandidates = keys.compactMap(Self.docTypeLabel(forStableKey:)).filter { seen.insert($0).inserted }
        draft.previousCards = Self.matchPages(pages, manualTypeKey: nil)
        return draft
    }

    enum DuplicateResolution { case keep, coexist, replace }

    func resolveDuplicate(_ resolution: DuplicateResolution) async -> ImportDraft? {
        guard let session = activeImport, let pending = session.duplicate, !session.isPreparing else { return nil }
        if resolution == .keep {
            session.duplicate = nil; session.duplicateHits = []; session.outcome = .cancelled
            return nil
        }
        session.isPreparing = true
        defer { session.isPreparing = false }
        let replaceID = resolution == .replace ? session.duplicateHits.first?.id : nil
        let sensitive = pending.isSensitive || session.duplicateHits.contains(where: \.isSensitive)
        let input = PendingDocument(patientId: pending.patientId, originalData: pending.originalData,
            processedData: pending.processedData, mimeType: pending.mimeType, docType: pending.docType,
            title: pending.title, sha256: pending.sha256, isSensitive: sensitive, origin: pending.origin)
        guard var draft = await prepare(input, in: session, checkDuplicates: false) else { return nil }
        draft.replaceDocumentId = replaceID
        session.draft = draft
        session.duplicate = nil; session.duplicateHits = []
        return draft
    }

    @discardableResult
    func commitDraft(_ draft: ImportDraft) async -> Bool {
        let session = activeImport ?? beginImport(patientId: draft.patientId)
        guard let session, session.patientId == draft.patientId, !session.isSaving,
              session.draft == nil || session.draft?.id == draft.id,
              !session.documentReviewFinished, draft.docTypeResolved else { return false }
        session.draft = draft
        // 稳定键：用户手选优先（标签反查），否则页判定；供关联区裁决主卡草稿（hub(for:documentTypeKey:)）
        session.documentTypeKey = (draft.docTypeManuallyChosen ? Self.docTypeKey(forLabel: draft.docType) : nil) ?? draft.documentTypeKey
        session.isSaving = true; session.errorMessage = nil; lastImportError = nil
        defer { session.isSaving = false }
        do {
            if session.source == nil {
                var meta = draft.retainedMeta
                if meta["original_path"] == nil {
                    let ext = draft.mimeType == "application/pdf" ? "pdf"
                        : ["doc", "docx"].contains(draft.mimeType) ? draft.mimeType : ImageInputRules.fileExtension(for: draft.mimeType)
                    meta["original_path"] = try persistOriginal(patientId: draft.patientId, data: draft.originalData, ext: ext)
                    session.draft?.retainedMeta = meta
                }
                if meta["processed_path"] == nil {
                    meta["processed_path"] = draft.originalData == draft.processedData ? meta["original_path"]
                        : try persistOriginal(patientId: draft.patientId, data: draft.processedData, ext: "jpg")
                }
                // Retain successful media writes across retries, including a later DB failure.
                session.draft?.retainedMeta = meta
                let review = try await cardsForCommit(draft)
                session.preparedCards = review.queue
                let snapshot = ReviewSnapshot(pages: draft.pages, docType: draft.docType,
                    docTypeResolved: draft.docTypeResolved, docTypeManuallyChosen: draft.docTypeManuallyChosen,
                    documentTypeKey: draft.documentTypeKey, cards: review.all)
                meta["ocr_review"] = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
                let json = String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self)
                let text = draft.allFields.filter(\.isConfirmed).map { field in
                    [field.value, field.unit].compactMap { $0 }.joined(separator: " ")
                }.joined(separator: "\n")
                let pages = draft.pages.map { DocumentStore.Page(index: $0.index,
                    text: $0.status == "ok" ? $0.text : nil, status: $0.status) }
                let reviewedFields = Dictionary(uniqueKeysWithValues: draft.pages.filter { $0.status == "ok" }.map { page in
                    (page.index, page.fields.filter(\.isConfirmed).map { field in
                        CandidateField(key: field.key, displayLabel: Self.fieldLabel(forKey: field.key),
                            rawText: field.rawText ?? field.originalValue, confidence: field.confidence, value: field.value,
                            grade: .userConfirmed, codeResolution: field.codeResolution, revisionHistory: field.revisionHistory)
                    })
                })
                // v27：稳定键随标签同事务落 doc_type_key（新行不进首启回填清单；复核改类型时键随标签走，不漂移）
                let persistedKey = Self.persistedDocTypeKey(label: draft.docType, classifierKey: draft.documentTypeKey).rawValue
                let documentID: UUID
                if let existing = draft.existingDocumentId {
                    try await store.updateReview(id: existing, patientId: draft.patientId, docType: draft.docType,
                        isSensitive: draft.isSensitive, metaJSON: json, ocrText: text.isEmpty ? nil : text,
                        grade: draft.allReviewed ? "C" : "D", pages: pages, cards: review.all, reviewedFields: reviewedFields,
                        docTypeKey: persistedKey)
                    documentID = existing
                } else {
                    documentID = try await store.save(patientId: draft.patientId, docType: draft.docType,
                        sha256: draft.sha256, mimeType: draft.mimeType, origin: draft.origin,
                        isSensitive: draft.isSensitive, metaJSON: json, title: draft.title,
                        ocrText: text.isEmpty ? nil : text, grade: draft.allReviewed ? "C" : "D", pages: pages,
                        cards: review.all, reviewedFields: reviewedFields, docTypeKey: persistedKey)
                }
                session.source = ImportSource(documentId: documentID, patientId: draft.patientId, pages: draft.pages)
            }
            guard session.source != nil else { throw ImportError.unreadableMedia }
            let cards = session.preparedCards ?? []
            if let replace = draft.replaceDocumentId {
                try await store.setArchived(id: replace, archived: true)
            }
            session.cards = cards; session.totalCards = cards.count
            session.cardOrder = cards.map(\.id)
            session.selectedCardID = cards.first?.id
            session.documentReviewFinished = true
            pendingDidChange()
            if loadingPatientId == draft.patientId || loadingPatientId == nil {
                await load(patientId: draft.patientId, includeArchived: lastIncludeArchived)
            }
            finishEntityQueueIfNeeded()
            return true
        } catch {
            session.errorMessage = L10n.docImportFailed; lastImportError = session.errorMessage
            return false
        }
    }

    private func cardsForCommit(_ draft: ImportDraft) async throws -> (all: [MatchedCard], queue: [MatchedCard]) {
        var cards = draft.entityCards
        if !cards.isEmpty, pendingCardStore == nil || cardStore == nil { throw ImportError.storeUnavailable }
        guard let documentID = draft.existingDocumentId else { return (cards, cards) }
        guard let cardStore else { throw ImportError.storeUnavailable }
        // Retain completed identities in the recovery snapshot even though they no longer appear in the queue.
        cards += draft.previousCards.filter { old in !cards.contains { $0.id == old.id } }
        var pagesEdited = false
        if let json = draft.retainedMeta["ocr_review"] as? String {
            let previous = try JSONDecoder().decode(ReviewSnapshot.self, from: Data(json.utf8))
            pagesEdited = draft.pages.count != previous.pages.count || zip(draft.pages, previous.pages).contains { current, old in
                current.index != old.index || current.fields.count != old.fields.count || zip(current.fields, old.fields).contains { a, b in
                    a.key != b.key || a.value != b.value || a.unit != b.unit || (a.grade == .rejected) != (b.grade == .rejected)
                }
            }
        }
        var canonical: [MatchedCard] = []
        var unfinished: [MatchedCard] = []
        // 审查修正（效率）：N 张卡串行 await reviewState = N 次串行 actor 往返 +
        // DB 读（30 项检验报告确认前数秒等待）；改为任务组并发读取（只读投影，
        // 无共享可变状态），结果按原序折回——reviewConflict 判定顺序语义不变。
        let states = try await withThrowingTaskGroup(of: (Int, OCRCardStore.ReviewState).self) { group in
            for (index, card) in cards.enumerated() {
                group.addTask { @Sendable in
                    (index, try await cardStore.reviewState(card: card, patientId: draft.patientId, documentId: documentID))
                }
            }
            var collected: [Int: OCRCardStore.ReviewState] = [:]
            for try await (index, state) in group { collected[index] = state }
            return (0..<cards.count).compactMap { collected[$0] }
        }
        for (card, state) in zip(cards, states) {
            if pagesEdited, state.card != card {
                // Concurrent edits must be resolved in the existing card, never overwritten by old document text.
                throw DocumentStore.StoreError.reviewConflict
            }
            canonical.append(state.card)
            if state.hasCommittedRows { activeImport?.committedCards.insert(card.id) }
            if let remaining = state.remaining { unfinished.append(remaining) }
        }
        return (canonical, unfinished)
    }

    func deferImportDraft(_ draft: ImportDraft) async -> Bool {
        guard await commitDraft(draft) else { return false }
        activeImport?.hadDeferrals = true
        if entityQueue.isEmpty {
            activeImport?.outcome = .deferred
            return true
        }
        return await deferRemainingEntityCards()
    }

    /// Legacy confirmation opens the retained media/review snapshot; it never flips a grade blindly.
    func prepareStoredDocument(id: UUID, patientId: UUID) async -> ImportDraft? {
        guard let session = preparationSession(patientId: patientId) else { return nil }
        defer { session.isPreparing = false }
        do {
            guard let document = try await store.fetch(id: id), document.patientId == patientId,
                  ["active", "favorite"].contains(document.status), let json = document.metaJSON,
                  let meta = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let original = meta["original_path"] as? String else { throw ImportError.unreadableMedia }
            let originalData = try Data(contentsOf: URL(fileURLWithPath: original))
            let processed = meta["processed_path"] as? String ?? original
            let processedData = try Data(contentsOf: URL(fileURLWithPath: processed))
            let input = PendingDocument(patientId: patientId, originalData: originalData, processedData: processedData,
                mimeType: document.mimeType ?? ImageInputRules.sniffMimeType(of: originalData), docType: document.docType,
                title: document.title, sha256: document.sha256 ?? "sha:" + Self.hash(processedData),
                isSensitive: document.isSensitive, origin: document.origin)
            var draft: ImportDraft
            if let snapshotJSON = meta["ocr_review"] as? String {
                let snapshot = try JSONDecoder().decode(ReviewSnapshot.self, from: Data(snapshotJSON.utf8))
                draft = assembleDraft(input, pages: snapshot.pages, qualityTags: [])
                draft.docType = snapshot.docType; draft.docTypeResolved = snapshot.docTypeResolved
                draft.docTypeManuallyChosen = snapshot.docTypeManuallyChosen
                draft.documentTypeKey = snapshot.documentTypeKey
                draft.previousCards = snapshot.cards
            } else {
                guard let prepared = await prepare(input, in: session, checkDuplicates: false) else { return nil }
                draft = prepared
            }
            draft.existingDocumentId = id
            draft.retainedMeta = meta
            session.draft = draft
            return draft
        } catch {
            session.errorMessage = L10n.sensitiveMedia_loadFailed; lastImportError = session.errorMessage
            return nil
        }
    }

    /// 临床类文档判定：以 Domain 稳定键谓词为唯一事实源（FR6.9 健康问题推荐门控），
    /// 旧数据无稳定键时回落到标签相等（与 Domain 判定集合一致的标签子集）。
    nonisolated func isClinicalDocType(key: String?, label: String) -> Bool {
        if let key { return DocumentTypeClassifierFallback.isClinicalType(key) }
        return label == L10n.docTypeReport || label == L10n.docTypeRecord
            || label == L10n.docTypeLabelDiagnosisProof
    }

    func createHealthProblem(patientId: UUID, name: String) async -> Bool {
        guard let problemStore else { return false }
        do { _ = try await problemStore.create(patientId: patientId, name: name); return true }
        catch { return false }
    }

    func createManual(patientId: UUID, title: String, docType: String, note: String) async {
        do {
            let json = String(decoding: try JSONEncoder().encode(["note": note]), as: UTF8.self)
            // v27：手工建档 Picker 选的是 27 键标签 → 反查稳定键同行落库（无页判定；未命中 custom）
            _ = try await store.save(patientId: patientId, docType: docType, sha256: nil, mimeType: nil,
                                    origin: "manual", isSensitive: false, metaJSON: json, title: title,
                                    docTypeKey: Self.persistedDocTypeKey(label: docType, classifierKey: nil).rawValue)
            await load(patientId: patientId)
            dataChange?.documentSaved()
        } catch { lastImportError = L10n.docImportFailed }
    }

    /// FR5.5 文档类型稳定键 → 当前语言标签（v27 / 原 D3-2：`DocumentTypeKey` 全 27 键经 `L10n.docTypeName`；
    /// 未知键 nil）。`document_file.doc_type` 仍写标签（既有列语义），稳定键另落 `doc_type_key`。
    nonisolated static func docTypeLabel(forStableKey key: String) -> String? {
        guard let type = DocumentTypeKey(rawValue: key) else { return nil }
        return L10n.docTypeName(type)
    }

    nonisolated static var unresolvedDocTypePlaceholder: String { L10n.docTypeLabelOther }

    /// 标签 → 稳定键：先按当前语言的 27 键标签精确反查，再回落旧 15 标签键 / 曾用键（`DocumentTypeKey(legacyLabelKey:)`）。
    /// 解析与（语言, 标签）缓存在 L10n 单出口（列表行 / 卡投影每帧反查，旧标签的三语扫描不重复付费）。
    nonisolated static func docTypeKey(forLabel label: String) -> String? {
        L10n.docTypeKey(forLabel: label)
    }

    /// v27 落库稳定键（`document_file.doc_type_key`，J4 follow-up）：已确认标签反查（当前语言 27 键 → 旧 15 标签键 /
    /// 曾用键三语）→ 页判定稳定键（理解层 `suggestedTarget`）→ `custom`（不猜）。标签优先：确认页展示并经
    /// `docTypeResolved` 闸门要求用户确认的是标签，页判定只是其来源之一（QuickCapture 提示标签与页判定不一致时以标签为准）。
    nonisolated static func persistedDocTypeKey(label: String, classifierKey: String?) -> DocumentTypeKey {
        if let raw = docTypeKey(forLabel: label), let key = DocumentTypeKey(rawValue: raw) { return key }
        if let raw = classifierKey, let key = DocumentTypeKey(rawValue: raw) { return key }
        return DocumentTypeKeyBackfill.resolve(label: label)
    }

    /// 导入确认页 / 手工建档 Picker 的类型目录（稳定键，标签经 `docTypeLabel(forStableKey:)`）：
    /// 仅附件类排在最后，`custom` 收尾。
    nonisolated static var docTypeKeyOptions: [String] {
        let all = DocumentTypeKey.allCases
        return (all.filter { !$0.attachmentOnly && $0 != .other && $0 != .custom }
                + all.filter(\.attachmentOnly) + [.other, .custom]).map(\.rawValue)
    }
    /// 同上目录的当前语言标签（Picker 选项以标签呈现、选中即经 `docTypeKey(forLabel:)` 回稳定键）。
    nonisolated static var docTypeLabelOptions: [String] {
        docTypeKeyOptions.compactMap(docTypeLabel(forStableKey:))
    }

    nonisolated static func fieldLabel(forKey key: String) -> String {
        switch key {
        case "dept": return L10n.ocFieldDept
        case "report_date", "prescribed_at": return L10n.ocFieldReportDate
        case "reference_range": return L10n.ocFieldReferenceRange
        case "lab_item": return L10n.ocFieldLabItem
        case "chief_complaint": return L10n.ocFieldChiefComplaint
        case "diagnosis": return L10n.ocFieldDiagnosis
        case "treatment": return L10n.ocFieldTreatment
        case "drug_name": return L10n.prescriptionFieldDrugName
        case "hospital": return L10n.prescriptionFieldHospital
        case "doctor": return L10n.prescriptionFieldDoctor
        default:
            if key.hasPrefix("line_"), let index = Int(key.dropFirst(5)) { return L10n.entityCardRowIndex(index + 1) }
            if key.hasPrefix("rx_line_"), let index = Int(key.dropFirst(8)) { return L10n.entityCardRowIndex(index + 1) }
            return L10n.templateFieldLabel(key)
        }
    }

    /// FR6.9 字段值**展示层映射**（discussions/2026-09-12-owner-round10-issues.md §3a）：
    /// 数据层保持 canonical raw（如 `EncounterKind.outpatient`、`unit_kind=tablet`），
    /// 展示层按当前语言呈现；用户实测「信息卡出现 outpatient」的根因就是 raw 值直出。
    /// 所有字段值渲染面（确认卡/待办续确认/已确认卡详情/首页待办卡/库存/图片确认卡）
    /// 必须经此函数。编辑态 TextField 仍显示并回写 canonical raw（编辑框即数据
    /// 真值、展示文案永不写回数据）——把展示文案映射进编辑框会让半程编辑
    /// 把本地化片段写进 raw 槽位（round10 max 审查结论，保持原设计）。
    /// 时间轴行**标题**的展示出口（2026-09-17 业主实测复发：就诊类型显示 `outpatient`）。
    ///
    /// **根因**：`TimelineQueryStore` 的就诊/住院行是 `SELECT … e.kind AS title`——`title`
    /// **就是** `kind` canonical raw。V3.71 那次修复只把**主卡行**接到了 `fieldValueDisplay`，
    /// 子卡行与平铺叶子行仍直出 `entry.title` → 英文 raw 上屏。
    ///
    /// 本函数收口三处渲染面（主卡行继续保持原调用，子卡行与叶子行改经此处），
    /// 使「同一 kind raw 在任何时间轴行上都按当前语言呈现」只有一处实现。
    nonisolated static func timelineEntryTitle(_ entry: TimelineEntry) -> String {
        switch entry.kind {
        // ── title 是 **canonical raw** 的行类：必须映射，否则英文 raw 上屏 ──
        // 依据：`TimelineQueryStore` 的 SQL 别名（逐条可查）——
        //   :44  `kind AS title`（就诊平铺）  :214 `e.kind AS title`（就诊主卡）
        //   :326 住院 `hospitalization` 行的 title 是文本（医院名）→ 不在本组
        //   :60  `kind AS title`（观察）
        //   :334 `f.metric_key AS title`（医院检验点）
        //   :335 `report_type AS title`（检查报告）
        case .encounter, .hospitalization:
            return fieldValueDisplay(forKey: "kind", value: entry.title)
        case .observation:
            // title = `ObservationKind` raw（stool/urine/skin/eye/…）；全仓其余渲染面
            // 均经 `L10n.observationKindName`，唯时间轴行此前直出。
            return ObservationKind(rawValue: entry.title).map(L10n.observationKindName) ?? entry.title
        case .examReport:
            // title = `report_type` canonical raw（pathology/imaging/…）
            return fieldValueDisplay(forKey: "report_type", value: entry.title)
        case .lab, .selfMeasured, .healthData:
            // title = `metric_key`（`lab.*` canonical）→ 本地化指标名
            if let metric = entry.metricKey.flatMap({ MetricType(grammarKey: $0) }) ?? MetricType(grammarKey: entry.title) {
                return L10n.metricName(metric)
            }
            return entry.title
        // ── title 是「已被上层处理过或本就是文本」的行类 ──
        // 说明：住院行（:326）title = 医院名；处方行（:328）title = 首行药名或其他文本；
        // 检验表头行（:330）title = 检验类别/实验室/医院文本——三者均为原文，不映射。
        case .clinicalConclusion:
            return L10n.timelineHubConclusions(Int(entry.title) ?? 0)
        case .treatmentRecord:
            return L10n.treatmentTypeName(entry.title)
        case .document:
            return entry.title.isEmpty ? L10n.timelineKindName(.document) : entry.title
        default:
            return entry.title.isEmpty ? L10n.timelineKindName(entry.kind) : entry.title
        }
    }

    nonisolated static func fieldValueDisplay(forKey key: String, value: String) -> String {
        switch key {
        case "kind":
            return EncounterKind(rawValue: value).map(L10n.encounterKindName) ?? value
        case "doc_type", "document_type":
            return docTypeLabel(forStableKey: value) ?? value
        case "item_type":
            switch value {
            case "invoice": return L10n.claim_type_invoice
            case "fee": return L10n.claim_type_fee
            case "receipt": return L10n.claim_type_receipt
            default: return value
            }
        case "unit_kind":
            return ["tablet", "capsule", "patch", "vial"].contains(value) ? L10n.lotUnitName(value) : value
        case "currency":
            return value == "CNY" ? L10n.currencyCNY : value
        case "prescription_type":
            return L10n.prescriptionTypeName(value)
        // v26（§C.3 / §C.4）：诊断类型 / 检查报告类型 canonical raw → 展示名（未登记原样透传）
        case "diagnosis_type":
            return L10n.diagnosisTypeName(value)
        case "report_type":
            return L10n.examReportTypeName(value)
        // v27（子项目 J）：治疗类型 / 结论类型 / 预约目的 / 文档稳定键 canonical raw → 展示名（未登记原样透传）。
        // `severity`（结论程度）**不在此列**：打印原文直出，不映射不着色（BR-004/012）。
        case "treatment_type":
            return L10n.treatmentTypeName(value)
        case "conclusion_type":
            return L10n.conclusionTypeName(value)
        case "purpose":
            return L10n.appointmentPurposeName(value)
        case "doc_type_key":
            return docTypeLabel(forStableKey: value) ?? value
        default:
            return value
        }
    }

    /// 枚举槽位的 canonical 值目录（SP-12 确认卡 Picker 选项；标签经 `fieldValueDisplay`）。
    /// 与 `EntityCardProjection.invalidFields` 的枚举校验同拼写；nil = 自由文本字段（走 TextField）。
    /// 处方类型按 Domain `prescriptionTypes` 过滤保序（Domain 增删枚举不会让 Picker 出现非法项）。
    nonisolated static func enumOptions(forKey key: String) -> [String]? {
        switch key {
        case "kind": return EncounterKind.allCases.map(\.rawValue)
        case "item_type": return ["invoice", "fee", "receipt"]
        case "unit_kind": return ["tablet", "capsule", "patch", "vial"]
        case "currency": return ["CNY", "HKD", "MOP", "TWD", "USD", "EUR", "JPY", "GBP"]
        case "prescription_type":
            return ["general", "emergency", "pediatric", "narcotic", "psychotropic", "tcm", "other"]
                .filter { EntityCardProjection.prescriptionTypes.contains($0) }
        // v26：诊断类型 / 检查报告类型（Domain CHECK 同拼写目录，Picker 绑 canonical raw）；
        // `kind` 目录随 EncounterKind.allCases 自动含 daySurgery（住院卡以外的 kind 由 invalidFields 裁定）。
        case "diagnosis_type": return Diagnosis.diagnosisTypes
        case "report_type": return ExamReport.reportTypes
        // v27：治疗类型 / 结论类型（Domain CHECK 同拼写目录；Picker 绑 canonical raw）
        case "treatment_type": return TreatmentRecord.treatmentTypes
        case "conclusion_type": return ClinicalConclusion.conclusionTypes
        default: return nil
        }
    }

    static func hash(_ data: Data) -> String { CryptoKitContentHasher().sha256Hex(data) }
    enum ImportError: Error { case unreadableMedia, storeUnavailable }
}

struct DocumentLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var showImportSource = false
    @State private var showArchived = false
    @State private var fileImporterActive = false
    @State private var photosImporterActive = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var selectionPatient: UUID?
    @State private var showManualCreate = false
    @State private var showImportError = false

    init(autoPresentImport: Bool = false) { _showImportSource = State(initialValue: autoPresentImport) }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if state.documents.isEmpty {
                    VLUnavailableView(L10n.docLibraryEmpty, systemImage: "folder", description: Text(L10n.docLibraryEmptyHint))
                } else {
                    List(state.documents) { doc in
                        DocumentLibraryRow(doc: doc)
                    }
                    .frame(maxWidth: 672)
                }
            }
            .navigationTitle(L10n.docLibraryTitle)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showArchived.toggle()
                        Task { await state.load(patientId: app.currentPatientId, includeArchived: showArchived) }
                    } label: { Image(systemName: showArchived ? "archivebox.fill" : "archivebox") }
                    .accessibilityLabel(L10n.docArchive)
                    Button { showImportSource = true } label: { Image(systemName: "plus") }
                        .disabled(!state.importSlotFree)
                        .accessibilityLabel(L10n.docAdd)
                        .accessibilityIdentifier("SP-09.document.add")
                }
            }
            .confirmationDialog(L10n.docImportSourceTitle, isPresented: $showImportSource, titleVisibility: .visible) {
                Button(L10n.docImportCamera) { router.navigate(to: .scanCapture(nil)) }
                Button(L10n.docImportFile) { selectionPatient = app.currentPatientId; fileImporterActive = true }
                Button(L10n.docImportPhotos) { selectionPatient = app.currentPatientId; photosImporterActive = true }
                Button(L10n.docImportManual) { showManualCreate = true }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .fileImporter(isPresented: $fileImporterActive, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    guard let patient = selectionPatient else { return }
                    state.enqueueFiles(urls, patientId: patient)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { showImportError = true }
                }
            }
            .photosPicker(isPresented: $photosImporterActive, selection: $pickedPhotos, maxSelectionCount: 5, matching: .images)
            .onChangeCompat(of: pickedPhotos) { _, items in
                guard !items.isEmpty, let patient = selectionPatient else { return }
                pickedPhotos = []
                state.enqueuePhotos(items, patientId: patient)
            }
            .ocrImportReviewHost(enabled: !fileImporterActive && !photosImporterActive)
            // 审查修复（读取失败可见化）：lastImportError 此前只在状态仓内部
            // 写入、零读者——load/fetch/setArchived 失败静默，列表残留旧数据
            // 或假空态。此处观察并弹出可见告警（四态纪律：读取失败必须有
            // 错误面，不得装作「暂无资料」）。
            .onChangeCompat(of: state.lastImportError) { _, newValue in
                if newValue != nil { showImportError = true }
            }
            .alert(L10n.docImportFailedTitle, isPresented: $showImportError) {
                Button(L10n.onboard_gotIt, role: .cancel) {}
            } message: { Text(L10n.docImportFailed) }
            .sheet(isPresented: $showManualCreate) {
                ManualDocumentSheet { title, type, note in
                    let patient = app.currentPatientId
                    Task {
                        await state.createManual(patientId: patient, title: title, docType: type, note: note)
                        showManualCreate = false
                    }
                }
            }
            .task(id: app.currentPatientId) {
                await state.load(patientId: app.currentPatientId, includeArchived: showArchived)
                state.processNextImport()
            }
        }
    }
}

private struct DocumentLibraryRow: View {
    let doc: DocumentStore.DocumentRow
    @Environment(DocumentsState.self) private var state

    var body: some View {
        WithPerceptionTracking {
            NavigationLink { DocumentDetailRouteView(documentId: doc.id) } label: {
                // v27（SP-09 行首图标）：文档类型 → 结构化目标首卡类图标（CardKindIcon 单一出口）；
                // DocumentRow 不携带稳定键，经标签反查（旧行按旧标签映射，未知 → 文档图标）。
                let spec = CardKindIcon.spec(documentTypeKey: DocumentsState.docTypeKey(forLabel: doc.docType))
                HStack {
                    Image(systemName: spec.symbol)
                        .foregroundStyle(spec.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(doc.docType).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color(.systemGray5)))
                            if doc.grade == "D" { GradeBadge(grade: "D") }
                            if doc.isSensitive { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange) }
                        }
                        Text(L10n.docTitle(doc.title)).font(.subheadline)
                        Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if doc.status == "favorite" { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }
            }
            .swipeActions {
                Button(doc.status == "archived" ? L10n.docUnarchive : L10n.docArchive) {
                    Task { await state.setArchived(id: doc.id, archived: doc.status != "archived") }
                }.tint(.orange)
                Button(doc.status == "favorite" ? L10n.docUnfavorite : L10n.docFavorite) {
                    Task { await state.setFavorite(id: doc.id, favorite: doc.status != "favorite") }
                }.tint(.yellow)
            }
            .contextMenu {
                if doc.origin != "manual" {
                    NavigationLink(L10n.docConfirmText) { DocumentReviewRouteView(documentId: doc.id, patientId: doc.patientId) }
                }
            }
            .accessibilityIdentifier("SP-09.document.row.\(doc.id.uuidString)")
        }
    }
}

private struct ManualDocumentSheet: View {
    let onCreate: (String, String, String) -> Void
    @State private var title = ""
    /// v27：类型目录 = `DocumentTypeKey` 27 稳定键（标签经 L10n），不再取旧 15 标签表
    @State private var type = DocumentsState.docTypeLabelOptions.first ?? DocumentsState.unresolvedDocTypePlaceholder
    @State private var note = ""

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    TextField(L10n.docManualTitle, text: $title)
                    Picker(L10n.docManualType, selection: $type) {
                        ForEach(DocumentsState.docTypeKeyOptions, id: \.self) { key in
                            let label = DocumentsState.docTypeLabel(forStableKey: key) ?? key
                            Label(label, systemImage: CardKindIcon.spec(documentTypeKey: key).symbol).tag(label)
                        }
                    }
                    TextField(L10n.docManualNote, text: $note, axis: .vertical).lineLimit(3...8)
                }
                .navigationTitle(L10n.docManualCreateTitle)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) { onCreate(title, type, note) }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}

struct DocumentStoreDetailView: View {
    let doc: DocumentStore.DocumentRow
    @State private var showOriginal = false
    @State private var showIssueSheet = false
    @Environment(AppState.self) private var app

    var body: some View {
        WithPerceptionTracking {
            List {
                Section(L10n.docTitleSection) {
                    Text(L10n.docTitle(doc.title)).font(.headline)
                    OCRReviewOwnerRow(patientId: doc.patientId)
                    LabeledContent(L10n.docDate, value: doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                    HStack { Text(doc.docType); if doc.grade == "D" { GradeBadge(grade: "D") } }
                }
                DocumentRelationsSection(documentId: doc.id, patientId: doc.patientId)
                Section {
                    Button { showOriginal = true } label: { Label(L10n.docViewOriginal, systemImage: "doc.text.magnifyingglass") }
                        .accessibilityIdentifier(doc.isSensitive ? "SP-09.document.detail.originalLocked" : "SP-09.document.detail.original")
                    if doc.origin != "manual" {
                        NavigationLink(L10n.docConfirmText) {
                            DocumentReviewRouteView(documentId: doc.id, patientId: doc.patientId)
                        }
                    }
                }
            }
            .navigationTitle(L10n.docDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showOriginal) {
                DocumentSourcePageView(documentId: doc.id, patientId: doc.patientId, pageIndex: 0)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showIssueSheet = true } label: { Image(systemName: "exclamationmark.bubble") }
                        .accessibilityLabel(L10n.docReportIssue)
                        .accessibilityIdentifier("SP-09.document.detail.reportIssue")
                }
            }
            .sheet(isPresented: $showIssueSheet) {
                ReportIssueSheet(documentId: doc.id, fields: []) { kind, fieldKey, note in
                    app.reportRecognitionIssue(documentId: doc.id, meta: "kind=\(kind);field=\(fieldKey);note=\(note)")
                }
            }
        }
    }
}

struct DuplicateCompareSheet: View {
    let existing: DocumentStore.DocumentRow?
    let newTitle: String
    var isResolving = false
    let onResolve: (DocumentsState.DuplicateResolution) -> Void
    @State private var choice: DocumentsState.DuplicateResolution = .keep

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 16) {
                Text(L10n.docDuplicateTitle).font(.headline)
                HStack(alignment: .top, spacing: 8) {
                    compareColumn(title: L10n.docDuplicateExisting, name: existing?.title ?? L10n.docUntitled, grade: existing?.grade ?? "D")
                    compareColumn(title: L10n.docDuplicateNewFile, name: newTitle, grade: "D")
                }
                if let existing { Text(existing.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                Picker("", selection: $choice) {
                    Text(L10n.docDuplicateKeep).tag(DocumentsState.DuplicateResolution.keep)
                    Text(L10n.docDuplicateReplace).tag(DocumentsState.DuplicateResolution.replace)
                    Text(L10n.docDuplicateKeepBoth).tag(DocumentsState.DuplicateResolution.coexist)
                }.pickerStyle(.segmented)
                HStack {
                    Button(L10n.commonCancel) { onResolve(.keep) }.buttonStyle(.bordered)
                    Button(L10n.commonConfirm) { onResolve(choice) }.buttonStyle(.borderedProminent)
                }
                Text(L10n.docDuplicateNeverAutoDelete).font(.caption2).foregroundStyle(.secondary)
                if isResolving { ProgressView() }
            }
            .padding(20)
            .disabled(isResolving)
        }
    }

    private func compareColumn(title: String, name: String, grade: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.subheadline).lineLimit(2)
            GradeBadge(grade: grade)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct ReportIssueSheet: View {
    let documentId: UUID
    let fields: [CandidateField]
    let onSubmit: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "fieldWrong"
    @State private var fieldKey: String?
    @State private var note = ""
    @State private var submitted = false
    private let kinds = [("fieldWrong", L10n.reportIssueFieldWrong), ("missingField", L10n.reportIssueMissing),
                         ("layout", L10n.reportIssueLayout), ("engine", L10n.reportIssueEngine)]

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section(L10n.reportIssueKind) {
                        Picker("", selection: $kind) { ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.inline)
                    }
                    if !fields.isEmpty {
                        Section(L10n.reportIssueField) {
                            Picker("", selection: $fieldKey) {
                                Text(L10n.reportIssueFieldAll).tag(String?.none)
                                ForEach(fields) { Text($0.displayLabel).tag(String?.some($0.key)) }
                            }
                        }
                    }
                    Section(L10n.reportIssueNote) {
                        TextField(L10n.reportIssueNoteHint, text: $note, axis: .vertical).lineLimit(2...5)
                    }
                    Section { Text(L10n.reportIssueMinimal).font(.caption2).foregroundStyle(.secondary) }
                }
                .navigationTitle(L10n.docReportIssue)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.commonCancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reportIssueSubmit) { onSubmit(kind, fieldKey ?? "", note); submitted = true }
                    }
                }
                .alert(L10n.reportIssueSubmitted, isPresented: $submitted) {
                    Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
                }
            }
        }
    }
}
