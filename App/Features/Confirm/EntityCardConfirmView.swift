import SwiftUI
import Domain
import Infrastructure
import Perception

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
    /// 原文呈现（2026-09-17 借鉴批）：一个 item 驱动的 sheet 取代原来的单个布尔——
    /// 扫描图与「原文行锚定」是同一条证据链上的两个视角，同一处呈现，避免两个 `.sheet`
    /// 挂同一视图（SwiftUI 只可靠地present一个）。
    private enum SourcePresentation: Identifiable {
        case scan
        case line(Int)
        /// 无锚定的全文选文面板（业主 2026-09-20 第 2 项：新增/无锚定字段也可
        /// 从识别文本选填——诚实纪律：无高亮，绝不冒充「这就是它的出处」）
        case fullText
        var id: String {
            switch self {
            case .scan: return "scan"
            case .line(let index): return "line-\(index)"
            case .fullText: return "fullText"
            }
        }
    }
    @State private var sourcePresentation: SourcePresentation?
    /// [看图] 入口携带的框级高亮（归一化 bbox；nil = 无高亮，fail-closed）
    @State private var scanHighlight: LayoutRect?
    /// 原文行点选引用的目标字段（key + 行身份 + 主卡草稿字段键）——从字段/清单入口打开
    /// 原文面板时登记，点行即回填该字段
    @State private var quoteTarget: QuoteTarget?
    private struct QuoteTarget {
        let key: String
        let rowId: UUID?
        /// 主卡草稿字段（`rowId == nil` 且本键非空 = 草稿字段；草稿区 [原文]
        /// 此前从未登记目标，点行静默无效果——2026-09-20 修复）
        let draftKey: String?
        init(key: String, rowId: UUID?, draftKey: String? = nil) {
            self.key = key; self.rowId = rowId; self.draftKey = draftKey
        }
    }
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

    // MARK: - 复核清单（2026-09-17 借鉴批）

    /// 一行字段（共享或行内）——把 13 个实参 + `.id` 锚点链收敛到一个函数里：
    /// 内联时它处在 List→ForEach→WithPerceptionTracking 三层嵌套中，类型检查器会放弃
    /// （CI 35166937683：unable to type-check this expression in reasonable time）。
    @ViewBuilder
    private func fieldRow(_ field: FieldDraft, index: Int, rowId: UUID?, required: Bool,
                          lines: [String]) -> some View {
        FieldConfirmRow(field: fieldBinding(index: index, rowID: rowId),
                        label: DocumentsDisplay.fieldLabel(forKey: field.key),
                        showUnit: false,
                        readOnly: rowId == nil ? sharedCommitted : false,
                        cardLevelConfirmation: true,
                        isRequired: required,
                        sourceLine: sourceLine(forKey: field.key, rowId: rowId, lines: lines),
                        onViewSource: { line in
                            quoteTarget = QuoteTarget(key: field.key, rowId: rowId)
                            scanHighlight = highlightRect(forLine: line, lines: lines)
                            sourcePresentation = .line(line)
                        },
                        // 字段旁 [选文]（业主 2026-09-20 第 2 项）：无锚定的新增字段
                        // 也能从识别文本选填——全文面板无高亮，不与 [原文] 锚定混淆
                        onViewSourceText: canViewScan ? {
                            quoteTarget = QuoteTarget(key: field.key, rowId: rowId)
                            scanHighlight = nil
                            sourcePresentation = .fullText
                        } : nil,
                        // 字段旁 [看图]（业主 2026-09-19 第 1 项）：原件有路径
                        // 才出（同 [原文] 诚实纪律——续办模式无原件不冒充）
                        onViewScan: canViewScan ? { openScanSheet(lines: lines, field: field, rowId: rowId) } : nil,
                        onRevise: { revise(index: index, rowID: rowId, value: $0) },
                        // round5 Q4：值类型单源——日期字段渲染选择器、数值字段数字键盘
                        valueKind: EntityCardProjection.valueKind(kind: card.kind, key: field.key))
            .id(CardConfirmationRules.anchorId(key: field.key, rowId: rowId))
    }

    /// 打开扫描原件面板并携带该字段锚定行的框级高亮（实测 bbox，fail-closed）
    private func openScanSheet(lines: [String], field: FieldDraft, rowId: UUID?) {
        if let line = sourceLine(forKey: field.key, rowId: rowId, lines: lines) {
            scanHighlight = highlightRect(forLine: line, lines: lines)
        } else {
            scanHighlight = nil
        }
        sourcePresentation = .scan
    }

    /// 队列模式（原件在导入会话内）才提供 [看图]；续办模式 pending 载荷
    /// 不携带原件 → 无入口（诚实纪律）。
    private var canViewScan: Bool {
        if case .queue = mode { return true }
        return false
    }

    /// 锚定行的框级高亮区（归一化坐标；越界/无实测版面 → nil 不画）
    private func highlightRect(forLine index: Int, lines: [String]) -> LayoutRect? {
        guard lines.indices.contains(index),
              case .queue = mode,
              let page = docs.activeImport?.source?.pages.first(where: { $0.index == card.pageIndex }),
              let blocks = page.layout?.blocks, blocks.indices.contains(index) else { return nil }
        let rect = blocks[index].bbox
        guard rect.x >= 0, rect.y >= 0, rect.width >= 0, rect.height >= 0,
              rect.x + rect.width <= 1, rect.y + rect.height <= 1 else { return nil }
        return rect
    }

    /// 原文行点选（多行按行序连接）→ 回填目标字段 **并记录出处**（round5 Q1：此前只写值——
    /// 新增字段引用后仍无 [原文] 锚、行原文不含引用行，业主实测「识别原文为空」；且旧路径经
    /// `revise → fillByUser` 把原值为空的新增字段顺手升 C，违反 V3.99 ①「引用不借 fillByUser 升 C」）。
    /// 语义与接线全部收敛 Domain `CardConfirmationRules.quote`：revise 留痕、D 级待确认、rawText/sourceLineIndex 落锚。
    private func quoteLine(_ lines: [String], _ indices: [Int]) {
        guard let target = quoteTarget, !saving, target.rowId != nil || target.draftKey != nil || !sharedCommitted else { return }
        quoteTarget = nil
        var current = card
        CardConfirmationRules.quote(&current, key: target.key, rowId: target.rowId, draftKey: target.draftKey,
                                    lines: lines, sourceLineIndices: indices)
        card = current
    }

    /// 复核清单段——同样从 List 体里拆出来（同一族类型检查压力）。
    @ViewBuilder
    private func reviewSection(_ items: [CardConfirmationRules.ReviewItem], proxy: ScrollViewProxy,
                               lines: [String]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in reviewQueueRow(item, proxy: proxy, lines: lines) }
            } header: {
                Text(L10n.entityCardReviewQueue(count: items.count,
                                                labels: ListFormatter.localizedString(byJoining: uniqueLabels(items))))
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityIdentifier("SP-12.entity.reviewQueue")
            }
        }
    }

    /// 本卡所在页的原文行（与 `FieldDraft.sourceLineIndex` **同一坐标系**）。
    /// 队列模式取自导入草稿的页；续办模式取自待办载荷的页文本——两处都按 `\n` 还原为行。
    private var pageLines: [String] {
        switch mode {
        case .queue: return docs.activeImport?.source?.pages.first { $0.index == card.pageIndex }?.lines ?? []
        case .resume(let review): return review.pending.rawText.components(separatedBy: "\n")
        }
    }

    /// 该字段的原文行（**没有锚定就返回 nil**——入口随之消失，绝不用整页原文冒充锚定）。
    /// 审查修复（每帧纪律）：行数组由 body 每帧拆一次传入——旧实现每行渲染
    /// 重拆整页 rawText / 重扫 pages 数组（击键热路径 N 次全文拆分）。
    private func sourceLine(forKey key: String, rowId: UUID?, lines: [String]) -> Int? {
        let field: FieldDraft? = rowId == nil
            ? card.shared.first { $0.key == key }
            : card.rows.first { $0.id == rowId }?.fields.first { $0.key == key }
        guard let line = field?.sourceLineIndex, lines.indices.contains(line) else { return nil }
        return line
    }

    /// 清单表头的字段名（同键多行只报一次——12 药处方不会把表头撑爆）。
    private func uniqueLabels(_ items: [CardConfirmationRules.ReviewItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            seen.insert(item.key).inserted ? DocumentsDisplay.fieldLabel(forKey: item.key) : nil
        }
    }

    /// 清单一项：就地处置（确认 / 补填），不要求用户先找到它。
    @ViewBuilder
    private func reviewQueueRow(_ item: CardConfirmationRules.ReviewItem, proxy: ScrollViewProxy,
                                lines: [String]) -> some View {
        let label = DocumentsDisplay.fieldLabel(forKey: item.key)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let rowId = item.rowId,
                   let position = card.rows.firstIndex(where: { $0.id == rowId }).map({ $0 + 1 }) {
                    Text(L10n.entityCardRowIndex(position)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.isMissing {
                // 缺 = 另一条路（业界把「缺」与「低置信」分开处理是明确口径）：
                // 与既有的「缺少 X，点此填写」同一动作——补上字段并滚到它。
                Button(L10n.entityCardMissingRequired(label)) {
                    appendField(item.key, rowID: item.rowId)
                    // 锚点 id 与「缺少 X，点此填写」那条按钮**同构**：键缺席时滚到按钮、已存在时滚到字段行，
                    // 同一帧内恒有落点（不必等重渲染）。
                    withAnimation { proxy.scrollTo(item.id, anchor: .center) }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("SP-12.review.fill.\(item.id)")
            } else if item.severity == 2 {
                // 歧义项**不给就地确认**：有候选就必须先做选择（业主 2026-09-17 裁定「挡」），
                // 一键确认会让默认胜出值溜过去——只跳到字段处的候选选择器。
                Button(L10n.entityCardReviewChoose) {
                    withAnimation { proxy.scrollTo(item.id, anchor: .center) }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("SP-12.review.choose.\(item.id)")
            } else {
                Button(L10n.commonConfirm) { confirmField(item) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("SP-12.review.confirm.\(item.id)")
                if let line = sourceLine(forKey: item.key, rowId: item.rowId, lines: lines) {
                    Button(L10n.entityCardReviewSource) {
                        quoteTarget = QuoteTarget(key: item.key, rowId: item.rowId)
                        scanHighlight = highlightRect(forLine: line, lines: lines)
                        sourcePresentation = .line(line)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("SP-12.review.source.\(item.id)")
                }
            }
        }
        .frame(minHeight: 44)
    }

    /// 清单里的就地确认：按 rowId 定位到共享面或行内字段，与行内 [确认] 完全同语义。
    private func confirmField(_ item: CardConfirmationRules.ReviewItem) {
        guard !saving else { return }
        var current = card
        if let rowId = item.rowId {
            guard let r = current.rows.firstIndex(where: { $0.id == rowId }),
                  let i = current.rows[r].fields.firstIndex(where: { $0.key == item.key }) else { return }
            _ = current.rows[r].fields[i].confirm()
        } else {
            guard let i = current.shared.firstIndex(where: { $0.key == item.key }) else { return }
            _ = current.shared[i].confirm()
        }
        card = current
    }
    /// 必填集自 `CardKindRegistry` 单一事实源（与 `CardConfirmationRules.confirmingAllFields` 同源）——
    /// 视图不复制数字/键表。
    private var sharedRequired: Set<String> { Set(CardKindRegistry.entry(for: card.kind)?.sharedRequired ?? []) }
    private func rowRequired(_ row: MatchedCardRow) -> Set<String> {
        let entry = CardKindRegistry.entry(for: card.kind)
        // 空行 = 「表头即实体」（票据页无明细行）：不受行级必填约束（与 `invalidFields` 同口径）
        return (entry?.allowsEmptyRows == true && row.fields.isEmpty) ? [] : Set(entry?.rowRequired ?? [])
    }
    /// 缺失共享键（2026-09-20 修复：由 body 已算的 `validation` 字典派生——
    /// 旧实现每帧对全部行重跑一遍 invalid() 投影，2N 次全卡投影/帧）。
    private func missingShared(reviewed: MatchedCard, validation: [UUID: [String]]) -> [String] {
        Set(validation.values.flatMap { $0 }).filter { key in
            !rowKeys.contains(key) && key != "card_kind" && !card.shared.contains { $0.key == key }
        }.sorted()
    }
    private func canSave(reviewed: MatchedCard, validation: [UUID: [String]]) -> Bool {
        // 审查修复（每帧纪律）：旧实现 save 闸门再跑一遍 invalid()（每帧第四遍
        // 全卡投影）——直接消费 body 已算的 validation 字典。
        guard !saving, card.rows.allSatisfy({ (validation[$0.id] ?? []).isEmpty || EntityCardProjection.isDiscarded($0, in: card) }) else {
            return false
        }
        // v27 §0.4：主卡草稿随卡同事务落库——草稿须字段全部已确认（卡级确认后仍缺的 = 必填/低置信未逐项确认）且日期可解析，
        // 与 store `HubDraft.isComplete` 同口径；否则保存按钮禁用（草稿区显示补填/未确认提示，用户不致只见灰按钮）。
        if case .newHub(let draft) = reviewed.encounterAssociation {
            return draft.isComplete(calendar: Self.gregorianCalendar)
        }
        return true
    }

    /// Calendar 静态复用（旧实现每行每帧新建一个实例）
    private static let gregorianCalendar = Calendar(identifier: .gregorian)

    /// 卡级确认延伸到主卡草稿——规则主体在 `CardConfirmationRules.confirmingDraft`
    /// （Domain 单一事实源，结构轮 2026-09-15：BR-003 D→C 谓词此前在模型两处 + 本视图
    /// 一处各写一份，视图不再持有业务规则）。store 侧再按 BR-003 校验一次。
    static func confirmingDraftFields(_ card: MatchedCard) -> MatchedCard {
        CardConfirmationRules.confirmingDraft(card)
    }
    /// 文档稳定键：队列模式随导入会话（commitDraft 写入）；续办模式的待办卡不携带 → nil（主卡草稿 kind 缺省门诊）。
    private var sessionDocumentTypeKey: String? {
        if case .queue(let session) = mode { return session.documentTypeKey }
        return nil
    }
    private var resumeError: String? {
        if case .resume(let review) = mode { return review.notificationError ?? review.errorMessage }
        return nil
    }
    /// 子项目 D · D4-2：续办模式的「资料建议」宿主键（队列模式由 ImportReviewSessionView 宿主呈现）。
    private var resumePresenterKey: String? {
        if case .resume(let review) = mode { return DocumentsState.suggestionPresenterKey(pending: review.pending) }
        return nil
    }
    private var suggestionsPending: Bool {
        resumePresenterKey != nil && docs.profileSuggestionBatch?.presenterKey == resumePresenterKey
    }
    private var completionKey: String {
        if case .resume(let review) = mode { return "\(review.completed)-\(saving)-\(resumeError != nil)-\(partialCount != nil)-\(suggestionsPending)" }
        return "queue"
    }

    var body: some View {
        WithPerceptionTracking {
            // 审查修复（每帧纪律）：confirmation 投影每帧只求值一次——旧实现
            // invalid(_:) 内部各自重建全卡投影，validation/missingShared/canSave
            // 三处合计 ~3N 次全卡拷贝（每次击键触发），N 行卡明显可感知。
            let reviewed = Self.confirmingDraftFields(card.confirmingAllFields())
            let validation = Dictionary(uniqueKeysWithValues: card.rows.map { ($0.id, invalid($0, reviewed: reviewed)) })
            // 必填逐项确认（FR6.9 2026-09-17 裁定）：必填不参与批量 → 保存闸门要求逐项；
            // 这里如实报出还差哪些（同一判据的 Domain 单一事实源），避免用户只见灰按钮。
            // 2026-09-17 借鉴批：清单按**风险**排序（缺 → 必填未确认 → 歧义 → 低置信），
            // 不按文档顺序——业界复核台的通行做法（用户从最挡路的一项开始，处置完一项清单短一项，
            // 这就是「确认并下一个」，不需要焦点态）。渲染顺序（文档顺序）不受影响。
            let reviewItems = CardConfirmationRules.reviewQueue(card)
            // 每帧一次的派生值（审查修复，击键热路径）：页行数组 / 缺失共享键 /
            // 失效共享键集合——旧实现每行渲染各重算一遍（N 次全文拆分 +
            // N 次全卡投影扫描 + O(N²) 成员判定）。
            let lines = pageLines
            let invalidSharedKeys = Set(validation.values.flatMap { $0 })
            let missingSharedKeys = missingShared(reviewed: reviewed, validation: validation)
            ScrollViewReader { proxy in
                // 跳转锚点（复核清单 → 字段）：行 id 与清单项 id 同一构造（Domain `anchorId`）。
                List {
                    Section {
                        OCRReviewOwnerRow(patientId: patientId)
                        HStack {
                            Text(L10n.entityCardHeaderPage(card.pageIndex + 1, max(pageCount, card.pageIndex + 1)))
                            if let position { Text(L10n.entityCardHeaderIndex(position.0, position.1)) }
                            Spacer()
                            GradeBadge(grade: "D")
                        }.font(.caption)
                        Button {
                            scanHighlight = nil
                            sourcePresentation = .scan
                        } label: {
                            Label(L10n.pendingCardViewSource, systemImage: "doc.text.magnifyingglass").frame(minHeight: 44)
                        }.buttonStyle(.borderless)
                    } footer: { Text(L10n.docConfirmHint) }

                    // v27 §0.4 改判：主卡草稿区**先于**关联区呈现（无可挂接主卡时随本卡新建；D 级、逐字段确认、同事务落库）
                    ParentDraftSection(card: $card, patientId: patientId, readOnly: saving || sharedCommitted,
                                   onViewSource: { line, key in
                                       // 范围校验已在草稿区完成；此处只负责呈现。
                                       // 2026-09-20 修复：登记草稿字段引用目标——此前
                                       // 草稿区 [原文] 不登记目标，点行静默无效果。
                                       quoteTarget = QuoteTarget(key: key, rowId: nil, draftKey: key)
                                       scanHighlight = nil
                                       sourcePresentation = .line(line)
                                   },
                                   lines: lines)
                    EncounterAssociationSection(card: $card, patientId: patientId, readOnly: saving || sharedCommitted,
                                                documentTypeKey: sessionDocumentTypeKey)

                    Section(L10n.entityCardSharedSection) {
                        if sharedCommitted { Text(L10n.homeCaptureSaved).font(.caption).foregroundStyle(.secondary) }
                        ForEach(card.shared.indices, id: \.self) { index in
                            // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                            WithPerceptionTracking {
                                // 字段行经 `fieldRow` 出列：内联版本（13 个实参 + `.id` 链）在
                                // List→ForEach→WithPerceptionTracking 三层嵌套里把类型检查器压垮
                                // （CI 35166937683 实证：unable to type-check in reasonable time）。
                                fieldRow(card.shared[index], index: index, rowId: nil,
                                         required: sharedRequired.contains(card.shared[index].key), lines: lines)
                                if card.shared[index].isConfirmed, invalidSharedKeys.contains(card.shared[index].key) {
                                    Text(L10n.ocrReviewInvalidField).font(.caption)
                                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                                }
                            }
                        }
                        ForEach(missingSharedKeys, id: \.self) { key in missingButton(key: key, rowID: nil) }
                        addFieldMenu(rowID: nil, present: Set(card.shared.map(\.key)))
                    }

                    ForEach(Array(card.rows.enumerated()), id: \.element.id) { offset, row in
                        if !row.fields.isEmpty || !rowKeys.isEmpty {
                            Section {
                                ForEach(row.fields.indices.filter { row.fields[$0].key != "metric_key" }, id: \.self) { index in
                                    fieldRow(row.fields[index], index: index, rowId: row.id,
                                             required: rowRequired(row).contains(row.fields[index].key), lines: lines)
                                    if row.fields[index].isConfirmed && validation[row.id]?.contains(row.fields[index].key) == true {
                                        Text(L10n.ocrReviewInvalidField).font(.caption)
                                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                                    }
                                }
                                ForEach((validation[row.id] ?? []).filter { key in rowKeys.contains(key) && !row.fields.contains(where: { $0.key == key }) }, id: \.self) { key in
                                    missingButton(key: key, rowID: row.id)
                                }
                                addFieldMenu(rowID: row.id, present: Set(row.fields.map(\.key)))
                            } header: { Text(L10n.entityCardRowIndex(offset + 1)) }
                        }
                    }
                    if !missingSharedKeys.isEmpty || validation.values.contains(where: { !$0.isEmpty }) {
                        Section { Text(L10n.docConfirmHint).font(.caption).foregroundStyle(.secondary) }
                    }
                    reviewSection(reviewItems, proxy: proxy, lines: lines)
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
                .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（2026-09-23 打磨轮）
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.entityCardKindName(card.kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.entityCardConfirmSave) { save(reviewed: reviewed, validation: validation) }
                        .disabled(!canSave(reviewed: reviewed, validation: validation))
                        .accessibilityIdentifier("SP-12.entity.confirm")
                }
                ToolbarItemGroup(placement: .keyboard) { OCRKeyboardDismissButton() }
            }
            .interactiveDismissDisabled()
            .sheet(item: $sourcePresentation) { presentation in
                switch presentation {
                case .scan:
                    DocumentSourcePageView(documentId: documentId, patientId: patientId,
                                           pageIndex: card.pageIndex, highlight: scanHighlight)
                case .line(let index):
                    SourceLineSheet(lines: lines, highlight: index, onPick: quoteLine)
                case .fullText:
                    SourceLineSheet(lines: lines, highlight: nil, onPick: quoteLine)
                }
            }
            .confirmationDialog(L10n.entityCardLater, isPresented: $showLater, titleVisibility: .visible) {
                Button(L10n.docConfirmSkipConfirm) { deferCard() }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .confirmationDialog(L10n.entityCardDiscard, isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L10n.entityCardDiscard, role: .destructive) { discard() }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .alert(partialAlertTitle,
                   isPresented: partialAlertBinding) {
                Button(L10n.onboard_gotIt, role: .cancel) {}
            } message: { Text(partialAlertMessage) }
            // 「资料建议」表单（续办模式宿主；alert 可见时暂不弹）。整卡处理完毕才采集，故与「已保存 N 条」不并发。
            .profileSuggestionHost(presenterKey: resumePresenterKey ?? "", enabled: suggestionsHostEnabled)
            .task(id: completionKey) {
                if shouldDismissCompletedResume { dismiss() }
            }
        }
    }

    /// alert 标题（提取子表达式 + 显式类型——型检预算分解，CI 35439281475/35440032364）。
    private var partialAlertTitle: String {
        resumeError != nil ? L10n.docConfirmSaveFailedTitle : L10n.homeCaptureSaved
    }

    /// alert 消息（同上）。
    private var partialAlertMessage: String {
        resumeError ?? L10n.ocrReviewPartialSaved(partialCount ?? 0)
    }

    /// alert 可见性绑定（同上；显式类型压缩推断成本）。
    private var partialAlertBinding: Binding<Bool> {
        Binding(get: { resumeError != nil || partialCount != nil },
                set: { dismissPartialAlert($0) })
    }

    /// alert 关闭回调（从 set 闭包提取——型检预算分解，CI 35439281475）。
    private func dismissPartialAlert(_ showing: Bool) {
        if !showing {
            partialCount = nil
            if case .resume(let review) = mode { review.errorMessage = nil; review.notificationError = nil }
        }
    }

    /// 「资料建议」宿主启用条件（提取子表达式，同型检预算分解）。
    private var suggestionsHostEnabled: Bool {
        resumePresenterKey != nil && resumeError == nil && partialCount == nil
    }

    /// 续办卡整卡处理完毕即退场（提取子表达式，同型检预算分解）。
    private var shouldDismissCompletedResume: Bool {
        if case .resume(let review) = mode { return review.completed && !saving && resumeError == nil && !suggestionsPending }
        return false
    }

    private func invalid(_ row: MatchedCardRow, reviewed: MatchedCard) -> [String] {
        // 2026-09-20 修复：复用静态 Calendar（旧实现每行每帧新建实例——静态常量
        // 存在却从未接入，击键热路径 N 次实例化）
        EntityCardProjection.invalidFields(in: reviewed,
            row: reviewed.rows.first { $0.id == row.id } ?? row, calendar: Self.gregorianCalendar)
    }

    private func missingButton(key: String, rowID: UUID?) -> some View {
        Button(L10n.entityCardMissingRequired(DocumentsDisplay.fieldLabel(forKey: key))) { appendField(key, rowID: rowID) }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(rowID == nil && sharedCommitted)
            // 与已存在字段的锚点 id **同构**：键缺席时是这条按钮，补上后是那条字段行——
            // 复核清单的跳转目标因此恒存在，不必关心用户此刻处在哪种形态。
            .id(CardConfirmationRules.anchorId(key: key, rowId: rowID))
    }

    /// 「添加字段」目录（FR6.9 · 子项目 D，解 O5）：`CardKindRegistry.optionalCatalog` − 卡内已有键；
    /// 共享面只列表头键（rowLevel=false），行内列行级键。目录与建卡门槛分离（可选键不进规则表分母）。
    /// 追加的是**空的 D 级可编辑字段**：用户填值并经卡级确认后才升 C（BR-003），空值保存时按缺失处理。
    @ViewBuilder
    private func addFieldMenu(rowID: UUID?, present: Set<String>) -> some View {
        let catalog = CardKindRegistry.optionalCatalog(kind: card.kind, present: present, rowLevel: rowID != nil)
        if !catalog.isEmpty {
            Menu {
                ForEach(catalog, id: \.self) { key in
                    Button(DocumentsDisplay.fieldLabel(forKey: key)) { appendField(key, rowID: rowID) }
                }
            } label: {
                Label(L10n.entityCardAddField, systemImage: "plus.circle").frame(minHeight: 44)
            }
            .disabled(rowID == nil && sharedCommitted)
            .accessibilityIdentifier(rowID == nil ? "SP-12.addField" : "SP-12.addField.row")
        }
    }

    /// 追加一条空字段（缺必填补填与「添加字段」共用）：同键已存在则不重复追加。
    private func appendField(_ key: String, rowID: UUID?) {
        guard !saving, rowID != nil || !sharedCommitted else { return }
        var current = card
        let field = FieldDraft(key: key, value: "", confidence: 1)
        if let rowID, let row = current.rows.firstIndex(where: { $0.id == rowID }) {
            if !current.rows[row].fields.contains(where: { $0.key == key }) { current.rows[row].fields.append(field) }
        } else if rowID == nil, !current.shared.contains(where: { $0.key == key }) { current.shared.append(field) }
        card = current
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

    private func save(reviewed: MatchedCard, validation: [UUID: [String]]) {
        // 2026-09-20 修复：直接消费 body 本帧已算的 validation 字典——旧实现
        // 保存时重算一遍全卡投影（N 行 × invalidFields + N 个 Calendar 实例）
        guard canSave(reviewed: reviewed, validation: validation) else { return }
        // FR6.9 卡级确认：保存即批量确认合格字段（非拒绝 ∧ 有值 ∧ ≥0.6 ∧ 无歧义 ∧ 非必填，
        // 单一事实源 `CardConfirmationRules`）；**必填与低置信均须逐项确认**（2026-09-17 业主裁定），
        // 缺必填行原样进待办/剩余卡。
        // v27：主卡草稿字段同一动作升 C（store 同事务先建主卡再写子卡；任一失败整体回滚，BR-003）。
        let snapshot = Self.confirmingDraftFields(card.confirmingAllFields())
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
        WithPerceptionTracking {
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
                                LabeledContent(DocumentsDisplay.fieldLabel(forKey: key),
                                               value: DocumentsDisplay.fieldValueDisplay(forKey: key, value: value))
                            }
                            ForEach(Array(pending.partialData.rows.enumerated()), id: \.offset) { index, row in
                                VStack(alignment: .leading) {
                                    Text(L10n.entityCardRowIndex(index + 1)).font(.caption)
                                    ForEach(row.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                        LabeledContent(DocumentsDisplay.fieldLabel(forKey: key),
                                                       value: DocumentsDisplay.fieldValueDisplay(forKey: key, value: value))
                                    }
                                }
                            }
                        }
                        Section(L10n.pendingCardRawText) { Text(pending.rawText).textSelection(.enabled) }
                    }
                    .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出（2026-09-23 打磨轮）
                } else if loadFailed {
                    VLUnavailableView {
                        Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                    } actions: { Button(L10n.retry) { Task { await load() } } }
                } else if loaded {
                    VLUnavailableView(L10n.pendingCardNotFound, systemImage: "tray")
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
