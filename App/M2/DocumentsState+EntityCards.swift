import Foundation
import Domain
import Infrastructure
import Protocols

extension DocumentsState {
    struct PageAnalysis: Codable, Equatable, Sendable {
        let index: Int
        let lines: [String]
        var status: String = "ok"
        var fields: [FieldDraft]
        var documentTypeKey: String?
        var confidence: Double = 0
        var qualityTags: [String] = []
        var typeConfidence: Double?
        var text: String { lines.joined(separator: "\n") }
    }

    var currentEntityCard: MatchedCard? {
        entityQueue.first { $0.id == activeImport?.selectedCardID } ?? entityQueue.first
    }
    var entityQueuePosition: (Int, Int) {
        // 审查修复：cardOrder 缺席时回落「剩余队列序位」而非 0（0 会把
        // 显示静默塌成「第 1 / M 张」）——cardOrder 是提交时快照，恢复/重建
        // 路径可能不携带它，位置显示不得依赖该快照的恒存性。
        let index = activeImport?.cardOrder.firstIndex { $0 == currentEntityCard?.id }
            ?? (entityQueueTotal - entityQueue.count)
        return (index + 1, entityQueueTotal)
    }

    /// Extraction is page-local and not restricted to the primary document label.
    static func extractPageFields(lines: [String], understood: [FieldDraft], confidence: Double) -> [FieldDraft] {
        DocumentTypeClassifierFallback.pageFields(lines: lines, understood: understood, confidence: confidence)
    }

    static func matchPages(_ pages: [PageAnalysis], manualTypeKey: String?) -> [MatchedCard] {
        pages.flatMap { page -> [MatchedCard] in
            guard page.status == "ok" else { return [] }
            let fields = page.fields.filter { $0.grade != .rejected && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let visitEvidence = manualTypeKey == "outpatient_record" || manualTypeKey == "diagnosis_certificate"
                || DocumentTypeClassifierFallback.hasVisitEvidence(in: fields)
            return CardTemplateMatcher.ocrTemplates.filter { OCRCardStore.supportedKinds.contains($0.kind) }.flatMap { template in
                var input = fields
                if template.kind == "prescription", !input.contains(where: { $0.key == "prescribed_at" }) {
                    for field in fields where field.key == "report_date" {
                        var date = field; date.key = "prescribed_at"
                        input.append(date)
                    }
                }
                let evidence = template.kind == "encounter" ? (visitEvidence ? "outpatient_record" : nil) : page.documentTypeKey
                var matches = CardTemplateMatcher.match(fields: input, pageIndex: page.index,
                                                       documentTypeKey: evidence, templates: [template])
                // Derived fields must not upgrade a low-confidence OCR page.
                for index in matches.indices {
                    for field in matches[index].shared.indices {
                        matches[index].shared[field].confidence = min(matches[index].shared[field].confidence, page.confidence)
                    }
                    for row in matches[index].rows.indices {
                        for field in matches[index].rows[row].fields.indices {
                            matches[index].rows[row].fields[field].confidence = min(matches[index].rows[row].fields[field].confidence, page.confidence)
                        }
                    }
                }
                return matches
            }
        }
    }

    /// Rebase changed document values onto the original card fields, preserving provenance and IDs.
    static func reconcileCards(_ cards: [MatchedCard], previous: [MatchedCard]) -> [MatchedCard] {
        func reconcileFields(_ current: [FieldDraft], _ original: [FieldDraft]) -> [FieldDraft] {
            var used = Set<Int>()
            return current.map { value in
                guard let index = original.indices.first(where: {
                    !used.contains($0) && original[$0].key == value.key && original[$0].rawText == value.rawText
                }) else { return value }
                used.insert(index)
                var field = original[index]
                field.revise(to: value.value)
                field.unit = value.unit
                field.confidence = value.confidence
                if value.grade == .rejected { field.reject() }
                else if value.isConfirmed { _ = field.confirm() }
                else { field.reenable() }
                return field
            }
        }
        return cards.map { current in
            guard let old = previous.first(where: { $0.kind == current.kind && $0.pageIndex == current.pageIndex }) else { return current }
            var used = Set<UUID>()
            let rows = current.rows.map { row -> MatchedCardRow in
                let previousRow = old.rows.first { !used.contains($0.id) && $0.fields.first?.rawText == row.fields.first?.rawText }
                guard let previousRow else { return row }
                used.insert(previousRow.id)
                return MatchedCardRow(id: previousRow.id, fields: reconcileFields(row.fields, previousRow.fields), missingRequired: row.missingRequired)
            }
            // 审查修复（过期建议陷阱）：建议随证据（医院/日期等）生成——
            // 证据字段经本合并路径更新时，旧 .suggested 携带的 evidence 与
            // 新卡不再一致，保存会被 validateAssociation 以 invalidAssociation
            // 拒绝（用户只看到泛化保存失败、无任何指引）。证据变化即回落
            // 未选择；关联区经 .task(id: evidenceKey) 用新证据重新建议
            // （无信号不猜）。.existing（用户显式选择）不受字段编辑影响。
            let association: EncounterAssociation
            if case .suggested(_, let evidence) = old.encounterAssociation,
               evidence != EncounterResolver.evidenceKey(for: current) {
                association = .unselected
            } else {
                association = old.encounterAssociation
            }
            return MatchedCard(id: old.id, kind: current.kind, pageIndex: current.pageIndex,
                shared: reconcileFields(current.shared, old.shared), rows: rows,
                allFieldCoverage: current.allFieldCoverage, requiredCoverage: current.requiredCoverage,
                missingRequired: current.missingRequired, level: current.level,
                encounterAssociation: association)
        }
    }

    func pendingDraft(_ card: MatchedCard, source: ImportSource) -> PendingCardDraft {
        let incomplete = card.rows.flatMap { row in
            EntityCardProjection.invalidFields(in: card, row: row, calendar: Calendar(identifier: .gregorian)).map {
                IncompleteField(key: $0, label: Self.fieldLabel(forKey: $0), reason: "requires_review", rowId: row.id)
            }
        }
        return PendingCardDraft(patientId: source.patientId, sourceType: "ocr", sourceDocId: source.documentId,
            sourcePage: card.pageIndex, cardKind: card.kind, incompleteFields: incomplete,
            partialData: PendingCardPayload(card: card), rawText: source.pages.first { $0.index == card.pageIndex }?.text ?? "")
    }

    func encounterCandidates(patientId: UUID) async throws -> [EncounterResolver.Candidate] {
        guard let cardStore else { throw ImportError.storeUnavailable }
        return try await cardStore.encounterCandidates(patientId: patientId)
    }

    func confirmEntityCard(_ card: MatchedCard, confirmed: MatchedCard) async -> OCRCardStore.SaveResult? {
        guard let session = activeImport, let source = session.source, let cardStore,
               !session.isSaving, session.cards.contains(where: { $0.id == card.id }), confirmed.id == card.id,
              confirmed.kind == card.kind, confirmed.pageIndex == card.pageIndex else { return nil }
        session.isSaving = true; session.errorMessage = nil; session.notificationError = nil
        defer { session.isSaving = false }
        do {
            let result = try await cardStore.save(card: confirmed, patientId: source.patientId, documentId: source.documentId)
            if result.writtenCount > 0 { session.committedCards.insert(card.id) }
            pendingDidChange()
            if result.writtenCount > 0, card.kind == "metric_sample" { dataChange?.metricsChanged() }
            if let remaining = result.remainingCard, let index = session.cards.firstIndex(where: { $0.id == card.id }) { session.cards[index] = remaining }
            else { dequeueEntityCard(card) }
            do { try await notifyAfterSave(result) }
            catch { session.notificationError = L10n.ocrReviewNotificationFailed }
            return result
        } catch {
            session.errorMessage = L10n.entityCardSaveFailed
            setImportError(session.errorMessage)
            return nil
        }
    }

    private func notifyAfterSave(_ result: OCRCardStore.SaveResult) async throws {
        guard let scheduler else { throw ImportError.storeUnavailable }
        if result.resolved {
            try await scheduler.cancel(["pending-\(result.pendingCardId)"])
            try await scheduler.removeDelivered(["pending-\(result.pendingCardId)"])
        }
        else {
            try await scheduler.schedule(dose: "pending-\(result.pendingCardId)", at: Date().addingTimeInterval(3600),
                                         route: .pendingCard(result.pendingCardId))
        }
    }

    func deferEntityCard(_ card: MatchedCard) async -> Bool {
        guard let session = activeImport, let source = session.source, let pendingCardStore,
               !session.isSaving, session.cards.contains(where: { $0.id == card.id }) else { return false }
        session.isSaving = true; session.errorMessage = nil; session.notificationError = nil
        defer { session.isSaving = false }
        do {
            let id = try await pendingCardStore.upsert(pendingDraft(card, source: source))
            pendingDidChange()
            do {
                guard let scheduler else { throw ImportError.storeUnavailable }
                try await scheduler.schedule(dose: "pending-\(id)", at: Date().addingTimeInterval(3600), route: .pendingCard(id))
            } catch {
                session.notificationError = L10n.ocrReviewNotificationFailed
                return false
            }
            session.hadDeferrals = true
            dequeueEntityCard(card)
            return true
        } catch {
            session.errorMessage = L10n.entityCardSaveFailed; setImportError(session.errorMessage)
            return false
        }
    }

    func deferRemainingEntityCards() async -> Bool {
        guard let session = activeImport, !session.isBulkDeferring else { return false }
        session.isBulkDeferring = true
        defer { session.isBulkDeferring = false }
        for card in entityQueue {
            guard await deferEntityCard(card) else { return false }
        }
        return true
    }

    static func discarded(_ input: MatchedCard) -> MatchedCard {
        var card = input
        if card.rows.allSatisfy({ $0.fields.isEmpty }) {
            for index in card.shared.indices { card.shared[index].reject() }
        } else {
            for row in card.rows.indices {
                for field in card.rows[row].fields.indices where card.rows[row].fields[field].key != "metric_key" {
                    card.rows[row].fields[field].reject()
                }
            }
        }
        return card
    }

    func discardEntityCard(_ card: MatchedCard) async -> Bool {
        let result = await confirmEntityCard(card, confirmed: Self.discarded(card))
        return result?.resolved == true
    }

    func residualCard(_ pending: PendingCard) async throws -> MatchedCard {
        guard let cardStore else { throw ImportError.storeUnavailable }
        return try await cardStore.remainingCard(for: pending)
    }

    func resumePendingCard(_ pending: PendingCard) async -> MatchedCard? {
        if let session = retainedImport(for: pending), let card = session.cards.first(where: { $0.kind == pending.cardKind && $0.pageIndex == pending.sourcePage }) {
            return card
        }
        if let retained = pendingReviews[pending.id], !retained.completed { return retained.card }
        do {
            let card = try await residualCard(pending)
            guard let documentID = pending.sourceDocId,
                  let document = try await documentStore.fetch(id: documentID), document.patientId == pending.patientId,
                  ["active", "favorite"].contains(document.status) else { throw ImportError.unreadableMedia }
            let pages = try await documentStore.pages(documentId: documentID)
            guard pages.contains(where: { $0.index == card.pageIndex }) else { throw ImportError.unreadableMedia }
            let full = try pending.matchedCard()
            pendingReviews[pending.id] = PendingReview(pending: pending, card: card,
                pageCount: (pages.map(\.index).max() ?? 0) + 1,
                sharedCommitted: card.rows.count < full.rows.filter { !EntityCardProjection.isDiscarded($0, in: full) }.count)
            return card
        } catch {
            setImportError(L10n.ocrReviewLegacySourceMissing)
            return nil
        }
    }

    func retainedImport(for pending: PendingCard) -> ImportSession? {
        guard let cardID = pending.partialData.card?.id ?? UUID(uuidString: pending.id),
              let session = activeImport, let source = session.source,
              source.patientId == pending.patientId, source.documentId == pending.sourceDocId,
              session.cards.contains(where: { $0.id == cardID && $0.kind == pending.cardKind && $0.pageIndex == pending.sourcePage }) else { return nil }
        return session
    }

    func loadPendingCard(id: String) async throws -> PendingCard? {
        guard let pendingCardStore else { throw ImportError.storeUnavailable }
        return try await pendingCardStore.card(id: id)
    }

    func pageCount(documentId: UUID) async -> Int {
        do { return max(1, (try await documentStore.pages(documentId: documentId)).map(\.index).max().map { $0 + 1 } ?? 1) }
        catch { setImportError(L10n.sensitiveMedia_loadFailed); return 1 }
    }

    func completePendingCard(_ pending: PendingCard, confirmed: MatchedCard) async -> OCRCardStore.SaveResult? {
        if let retained = retainedImport(for: pending) {
            guard let current = retained.cards.first(where: { $0.id == confirmed.id }) else {
                setImportError(L10n.ocrReviewFinishCurrent)
                return nil
            }
            return await confirmEntityCard(current, confirmed: confirmed)
        }
        guard let documentID = pending.sourceDocId, let cardStore,
              confirmed.kind == pending.cardKind, confirmed.pageIndex == pending.sourcePage else { return nil }
        if pendingReviews[pending.id] == nil { _ = await resumePendingCard(pending) }
        guard let review = pendingReviews[pending.id], !review.isSaving else { return nil }
        review.isSaving = true; review.errorMessage = nil; review.notificationError = nil
        defer { review.isSaving = false }
        do {
            let result = try await cardStore.save(card: confirmed, patientId: pending.patientId,
                                                 documentId: documentID, pendingCardId: pending.id)
            if let remaining = result.remainingCard { review.card = remaining }
            review.writtenCount += result.writtenCount
            review.sharedCommitted = review.sharedCommitted || (result.writtenCount > 0 && !result.resolved)
            review.completed = result.resolved
            pendingDidChange()
            if result.writtenCount > 0, confirmed.kind == "metric_sample" { dataChange?.metricsChanged() }
            do { try await notifyAfterSave(result) }
            catch { review.notificationError = L10n.ocrReviewNotificationFailed }
            return result
        } catch {
            review.errorMessage = L10n.entityCardSaveFailed; setImportError(review.errorMessage)
            return nil
        }
    }

    func deferPendingCard(_ pending: PendingCard, edited: MatchedCard) async -> Bool {
        guard let documentID = pending.sourceDocId, let pendingCardStore,
              edited.kind == pending.cardKind, edited.pageIndex == pending.sourcePage else { return false }
        do {
            let source = ImportSource(documentId: documentID, patientId: pending.patientId,
                pages: [.init(index: edited.pageIndex, lines: pending.rawText.components(separatedBy: "\n"), fields: [])])
            let id = try await pendingCardStore.upsert(pendingDraft(edited, source: source))
            guard id == pending.id else { throw ImportError.unreadableMedia }
            pendingReviews[pending.id]?.card = edited
            pendingDidChange()
            do {
                guard let scheduler else { throw ImportError.storeUnavailable }
                try await scheduler.schedule(dose: "pending-\(id)", at: Date().addingTimeInterval(3600), route: .pendingCard(id))
            } catch {
                pendingReviews[pending.id]?.notificationError = L10n.ocrReviewNotificationFailed
                return false
            }
            return true
        } catch {
            pendingReviews[pending.id]?.errorMessage = L10n.entityCardSaveFailed
            setImportError(L10n.entityCardSaveFailed)
            return false
        }
    }

    func discardPendingCard(_ pending: PendingCard) async -> Bool {
        if let retained = retainedImport(for: pending) {
            guard let current = retained.cards.first(where: { $0.kind == pending.cardKind && $0.pageIndex == pending.sourcePage }) else { setImportError(L10n.ocrReviewFinishCurrent); return false }
            let discarded = await discardEntityCard(current)
            return discarded && retained.notificationError == nil
        }
        if let review = pendingReviews[pending.id], review.completed, review.notificationError != nil {
            do {
                guard let scheduler else { throw ImportError.storeUnavailable }
                try await scheduler.cancel(["pending-\(pending.id)"])
                try await scheduler.removeDelivered(["pending-\(pending.id)"])
                review.notificationError = nil
                return true
            } catch { return false }
        }
        if pending.sourceDocId != nil, pending.sourcePage != nil,
           let card = await resumePendingCard(pending) {
            let result = await completePendingCard(pending, confirmed: Self.discarded(card))
            return result?.resolved == true && pendingReviews[pending.id]?.notificationError == nil
        }
        // Old source-less rows cannot produce facts; explicit discard is still recoverable.
        guard let pendingCardStore else { return false }
        do {
            let current = try await pendingCardStore.card(id: pending.id)
            guard current?.patientId == pending.patientId else { throw ImportError.unreadableMedia }
            if current?.status != "resolved" || current?.note != "discarded" {
                try await pendingCardStore.markResolved(id: pending.id, by: "user", note: "discarded")
            }
            pendingDidChange()
            guard let scheduler else { throw ImportError.storeUnavailable }
            try await scheduler.cancel(["pending-\(pending.id)"])
            try await scheduler.removeDelivered(["pending-\(pending.id)"])
            return true
        } catch { setImportError(L10n.entityCardSaveFailed); return false }
    }
}
