import Foundation
import Domain
import Infrastructure
import Protocols

/// FR6.9 V3.61 页级多卡：文档卡确认后，各页匹配出的实体卡逐张进入队列——
/// 确认保存（写各自事实表 + 页级留痕）/ 稍后处理（pending_card + 1h 通知）/ 放弃本卡；
/// 待办卡续确认复用同一落库路径。BR-003：卡内字段在用户确认前不写任何事实表。
///
/// 页与卡的映射：`MatchedCard.pageIndex` ↔ `document_page.page_index`；写入侧
/// `metric_sample.source_ref = doc:<id>#p<n>`、`ocr_result.page_index = n`、`pending_card.source_page = n`。
extension DocumentsState {
    /// 单页识别分析结果（草稿态，随 ImportDraft 携带；不落库）
    struct PageAnalysis: Equatable {
        let index: Int
        let lines: [String]
        let failed: Bool
        /// 理解层字段（稳定键，供卡模板匹配）
        let fields: [FieldDraft]
        let documentTypeKey: String?
        var text: String { lines.joined(separator: "\n") }
    }

    /// 当前队首卡（视图以 `.sheet(item:)` 承载）
    var currentEntityCard: MatchedCard? { entityQueue.first }

    /// 「第 k/m 张」：k = 已处理 + 1，m = 本次文档卡确认后的总卡数
    var entityQueuePosition: (Int, Int) {
        (entityQueueTotal - entityQueue.count + 1, entityQueueTotal)
    }

    /// 确认保存：按卡类写事实表 + 页级留痕，成功出队。失败置 lastImportError、不出队。
    /// 返回 false 时卡仍在队首，视图可重试或改稍后处理。
    func confirmEntityCard(_ card: MatchedCard, confirmed: MatchedCard) async -> Bool {
        guard let documentId = entityQueueDocumentId, let patientId = entityQueuePatientId else { return false }
        let ok = await persist(confirmed, documentId: documentId, patientId: patientId)
        if ok { dequeueEntityCard(card) }
        return ok
    }

    /// 稍后处理：D 级快照进待办（精确到页）+ 1 小时后一次提醒（FR6.9 待办队列纪律），成功出队。
    func deferEntityCard(_ card: MatchedCard) async -> Bool {
        guard let pendingCards = pendingCardStore, let documentId = entityQueueDocumentId,
              let patientId = entityQueuePatientId else {
            setImportError(L10n.docImportFailed)
            return false
        }
        let incomplete = card.missingRequired.map {
            IncompleteField(key: $0.key, confidence: 0, reason: L10n.pendingCardReasonOcrMissing)
        } + card.rows.flatMap { row in
            row.missingRequired.map { IncompleteField(key: $0, confidence: 0, reason: L10n.entityCardRowSkipped) }
        }
        let draft = PendingCardDraft(patientId: patientId, sourceType: "ocr", sourceDocId: documentId,
                                     sourcePage: card.pageIndex, cardKind: card.kind,
                                     incompleteFields: incomplete, partialData: PendingCardPayload(card: card),
                                     rawText: entityQueuePageTexts[card.pageIndex] ?? "")
        do {
            let id = try await pendingCards.upsert(draft)
            // 通知失败不阻断建卡（待办已在首页聚合中心可见，FR6.9）
            try? await scheduler?.schedule(dose: "pending-\(id)", at: Date().addingTimeInterval(3600),   // try?-ok: 通知排程失败不回滚待办卡，聚合中心仍可达
                                           route: .pendingCard(id))
            dequeueEntityCard(card)
            dataChange?.documentSaved()
            return true
        } catch {
            setImportError(L10n.docImportFailed)
            return false
        }
    }

    /// 放弃本卡：不产生任何实体（识别文本已随文档页保留，BR-002）
    func discardEntityCard(_ card: MatchedCard) {
        dequeueEntityCard(card)
    }

    /// 队列级兜底（长 PDF）：剩余全部进待办，逐卡失败不阻断其余
    func deferRemainingEntityCards() async {
        for card in entityQueue {
            _ = await deferEntityCard(card)
        }
        if !entityQueue.isEmpty {
            // 写入失败的卡留在队列由用户处理；不静默清空
            return
        }
    }

    /// 待办卡续确认：从页文本 + 载荷还原实体卡（页文本缺失回落 raw_text）
    func resumePendingCard(_ card: PendingCard) async -> MatchedCard? {
        guard let documentId = card.sourceDocId else { return nil }
        let pageIndex = card.sourcePage ?? 0
        let shared = card.partialData.shared.sorted { $0.key < $1.key }.map { FieldDraft(key: $0.key, value: $0.value, confidence: 0.6) }
        let rows = card.partialData.rows.map { row in
            MatchedCardRow(fields: row.sorted { $0.key < $1.key }.map { FieldDraft(key: $0.key, value: $0.value, confidence: 0.6) })
        }
        let rules = CompletenessEvaluator.rules(for: card.kind)
        let covered = Set(shared.map(\.key) + rows.flatMap { $0.fields.map(\.key) })
        let required = rules.filter(\.isRequired)
        let missing = required.filter { !covered.contains($0.key) }
        let level = CompletenessEvaluator.assess(fields: shared + (rows.first?.fields ?? []), cardKind: card.kind).level
        let text = (try? await documentStore.pages(documentId: documentId))?.first { $0.index == pageIndex }?.text   // try?-ok: 页文本读取失败回落 raw_text
        prepareResume(patientId: card.patientId, pageIndex: pageIndex, text: text ?? card.rawText)
        return MatchedCard(kind: card.kind, pageIndex: pageIndex, shared: shared, rows: rows,
                           allFieldCoverage: rules.isEmpty ? 1 : Double(covered.intersection(rules.map(\.key)).count) / Double(rules.count),
                           requiredCoverage: required.isEmpty ? 1 : Double(required.count - missing.count) / Double(required.count),
                           missingRequired: missing, level: level)
    }

    /// 文档页数（卡头「第 p/N 页」；无页记录的旧文档回落 1）
    func pageCount(documentId: UUID) async -> Int {
        max(1, (try? await documentStore.pages(documentId: documentId))?.count ?? 1)   // try?-ok: 读取失败回落单页
    }

    /// 待办卡续确认落库 → resolved + 取消提醒
    func completePendingCard(_ card: PendingCard, confirmed: MatchedCard) async -> Bool {
        guard let documentId = card.sourceDocId else { return false }
        guard await persist(confirmed, documentId: documentId, patientId: card.patientId) else { return false }
        try? await pendingCardStore?.markResolved(id: card.id, by: "user")   // try?-ok: 完结标记失败卡仍在队列可重试，事实已落库
        try? await scheduler?.cancel(["pending-\(card.id)"])   // try?-ok: 通知取消失败不影响事实
        dataChange?.documentSaved()
        return true
    }

    /// 放弃待办卡：完结（note=discarded）+ 取消提醒；不产生实体
    func discardPendingCard(_ card: PendingCard) async {
        try? await pendingCardStore?.markResolved(id: card.id, by: "user", note: "discarded")   // try?-ok: 同上
        try? await scheduler?.cancel(["pending-\(card.id)"])   // try?-ok: 同上
        dataChange?.documentSaved()
    }

    // MARK: - 落库（单一路径：确认卡与待办续确认共用）

    private func persist(_ card: MatchedCard, documentId: UUID, patientId: UUID) async -> Bool {
        setImportError(nil)
        let calendar = Calendar.current
        do {
            switch card.kind {
            case "metric_sample":
                guard let trendStore else { throw EntityCardError.storeUnavailable }
                let projection = EntityCardProjection.hospitalSamples(from: card, calendar: calendar)
                guard !projection.samples.isEmpty else { throw EntityCardError.nothingToSave }
                _ = try await trendStore.addHospitalSamples(patientId: patientId, documentId: documentId,
                                                             pageIndex: card.pageIndex, samples: projection.samples)
                dataChange?.metricsChanged()
            case "encounter":
                guard let encounterStore else { throw EntityCardError.storeUnavailable }
                guard let draft = EntityCardProjection.encounterDraft(from: card, patientId: patientId, calendar: calendar) else {
                    throw EntityCardError.nothingToSave
                }
                let encounterId = try await encounterStore.upsert(encounter: draft)
                try await encounterStore.linkDocument(documentId: documentId, encounterId: encounterId)
            case "prescription":
                guard let prescriptionStore = prescriptionWriter else { throw EntityCardError.storeUnavailable }
                guard let intent = EntityCardProjection.prescriptionIntent(from: card) else { throw EntityCardError.nothingToSave }
                _ = try await prescriptionStore.create(patientId: patientId, documentFileId: documentId,
                                                       hospital: intent.hospital, doctor: intent.doctor,
                                                       adviceText: intent.adviceText)
            default:
                throw EntityCardError.unsupportedKind(card.kind)
            }
            // 页级留痕（FR6.1）：本卡确认的字段落 ocr_result(page_index)
            let fields = EntityCardProjection.candidateFields(from: card, labelFor: Self.fieldLabel(forKey:))
                .map { var f = $0; _ = f.confirm(); return f }
            try? await documentStore.saveOCRResult(documentId: documentId, pageIndex: card.pageIndex,   // try?-ok: 留痕失败不阻断主入库
                                                   fields: fields, engineVersion: "ocr-pipeline")
            dataChange?.documentSaved()
            return true
        } catch {
            setImportError(L10n.docImportFailed)
            return false
        }
    }

    enum EntityCardError: Error {
        case storeUnavailable, nothingToSave, unsupportedKind(String)
    }
}
