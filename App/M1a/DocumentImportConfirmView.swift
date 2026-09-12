import SwiftUI
import UIKit
import Domain
import Infrastructure

/// 原件/类型审核与实体字段审核分离；字段只在对应信息卡中确认。
struct DocumentImportConfirmView: View {
    @Environment(DocumentsState.self) private var docs
    @Binding var draft: DocumentsState.ImportDraft
    @Bindable var session: DocumentsState.ImportSession
    @State private var sourcePage: Int?
    @State private var showLater = false

    private var editable: Bool { !session.isSaving && session.source == nil }

    var body: some View {
        List {
            Section {
                OCRReviewOwnerRow(patientId: draft.patientId)
                Picker(L10n.docConfirmDocType, selection: Binding(get: { draft.docType }, set: {
                    draft.docType = $0; draft.docTypeResolved = true; draft.docTypeManuallyChosen = true
                    draft.documentTypeKey = DocumentsState.docTypeKey(forLabel: $0)
                    draft.docTypeLowConfidence = false
                })) {
                    ForEach(typeOptions, id: \.self) { Text($0).tag($0) }
                }
                if !draft.docTypeResolved {
                    Text(L10n.docConfirmDocTypeUnresolved).foregroundStyle(.orange)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(typeOptions, id: \.self) { type in
                                Button(type) {
                                    draft.docType = type; draft.docTypeResolved = true
                                    draft.docTypeManuallyChosen = true; draft.docTypeLowConfidence = false
                                    draft.documentTypeKey = DocumentsState.docTypeKey(forLabel: type)
                                }.buttonStyle(.bordered).frame(minHeight: 44)
                            }
                        }
                    }
                } else if draft.docTypeLowConfidence {
                    Text(L10n.docConfirmDocTypeLowConfidence).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.captureSensitiveToggle, isOn: $draft.isSensitive)
            } footer: {
                Text(L10n.ocrReviewDocumentHint)
            }
            .disabled(!editable)

            Section(L10n.ocrCardsOverview) {
                let cards = draft.entityCards
                if cards.isEmpty { Text(L10n.ocrNoMatchedCards).foregroundStyle(.secondary) }
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.entityCardKindName(card.kind)).font(.headline)
                        Text(L10n.entityCardHeaderPage(card.pageIndex + 1, draft.pages.count)).font(.caption)
                        Text(L10n.ocrCardFieldCount(card.allFields.count)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                Text(L10n.ocrCardReviewHint).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(draft.pages.indices, id: \.self) { pageIndex in
                Section {
                    Button { sourcePage = draft.pages[pageIndex].index } label: {
                        Label(L10n.docConfirmViewRegion, systemImage: "doc.text.magnifyingglass")
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                    if draft.pages[pageIndex].status == "failed" {
                        Label(L10n.docPDFImportFailed, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if draft.pages[pageIndex].status == "skipped" {
                        Text(L10n.ocrReviewPageSkipped).foregroundStyle(.secondary)
                    } else if draft.pages[pageIndex].fields.isEmpty {
                        Text(L10n.imageInputNoText).foregroundStyle(.secondary)
                    }
                    if !draft.pages[pageIndex].lines.isEmpty {
                        DisclosureGroup(L10n.pendingCardRawText) {
                            Text(draft.pages[pageIndex].text).font(.callout).textSelection(.enabled)
                        }
                        Text(draft.pages[pageIndex].fields.contains { $0.source == .foundationModels }
                             ? L10n.ocrExtractionModel : L10n.ocrExtractionRules)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.entityCardHeaderPage(draft.pages[pageIndex].index + 1, draft.pages.count))
                }
            }
            if !draft.qualityTags.isEmpty {
                Section {
                    ForEach(draft.qualityTags, id: \.self) {
                        Label(L10n.qualityTag($0), systemImage: "exclamationmark.triangle").font(.caption)
                    }
                }
            }
            Section {
                Button { showLater = true } label: {
                    Label(L10n.docConfirmSkipLater, systemImage: "clock.badge.checkmark").frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(session.isSaving || !draft.docTypeResolved)
                .accessibilityIdentifier("SP-12.skip-later")
            }
        }
        .disabled(session.isSaving || session.isBulkDeferring)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L10n.docConfirmTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.commonCancel) { docs.cancelImport(sessionID: session.id) }
                    .disabled(session.isSaving || session.source != nil)
                    .accessibilityIdentifier("SP-11.docConfirm.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.ocrBeginCardReview) {
                    let snapshot = draft
                    Task { _ = await docs.commitDraft(snapshot) }
                }
                .disabled(session.isSaving || !draft.docTypeResolved)
                .accessibilityIdentifier("SP-11.docConfirm.saveAll")
            }
            ToolbarItemGroup(placement: .keyboard) { OCRKeyboardDismissButton() }
        }
        .sheet(isPresented: Binding(get: { sourcePage != nil }, set: { if !$0 { sourcePage = nil } })) {
            if let page = sourcePage { DocumentSourcePageView(draft: draft, pageIndex: page) }
        }
        .confirmationDialog(L10n.docConfirmSkipTitle, isPresented: $showLater, titleVisibility: .visible) {
            Button(L10n.docConfirmSkipConfirm) {
                let snapshot = draft
                Task { _ = await docs.deferImportDraft(snapshot) }
            }
            Button(L10n.commonCancel, role: .cancel) {}
        } message: { Text(L10n.ocrReviewDocumentHint) }
    }

    private var typeOptions: [String] {
        var seen = Set<String>()
        return (draft.documentTypeCandidates + L10n.docTypeLabels + [draft.docType]).filter { seen.insert($0).inserted }
    }
}

/// Immediate binding: keyboard submission, page save and later all see the same current value.
struct FieldConfirmRow: View {
    @Binding var field: FieldDraft
    let label: String
    var showUnit = true
    var readOnly = false
    var cardLevelConfirmation = false
    var onRevise: ((String) -> Void)?
    @FocusState private var focused: Bool

    private var tier: ConfidenceTier { ConfidenceTier.tier(field.confidence) }
    private var confidenceLabel: String {
        switch tier {
        case .high: return L10n.docConfirmConfidenceHigh
        case .mid: return L10n.docConfirmConfidenceMid
        case .low: return L10n.docConfirmConfidenceLow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if field.grade == .rejected { Text(L10n.docConfirmReject).font(.caption) }
                else { GradeBadge(grade: field.isConfirmed ? "C" : "D") }
            }
            if !field.isConfirmed && field.grade != .rejected {
                Text(confidenceLabel).font(.caption)
                    .foregroundStyle(tier == .low ? Color("semantic-danger", bundle: .main) : Color.secondary)
            }
            if readOnly || field.grade == .rejected {
                Text(DocumentsState.fieldValueDisplay(forKey: field.key, value: field.value))
                    .strikethrough(field.grade == .rejected)
            } else {
                // 编辑态显示并回写 canonical raw（编辑框即数据真值；展示文案
                // 永不写回数据）——把展示文案映射进编辑框会令半程编辑
                // （退格/追加一字符）把本地化片段写进 raw 槽位、污染审计
                // 历史（round10 max 审查结论：与「编辑态仍回写 raw」设计一致）。
                TextField(label, text: Binding(get: { field.value }, set: { value in
                    if let onRevise { onRevise(value) } else { field.revise(to: value) }
                }), axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { focused = false }
                if showUnit, field.unit != nil {
                    TextField(L10n.templateFieldLabel("unit"), text: Binding(get: { field.unit ?? "" }, set: { field.unit = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if !readOnly {
                HStack(spacing: 12) {
                    if field.grade == .rejected {
                        Button(L10n.docConfirmReenable) { field.reenable() }
                    } else {
                        if !cardLevelConfirmation || tier == .low {
                            Button(L10n.commonConfirm) { _ = field.confirm(); focused = false }
                                .disabled(field.isConfirmed || field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("OCR.field.confirm.\(field.key)")
                        }
                        // 审查修复：单条目 Menu 只徒增一次点按——卡级模式下
                        // 「拒绝」以纯按钮直出（行为与页面级完全一致）。
                        Button(L10n.docConfirmReject, role: .destructive) { field.reject() }
                    }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, cardLevelConfirmation ? 10 : 0)
        .overlay(alignment: .leading) {
            if cardLevelConfirmation {
                // 审查修复：token-only 纪律——已确认走 C 级绿、低置信走语义红、
                // 中置信走语义橙（旧实现内联系统调色板，深色/关怀模式无主题化）。
                Rectangle().fill(field.isConfirmed ? Color("grade-c", bundle: .main)
                    : tier == .low ? Color("semantic-danger", bundle: .main)
                    : Color("semantic-warning", bundle: .main))
                    .frame(width: 3)
            }
        }
    }
}

struct OCRKeyboardDismissButton: View {
    var body: some View {
        HStack {
            Spacer()
            Button(L10n.onboard_gotIt) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
}

struct OCRReviewOwnerRow: View {
    let patientId: UUID
    @Environment(AppState.self) private var app

    var body: some View {
        LabeledContent(L10n.commonMember, value: app.members.first { $0.id == patientId }?.displayName ?? patientId.uuidString)
            .accessibilityIdentifier("OCR.review.owner.\(patientId.uuidString)")
    }
}

/// One sheet changes content in place; no document-sheet/entity-sheet arming race.
private struct ImportReviewSessionView: View {
    @Bindable var session: DocumentsState.ImportSession
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss
    @State private var offerHealthProblem = false

    private var alertVisible: Bool { session.errorMessage != nil || session.notificationError != nil || offerHealthProblem }
    private var completionKey: String {
        "\(String(describing: session.outcome))-\(session.isSaving)-\(session.isBulkDeferring)-\(alertVisible)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let duplicate = session.duplicate {
                    VStack {
                        OCRReviewOwnerRow(patientId: session.patientId).padding(.horizontal)
                        DuplicateCompareSheet(existing: session.duplicateHits.first,
                            newTitle: duplicate.title ?? L10n.docDuplicateNewFile, isResolving: session.isPreparing) { resolution in
                            Task { session.draft = await docs.resolveDuplicate(resolution) }
                        }
                    }
                } else if !session.documentReviewFinished, let draft = session.draft {
                    DocumentImportConfirmView(draft: Binding(get: { session.draft ?? draft }, set: { session.draft = $0 }), session: session)
                } else if let card = docs.currentEntityCard, let source = session.source {
                    VStack(spacing: 0) {
                        OCRCardBrowserNavigation(session: session)
                        EntityCardConfirmView(card: Binding(get: { session.cards.first { $0.id == card.id } ?? card }, set: { edited in
                            guard edited.id == card.id else { return }
                            _ = docs.updateEntityCard(edited)
                        }), mode: .queue(session), patientId: source.patientId, documentId: source.documentId,
                            pageCount: source.pages.count, position: docs.entityQueuePosition)
                            .id(card.id)
                    }
                } else if session.errorMessage != nil {
                    ContentUnavailableView(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                } else { ProgressView() }
            }
            .disabled(session.isPreparing || session.isBulkDeferring)
            .toolbar {
                if session.draft == nil && session.duplicate == nil && !session.isPreparing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { docs.cancelImport(sessionID: session.id) }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .alert(session.notificationError != nil ? L10n.helpPermNotification
               : offerHealthProblem ? L10n.healthProblemOfferTitle : L10n.docConfirmSaveFailedTitle,
               isPresented: Binding(get: { alertVisible }, set: { showing in
                   if !showing {
                       session.errorMessage = nil; session.notificationError = nil; offerHealthProblem = false
                   }
               })) {
            if offerHealthProblem {
                Button(L10n.healthProblemCreate) { createHealthProblem() }
            }
            Button(L10n.onboard_gotIt, role: .cancel) {}
        } message: {
            Text(session.notificationError ?? session.errorMessage ?? L10n.healthProblemOfferBody)
        }
        .task(id: completionKey) {
            guard session.outcome != nil, !session.isSaving, !session.isBulkDeferring, !alertVisible else { return }
            if session.outcome == .saved, !session.healthProblemOfferHandled,
               let draft = session.draft, draft.allReviewed,
               docs.isClinicalDocType(key: draft.documentTypeKey, label: draft.docType) {
                session.healthProblemOfferHandled = true
                offerHealthProblem = true
            } else { dismiss() }
        }
    }

    private func createHealthProblem() {
        guard let draft = session.draft else { return }
        let fields = draft.allFields.filter(\.isConfirmed).map {
            CandidateField(key: $0.key, displayLabel: DocumentsState.fieldLabel(forKey: $0.key),
                rawText: $0.rawText ?? $0.originalValue, confidence: $0.confidence, value: $0.value, grade: .userConfirmed)
        }
        let name = HealthProblemDerivation.candidateName(fields: fields, docTypeLabel: draft.docType)
        session.isSaving = true
        Task {
            let saved = await docs.createHealthProblem(patientId: draft.patientId, name: name)
            if !saved { session.errorMessage = L10n.docImportFailed }
            session.isSaving = false
        }
    }
}

private struct OCRCardBrowserNavigation: View {
    @Bindable var session: DocumentsState.ImportSession
    @Environment(DocumentsState.self) private var docs
    private var index: Int { session.cards.firstIndex { $0.id == docs.currentEntityCard?.id } ?? 0 }
    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(session.cards) { card in
                        Button {
                            docs.selectEntityCard(card.id)
                        } label: {
                            VStack(spacing: 2) {
                                Text(L10n.entityCardKindName(card.kind))
                                Text(L10n.entityCardHeaderPage(card.pageIndex + 1, session.source?.pages.count ?? 1)).font(.caption2)
                            }
                            .padding(8).frame(minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(card.id == docs.currentEntityCard?.id
                                ? Color("brand-primary", bundle: .main).opacity(0.16) : Color(.secondarySystemGroupedBackground)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("SP-12.card.select.\(card.id.uuidString)")
                    }
                }.padding(.horizontal)
            }
            HStack {
                // 审查修复：上/下一张按钮自身无 44pt 命中区（父 HStack 的
                // minHeight 不扩大子按钮热区）——逐按钮补 44pt + contentShape。
                Button(L10n.ocrPreviousCard) { docs.selectEntityCard(session.cards[index - 1].id) }
                    .disabled(index == 0)
                    .frame(minHeight: 44).contentShape(Rectangle())
                Spacer()
                Text(L10n.ocrCardsRemaining(session.cards.count)).font(.caption)
                Spacer()
                Button(L10n.ocrNextCard) { docs.selectEntityCard(session.cards[index + 1].id) }
                    .disabled(index + 1 >= session.cards.count)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.padding(.horizontal).frame(minHeight: 44)
        }
        .disabled(session.isSaving || session.isBulkDeferring)
        .background(.thinMaterial)
    }
}

private struct OCRImportReviewHost: ViewModifier {
    let enabled: Bool
    let advanceQueuedImports: Bool
    var onFinished: (DocumentsState.ImportOutcome) -> Void
    @Environment(DocumentsState.self) private var docs
    @State private var presenterID = UUID()
    @State private var presented: DocumentsState.ImportSession?
    @State private var presentedSession: DocumentsState.ImportSession?
    @State private var visible = false

    func body(content: Content) -> some View {
        // Keep the presenter mounted when a library's empty/list branch changes after saving.
        ZStack { content }
            .sheet(item: $presented, onDismiss: {
                guard let session = presentedSession else { return }
                if session.presenterID == presenterID {
                    docs.releaseImportPresenter(sessionID: session.id, presenterID: presenterID)
                    if let outcome = session.outcome, docs.finishImportPresentation(sessionID: session.id) {
                        onFinished(outcome)
                        if advanceQueuedImports { docs.processNextImport() }
                    }
                }
                presentedSession = nil
            }) { session in ImportReviewSessionView(session: session) }
            .onChange(of: docs.activeImport?.id, initial: true) { _, _ in presentIfReady() }
            .onChange(of: enabled) { _, _ in presentIfReady() }
            .onAppear { visible = true; presentIfReady() }
            .onDisappear {
                visible = false
                if let session = presentedSession {
                    docs.releaseImportPresenter(sessionID: session.id, presenterID: presenterID)
                }
            }
    }

    private func presentIfReady() {
        guard enabled, visible, presented == nil, let session = docs.activeImport,
              session.presenterID == nil || session.presenterID == presenterID else { return }
        session.presenterID = presenterID
        presentedSession = session
        presented = session
    }
}

extension View {
    func ocrImportReviewHost(enabled: Bool = true, advanceQueuedImports: Bool = true,
                             onFinished: @escaping (DocumentsState.ImportOutcome) -> Void = { _ in }) -> some View {
        modifier(OCRImportReviewHost(enabled: enabled, advanceQueuedImports: advanceQueuedImports, onFinished: onFinished))
    }
}

struct DocumentReviewRouteView: View {
    let documentId: UUID
    let patientId: UUID
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    @State private var reviewingSessionID: UUID?

    var body: some View {
        VStack(spacing: 16) {
            OCRReviewOwnerRow(patientId: patientId)
            if let active = docs.activeImport, reviewingSessionID != active.id {
                Text(L10n.ocrReviewFinishCurrent)
                OCRReviewOwnerRow(patientId: active.patientId)
                Button(L10n.pendingCardResume) { reviewingSessionID = active.id }.buttonStyle(.bordered)
            } else if failed {
                Text(L10n.sensitiveMedia_loadFailed)
                Button(L10n.retry) { Task { await prepare() } }.buttonStyle(.bordered)
            } else { ProgressView() }
        }
        .padding()
        .navigationTitle(L10n.docConfirmTitle)
        .ocrImportReviewHost(enabled: reviewingSessionID != nil && docs.activeImport?.id == reviewingSessionID,
                             advanceQueuedImports: false) { _ in dismiss() }
        .task { await prepare() }
    }

    private func prepare() async {
        failed = false
        if docs.activeImport == nil {
            reviewingSessionID = docs.beginImport(patientId: patientId)?.id
            failed = await docs.prepareStoredDocument(id: documentId, patientId: patientId) == nil
        } else if docs.activeImport?.draft?.existingDocumentId == documentId {
            reviewingSessionID = docs.activeImport?.id
        }
    }
}
