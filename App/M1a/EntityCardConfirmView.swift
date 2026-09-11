import SwiftUI
import Domain
import Infrastructure

struct EntityCardConfirmView: View {
    enum Mode {
        case queue(DocumentsState.ImportSession)
        case resume(DocumentsState.PendingReview)
    }

    @Binding var card: MatchedCard
    let mode: Mode
    let patientId: UUID
    let documentId: UUID
    let pageCount: Int
    var position: (Int, Int)?
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss
    @State private var showSource = false
    @State private var showLater = false
    @State private var showDiscard = false
    @State private var partialCount: Int?

    private var saving: Bool {
        switch mode {
        case .queue(let session): return session.isSaving || session.isBulkDeferring
        case .resume(let review): return review.isSaving
        }
    }
    private var sharedCommitted: Bool {
        switch mode {
        case .queue:
            // A partial receipt fixes shared data for already-written rows.
            return docs.activeImport?.committedCards.contains(card.id) == true
        case .resume(let review): return review.sharedCommitted
        }
    }
    private var rowKeys: Set<String> {
        CardTemplateMatcher.ocrTemplates.first { $0.kind == card.kind }?.rowLevelKeys ?? []
    }
    private func missingShared(reviewed: MatchedCard) -> [String] {
        Set(card.rows.flatMap { invalid($0, reviewed: reviewed) }).filter { key in
            !rowKeys.contains(key) && key != "card_kind" && !card.shared.contains { $0.key == key }
        }.sorted()
    }
    private func canSave(reviewed: MatchedCard) -> Bool {
        !saving && card.rows.contains { invalid($0, reviewed: reviewed).isEmpty || EntityCardProjection.isDiscarded($0, in: card) }
    }
    private var resumeError: String? {
        if case .resume(let review) = mode { return review.notificationError ?? review.errorMessage }
        return nil
    }
    private var completionKey: String {
        if case .resume(let review) = mode { return "\(review.completed)-\(saving)-\(resumeError != nil)" }
        return "queue"
    }

    var body: some View {
        // 审查修复（每帧纪律）：confirmation 投影每帧只求值一次——旧实现
        // invalid(_:) 内部各自重建全卡投影，validation/missingShared/canSave
        // 三处合计 ~3N 次全卡拷贝（每次击键触发），N 行卡明显可感知。
        let reviewed = card.confirmingAllFields()
        let validation = Dictionary(uniqueKeysWithValues: card.rows.map { ($0.id, invalid($0, reviewed: reviewed)) })
        List {
            Section {
                OCRReviewOwnerRow(patientId: patientId)
                HStack {
                    Text(L10n.entityCardHeaderPage(card.pageIndex + 1, max(pageCount, card.pageIndex + 1)))
                    if let position { Text(L10n.entityCardHeaderIndex(position.0, position.1)) }
                    Spacer()
                    GradeBadge(grade: "D")
                }.font(.caption)
                Button { showSource = true } label: {
                    Label(L10n.pendingCardViewSource, systemImage: "doc.text.magnifyingglass").frame(minHeight: 44)
                }.buttonStyle(.borderless)
            } footer: { Text(L10n.docConfirmHint) }

            EncounterAssociationSection(card: $card, patientId: patientId, readOnly: saving || sharedCommitted)

            Section(L10n.entityCardSharedSection) {
                if sharedCommitted { Text(L10n.homeCaptureSaved).font(.caption).foregroundStyle(.secondary) }
                ForEach(card.shared.indices, id: \.self) { index in
                    FieldConfirmRow(field: fieldBinding(index: index, rowID: nil),
                        label: DocumentsState.fieldLabel(forKey: card.shared[index].key),
                         showUnit: false, readOnly: sharedCommitted,
                         cardLevelConfirmation: true,
                        onRevise: { revise(index: index, rowID: nil, value: $0) })
                    if card.shared[index].isConfirmed, validation.values.contains(where: { $0.contains(card.shared[index].key) }) {
                        Text(L10n.ocrReviewInvalidField).font(.caption).foregroundStyle(.red)
                    }
                }
                ForEach(missingShared(reviewed: reviewed), id: \.self) { key in missingButton(key: key, rowID: nil) }
            }

            ForEach(Array(card.rows.enumerated()), id: \.element.id) { offset, row in
                if !row.fields.isEmpty || !rowKeys.isEmpty {
                    Section {
                        ForEach(row.fields.indices.filter { row.fields[$0].key != "metric_key" }, id: \.self) { index in
                            FieldConfirmRow(field: fieldBinding(index: index, rowID: row.id),
                                 label: DocumentsState.fieldLabel(forKey: row.fields[index].key), showUnit: false,
                                 cardLevelConfirmation: true,
                                onRevise: { revise(index: index, rowID: row.id, value: $0) })
                            if row.fields[index].isConfirmed && validation[row.id]?.contains(row.fields[index].key) == true {
                                Text(L10n.ocrReviewInvalidField).font(.caption).foregroundStyle(.red)
                            }
                        }
                        ForEach((validation[row.id] ?? []).filter { key in rowKeys.contains(key) && !row.fields.contains(where: { $0.key == key }) }, id: \.self) { key in
                            missingButton(key: key, rowID: row.id)
                        }
                    } header: { Text(L10n.entityCardRowIndex(offset + 1)) }
                }
            }
            if !missingShared(reviewed: reviewed).isEmpty || validation.values.contains(where: { !$0.isEmpty }) {
                Section { Text(L10n.docConfirmHint).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Button { showLater = true } label: {
                    Label(L10n.entityCardLater, systemImage: "clock.badge.checkmark").frame(minHeight: 44)
                }
                Button(role: .destructive) { showDiscard = true } label: {
                    Label(L10n.entityCardDiscard, systemImage: "xmark.circle").frame(minHeight: 44)
                }
                if case .queue = mode, docs.entityQueue.count > 1 {
                    Button {
                        Task { _ = await docs.deferRemainingEntityCards() }
                    } label: {
                        Label(L10n.entityCardDeferRemaining, systemImage: "tray.full").frame(minHeight: 44)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.entityCardConfirmAllHint)
                    Text(L10n.entityCardLaterHint)
                }
            }
            .buttonStyle(.borderless)
        }
        .disabled(saving)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L10n.entityCardKindName(card.kind))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.entityCardConfirmSave) { save(reviewed: reviewed) }.disabled(!canSave(reviewed: reviewed))
                    .accessibilityIdentifier("SP-12.entity.confirm")
            }
            ToolbarItemGroup(placement: .keyboard) { OCRKeyboardDismissButton() }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSource) {
            DocumentSourcePageView(documentId: documentId, patientId: patientId, pageIndex: card.pageIndex)
        }
        .confirmationDialog(L10n.entityCardLater, isPresented: $showLater, titleVisibility: .visible) {
            Button(L10n.docConfirmSkipConfirm) { deferCard() }
            Button(L10n.commonCancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.entityCardDiscard, isPresented: $showDiscard, titleVisibility: .visible) {
            Button(L10n.entityCardDiscard, role: .destructive) { discard() }
            Button(L10n.commonCancel, role: .cancel) {}
        }
        .alert(resumeError != nil ? L10n.docConfirmSaveFailedTitle : L10n.homeCaptureSaved,
               isPresented: Binding(get: { resumeError != nil || partialCount != nil }, set: { showing in
                   if !showing {
                       partialCount = nil
                       if case .resume(let review) = mode { review.errorMessage = nil; review.notificationError = nil }
                   }
               })) {
            Button(L10n.onboard_gotIt, role: .cancel) {}
        } message: { Text(resumeError ?? L10n.ocrReviewPartialSaved(partialCount ?? 0)) }
        .task(id: completionKey) {
            if case .resume(let review) = mode, review.completed, !saving, resumeError == nil { dismiss() }
        }
    }

    private func invalid(_ row: MatchedCardRow, reviewed: MatchedCard) -> [String] {
        EntityCardProjection.invalidFields(in: reviewed,
            row: reviewed.rows.first { $0.id == row.id } ?? row, calendar: Calendar(identifier: .gregorian))
    }

    private func missingButton(key: String, rowID: UUID?) -> some View {
        Button(L10n.entityCardMissingRequired(DocumentsState.fieldLabel(forKey: key))) {
            var current = card
            let field = FieldDraft(key: key, value: "", confidence: 1)
            if let rowID, let row = current.rows.firstIndex(where: { $0.id == rowID }) {
                if !current.rows[row].fields.contains(where: { $0.key == key }) { current.rows[row].fields.append(field) }
            } else if rowID == nil, !current.shared.contains(where: { $0.key == key }) { current.shared.append(field) }
            card = current
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
        .disabled(rowID == nil && sharedCommitted)
    }

    private func fieldBinding(index: Int, rowID: UUID?) -> Binding<FieldDraft> {
        let existing: FieldDraft?
        if let rowID { existing = card.rows.first { $0.id == rowID }?.fields[safe: index] }
        else { existing = card.shared[safe: index] }
        let fallback = existing ?? FieldDraft(key: "", value: "", confidence: 0)
        return Binding(get: {
            if let rowID { return card.rows.first { $0.id == rowID }?.fields[safe: index] ?? fallback }
            return card.shared[safe: index] ?? fallback
        }, set: { field in
            guard !saving else { return }
            var current = card
            if let rowID, let row = current.rows.firstIndex(where: { $0.id == rowID }), current.rows[row].fields.indices.contains(index) {
                current.rows[row].fields[index] = field
            } else if rowID == nil, !sharedCommitted, current.shared.indices.contains(index) {
                current.shared[index] = field
            }
            card = current
        })
    }

    private func revise(index: Int, rowID: UUID?, value: String) {
        guard !saving, rowID != nil || !sharedCommitted else { return }
        var current = card
        current.reviseField(at: index, rowId: rowID, to: value)
        card = current
    }

    private func save(reviewed: MatchedCard) {
        guard canSave(reviewed: reviewed) else { return }
        // FR6.9 V3.66 一键确认本卡：保存即确认卡内其余非低置信字段（用户卡级显式动作），
        // 低置信字段仍须逐项确认（FR17.4），缺必填行原样进待办/剩余卡。
        let snapshot = card.confirmingAllFields()
        Task {
            let result: OCRCardStore.SaveResult?
            switch mode {
            case .queue: result = await docs.confirmEntityCard(snapshot, confirmed: snapshot)
            case .resume(let review): result = await docs.completePendingCard(review.pending, confirmed: snapshot)
            }
            if let result, !result.resolved { partialCount = result.writtenCount }
        }
    }

    private func deferCard() {
        let snapshot = card
        Task {
            switch mode {
            case .queue: _ = await docs.deferEntityCard(snapshot)
            case .resume(let review):
                review.isSaving = true
                let saved = await docs.deferPendingCard(review.pending, edited: snapshot)
                review.isSaving = false
                if saved { dismiss() }
            }
        }
    }

    private func discard() {
        let snapshot = card
        Task {
            switch mode {
            case .queue: _ = await docs.discardEntityCard(snapshot)
            case .resume(let review): _ = await docs.discardPendingCard(review.pending)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct PendingCardResumeRouteView: View {
    let cardId: String
    @Environment(DocumentsState.self) private var docs
    @State private var pending: PendingCard?
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var reimport = false
    @State private var retainedImportID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let retainedImportID, docs.activeImport?.id == retainedImportID {
                ProgressView()
            } else if pending != nil, let review = docs.pendingReviews[cardId], let documentId = review.pending.sourceDocId, !loadFailed {
                EntityCardConfirmView(card: Binding(get: { review.card }, set: { review.card = $0 }),
                    mode: .resume(review), patientId: review.pending.patientId, documentId: documentId,
                    pageCount: review.pageCount, position: nil)
            } else if let pending, loaded {
                List {
                    Section {
                        OCRReviewOwnerRow(patientId: pending.patientId)
                        GradeBadge(grade: "D")
                        Text(L10n.ocrReviewLegacySourceMissing)
                        Button(L10n.homeCaptureFile) { reimport = true }.frame(minHeight: 44)
                    }
                    Section(L10n.entityCardSharedSection) {
                        ForEach(pending.partialData.shared.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(DocumentsState.fieldLabel(forKey: key), value: value)
                        }
                        ForEach(Array(pending.partialData.rows.enumerated()), id: \.offset) { index, row in
                            VStack(alignment: .leading) {
                                Text(L10n.entityCardRowIndex(index + 1)).font(.caption)
                                ForEach(row.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    LabeledContent(DocumentsState.fieldLabel(forKey: key), value: value)
                                }
                            }
                        }
                    }
                    Section(L10n.pendingCardRawText) { Text(pending.rawText).textSelection(.enabled) }
                }
            } else if loadFailed {
                ContentUnavailableView {
                    Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                } actions: { Button(L10n.retry) { Task { await load() } } }
            } else if loaded {
                ContentUnavailableView(L10n.pendingCardNotFound, systemImage: "tray")
            } else { ProgressView() }
        }
        .task(id: cardId) { await load() }
        .ocrImportReviewHost(enabled: retainedImportID != nil && docs.activeImport?.id == retainedImportID,
                             advanceQueuedImports: false) { _ in dismiss() }
        .onDisappear {
            if docs.pendingReviews[cardId]?.completed == true { docs.pendingReviews.removeValue(forKey: cardId) }
        }
        .sheet(isPresented: $reimport) {
            if let pending { NavigationStack { QuickCaptureView(kind: nil, patientId: pending.patientId) } }
        }
        .toolbar {
            if loaded && docs.pendingReviews[cardId] == nil && retainedImportID == nil {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.commonCancel) { dismiss() } }
            }
        }
    }

    private func load() async {
        loaded = false; loadFailed = false; pending = nil; retainedImportID = nil
        do {
            let fetched = try await docs.loadPendingCard(id: cardId)
            guard !Task.isCancelled else { return }
            guard let fetched, ["pending", "in_progress"].contains(fetched.status) else { loaded = true; return }
            pending = fetched
            if let retained = docs.retainedImport(for: fetched) {
                retainedImportID = retained.id
                loaded = true
                return
            }
            _ = await docs.resumePendingCard(fetched)
        } catch { loadFailed = true }
        loaded = true
    }
}
