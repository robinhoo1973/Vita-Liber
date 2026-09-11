import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Domain
import Infrastructure
import Protocols

/// F5/F6: one retained import owns preparation, document review and every page card.
@MainActor
@Observable
final class DocumentsState {
    private(set) var documents: [DocumentStore.DocumentRow] = []
    private(set) var pendingDocuments: [DocumentStore.DocumentRow] = []
    private(set) var lastImportError: String?
    private(set) var pendingLoadError: String?
    private(set) var pendingVersion: UInt64 = 0
    private(set) var activeImport: ImportSession?
    private(set) var queuedImports: [QueuedImport] = []
    var pendingReviews: [String: PendingReview] = [:]

    private let store: DocumentStore
    let pendingCardStore: PendingCardStore?
    let cardStore: OCRCardStore?
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

    @MainActor @Observable
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

        init(patientId: UUID) { self.patientId = patientId }
    }

    @MainActor @Observable
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
        /// entityCards 的五个输入（matchPages + reconcileCards 的实参来源）；
        /// 任一变更即失效缓存（H8 审查修复：确认页 body 每次渲染都重跑
        /// matchPages——输入未变的键盘/焦点刷新也付全量模板匹配成本；
        /// didSet 失效使每帧重算收敛为每次真实变更一次）。
        var docType: String { didSet { cardsCache = nil } }
        var docTypeResolved = true
        var docTypeLowConfidence = false
        var docTypeManuallyChosen = false { didSet { cardsCache = nil } }
        var documentTypeKey: String? { didSet { cardsCache = nil } }
        var documentTypeCandidates: [String] = []
        var title: String?
        var isSensitive: Bool
        let origin: String
        let sha256: String
        let originalData: Data
        let processedData: Data
        let mimeType: String
        var qualityTags: [String]
        var pages: [PageAnalysis] { didSet { cardsCache = nil } }
        var replaceDocumentId: UUID?
        var existingDocumentId: UUID?
        var retainedMeta: [String: Any] = [:]
        var previousCards: [MatchedCard] = [] { didSet { cardsCache = nil } }
        private var cardsCache: [MatchedCard]?

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
            if let cache = cardsCache { return cache }
            // 值语义：数组/字典嵌套字段的原地修改同样走属性 setter 触发 didSet
            //（draft.pages[i].fields[j].value = x 即 pages 变更），缓存不失序。
            let cards = DocumentsState.reconcileCards(
                DocumentsState.matchPages(pages, manualTypeKey: docTypeManuallyChosen
                    ? (DocumentsState.docTypeKey(forLabel: docType) ?? documentTypeKey) : nil),
                previous: previousCards)
            cardsCache = cards
            return cards
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
         scheduler: (any ReminderScheduling)? = nil, cardStore: OCRCardStore? = nil) {
        self.store = store; self.pipeline = pipeline
        self.decoder = decoder ?? EngineRegistry.shared.resolve(ImageDecodingFactory.self)
        self.ocrAuthorized = ocrAuthorized
        self.aiAuthorization = aiAuthorization
        self.originalsDir = originalsDir ?? FileManager.default.temporaryDirectory
        self.understandingEngine = understandingEngine ?? EngineRegistry.shared.resolve(TextUnderstandingFactory.self)
        self.codeIndex = codeIndex; self.problemStore = problemStore
        self.dataChange = dataChange; self.pendingCardStore = pendingCards
        self.scheduler = scheduler; self.cardStore = cardStore
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
        loadingPatientId = patientId; lastIncludeArchived = includeArchived
        do {
            let rows = try await store.list(patientId: patientId, includeArchived: includeArchived)
            guard loadingPatientId == patientId else { return }
            documents = rows
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
            if ImageInputRules.supportedImageExtensions.contains(url.pathExtension.lowercased()) {
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
            var understanding = await understandingEngine.understand(input)
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
                understanding = await understandingEngine.understand(gated)
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
                let documentID: UUID
                if let existing = draft.existingDocumentId {
                    try await store.updateReview(id: existing, patientId: draft.patientId, docType: draft.docType,
                        isSensitive: draft.isSensitive, metaJSON: json, ocrText: text.isEmpty ? nil : text,
                        grade: draft.allReviewed ? "C" : "D", pages: pages, cards: review.all, reviewedFields: reviewedFields)
                    documentID = existing
                } else {
                    documentID = try await store.save(patientId: draft.patientId, docType: draft.docType,
                        sha256: draft.sha256, mimeType: draft.mimeType, origin: draft.origin,
                        isSensitive: draft.isSensitive, metaJSON: json, title: draft.title,
                        ocrText: text.isEmpty ? nil : text, grade: draft.allReviewed ? "C" : "D", pages: pages,
                        cards: review.all, reviewedFields: reviewedFields)
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
        for card in cards {
            let state = try await cardStore.reviewState(card: card, patientId: draft.patientId, documentId: documentID)
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

    func isClinicalDocType(_ label: String) -> Bool { label == L10n.docTypeReport || label == L10n.docTypeRecord }

    func createHealthProblem(patientId: UUID, name: String) async -> Bool {
        guard let problemStore else { return false }
        do { _ = try await problemStore.create(patientId: patientId, name: name); return true }
        catch { return false }
    }

    func createManual(patientId: UUID, title: String, docType: String, note: String) async {
        do {
            let json = String(decoding: try JSONEncoder().encode(["note": note]), as: UTF8.self)
            _ = try await store.save(patientId: patientId, docType: docType, sha256: nil, mimeType: nil,
                                    origin: "manual", isSensitive: false, metaJSON: json, title: title)
            await load(patientId: patientId)
            dataChange?.documentSaved()
        } catch { lastImportError = L10n.docImportFailed }
    }

    static func docTypeLabel(forStableKey key: String) -> String? {
        switch key {
        case "prescription": return L10n.docTypePrescription
        case "lab_report": return L10n.docTypeReport
        case "outpatient_record", "diagnosis_certificate": return L10n.docTypeRecord
        case "vaccine_record": return L10n.docTypeLabelVaccineRecord
        case "invoice": return L10n.claim_type_invoice
        case "medication_label": return L10n.entityCardKindName("medication")
        default: return nil
        }
    }

    static var unresolvedDocTypePlaceholder: String { L10n.docTypeLabelOther }

    static func docTypeKey(forLabel label: String) -> String? {
        ["prescription", "lab_report", "outpatient_record", "vaccine_record", "invoice", "medication_label"].first { docTypeLabel(forStableKey: $0) == label }
    }

    static func fieldLabel(forKey key: String) -> String {
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
            if key.hasPrefix("line_"), let index = Int(key.dropFirst(5)) { return String(format: L10n.ocrFieldLine, index + 1) }
            if key.hasPrefix("rx_line_"), let index = Int(key.dropFirst(8)) { return String(format: L10n.ocrFieldLine, index + 1) }
            return L10n.templateFieldLabel(key)
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
        Group {
            if state.documents.isEmpty {
                ContentUnavailableView(L10n.docLibraryEmpty, systemImage: "folder", description: Text(L10n.docLibraryEmptyHint))
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
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty, let patient = selectionPatient else { return }
            pickedPhotos = []
            state.enqueuePhotos(items, patientId: patient)
        }
        .ocrImportReviewHost(enabled: !fileImporterActive && !photosImporterActive)
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

private struct DocumentLibraryRow: View {
    let doc: DocumentStore.DocumentRow
    @Environment(DocumentsState.self) private var state

    var body: some View {
        NavigationLink { DocumentDetailRouteView(documentId: doc.id) } label: {
            HStack {
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

struct DocumentStoreDetailView: View {
    let doc: DocumentStore.DocumentRow
    @State private var showOriginal = false
    @State private var showIssueSheet = false
    @Environment(AppState.self) private var app

    var body: some View {
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

struct DuplicateCompareSheet: View {
    let existing: DocumentStore.DocumentRow?
    let newTitle: String
    var isResolving = false
    let onResolve: (DocumentsState.DuplicateResolution) -> Void
    @State private var choice: DocumentsState.DuplicateResolution = .keep

    var body: some View {
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
