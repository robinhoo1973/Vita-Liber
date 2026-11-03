import SwiftUI
import Domain
import Infrastructure
import Perception

/// 聊天媒体详情（2026-10-29 批三 · mock v4 对照落地；2026-10-30 业主五点复核后）。
///
/// 结构对齐真机修订（2026-11-02 业主）：
/// - 上=媒体卡：标题 + 附件/页数 + 上传缩略图（点图看原件）+ 来源徽章。
/// - 下=三个 tab：识别原文（按页） / 数据信息元（每字段一张卡，可改值/引原文/
///   看裁片/去核对） / 医疗信息卡片（「需要修改」在前、「已确认」在后；BR-003 页脚）。
/// - 工具栏「更多操作」→ 查看原图 / 重新识别 / 资料信息（存储位置）/ 导出副本。
/// 三值状态纪律：文本/已确认卡/待核对卡/文档行各自 loading/loaded/failed，
/// 读取失败必须可见并可重试——不得把失败涂成空态。
struct ChatMediaDetailView: View {
    let documentId: UUID
    let patientId: UUID
    let title: String
    /// 附件数（2026-10-30 业主：缩略图按附件一张——合并导入的页序=附件序；
    /// 单份多页 PDF 仍只出 1 张）。nil=未知，回落文档页数。
    var attachmentCount: Int? = nil
    /// 每个附件在合并 PDF 中的起始页（0 基；2026-10-30 多页 PDF 页偏移批）。
    /// nil=旧快照——按「附件序=页序」回落，与历史行为一致。
    var attachmentPageOffsets: [Int]? = nil
    /// 会话身份（2026-10-30）：详情内「导出副本」沿用聊天会话目录；
    /// 历史/无会话上下文时为 nil（回落直接导入月桶）。
    var conversationID: UUID?
    var conversationTitle: String?

    @Environment(DocumentsState.self) private var docs
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    /// 2026-11-03 真机：缩略图在上，下面三个 tab——识别原文 / 数据信息元 / 医疗信息卡片。
    private enum Tab: String, CaseIterable, Identifiable {
        case text, elements, cards
        var id: String { rawValue }
        var label: String {
            switch self {
            case .text: return L10n.pendingCardRawText
            case .elements: return L10n.chatMediaTabElements
            case .cards: return L10n.chatMediaTabCards
            }
        }
    }

    /// 数据信息元的分组投影：每个字段一张卡，保留卡片/行/原文锚点。
    private struct ElementRow: Identifiable {
        let group: ChatMediaElementGroup
        let cardID: String
        let pageIndex: Int
        let title: String
        let subtitle: String
        let editable: Bool
        /// 共享字段在部分行已提交后不得再行内改写：事实行已按旧共享值落库，
        /// store 的 `mergeDraft` 会拒绝这类快照（committedDataChanged）。
        /// 与其让保存必然失败，不如在入口处如实锁定并引导去卡片页。
        let sharedLocked: Bool
        var id: String { group.id }
    }

    private struct CommittedCard: Identifiable, Equatable {
        let kind: String
        let id: UUID
    }

    private enum TextState: Equatable {
        case loading
        case pages([DocumentStore.Page])
        case legacy(text: String)
        case empty
        case failed
    }

    private enum CardsState: Equatable {
        case loading
        case loaded([CommittedCard])
        case failed
    }

    private enum PendingState: Equatable {
        case loading
        case loaded([PendingCard])
        case failed
    }

    private enum DocState: Equatable {
        case loading
        case loaded(grade: String)
        case failed
    }

    /// 单一 sheet 槽（2026-10-30）：原图 / 待核对卡 / 更多操作共用一次
    /// presentation，避免同视图多 `.sheet` 在 iOS 16 相互覆盖。
    private enum DetailSheet: Identifiable {
        case original(page: Int)
        case pending(id: String)
        case actions
        case sourceLine(cardID: String, fieldKey: String, rowID: UUID?,
                        pageIndex: Int, lines: [String], canQuote: Bool)
        case sourceCrop(pageIndex: Int, lineIndex: Int?, text: String)

        var id: String {
            switch self {
            case .original(let page): return "original-\(page)"
            case .pending(let id): return "pending-\(id)"
            case .actions: return "actions"
            case .sourceLine(let cardID, let key, let rowID, _, _, _):
                return "line-\(cardID)-\(key)-\(rowID?.uuidString ?? "shared")"
            case .sourceCrop(let page, let line, _):
                return "crop-\(page)-\(line ?? -1)"
            }
        }
    }

    @State private var tab: Tab = .elements
    @State private var textState: TextState = .loading
    /// 识别原文页签的当前页（按页显示，底部翻页）。
    @State private var textPageIndex = 0
    @State private var cardsState: CardsState = .loading
    @State private var pendingState: PendingState = .loading
    @State private var docState: DocState = .loading
    /// 缩略图条共享的文档元数据（一次读行/解析 meta；2026-10-30 效率批）。
    @State private var thumbPreload: ChatMediaThumbnail.Preloaded?
    @State private var detailSheet: DetailSheet?
    /// 数据信息元的编辑草稿（cardID → 完整 MatchedCard）；仅 OCR 卡可编辑。
    @State private var elementDrafts: [String: MatchedCard] = [:]
    @State private var dirtyCards: Set<String> = []
    @State private var savedCards: Set<String> = []
    @State private var savingCards: Set<String> = []
    /// 在途保存任务：重复点按（保存/去核对）复用同一次落库，不静默丢弃。
    @State private var saveTasks: [String: Task<Bool, Never>] = [:]
    @State private var elementSaveError: String?
    /// 保存失败时仍允许打开现有核对卡，避免共享字段/已提交行冲突造成死路。
    @State private var pendingCardAfterSaveFailure: String?
    /// 有未保存修正时关闭确认。
    @State private var showDiscardEdits = false
    /// 有识别文本的页（避免每次键入都在 body 里整页 split 原文）。
    @State private var pagesWithText: Set<Int> = []
    /// 数据信息元手风琴：同一时刻只展开一组；首次加载默认第一组。
    @State private var expandedElementGroup: String?
    @State private var didInitializeExpandedGroup = false
    /// 关闭 sheet 后的刷新范围：看原图不重读；待核对卡只刷卡片区+文档徽章
    /// （正文/滚动位不塌回 loading）；更多操作可能重新识别，整页重读。
    @State private var dismissRefresh: DismissRefresh = .none

    private enum DismissRefresh { case none, cards, all }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        mediaCard
                        tabPicker
                        // 页级识别状态属于整份文档：两个页签都必须看见，
                        // 否则卡片页会让人误以为全部页都已识别。
                        pageStatusNotices
                        tabContent
                    }
                    .padding(16)
                }
                .navigationTitle(L10n.chatMediaResultTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if dirtyCards.isEmpty { dismiss() }
                            else { showDiscardEdits = true }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(L10n.commonBack)
                        .accessibilityIdentifier("chat.mediaDetail.back")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismissRefresh = .all
                            detailSheet = .actions
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel(L10n.chatMediaMoreActions)
                        .accessibilityIdentifier("chat.mediaDetail.more")
                    }
                }
                .task(id: documentId) { await loadBasics() }
                // OCR 收尾后卡才从导入会话转入待办表（聊天页释放导入槽）；
                // 详情若先打开，必须在该时点重读两区，不能停在空态。
                .onChangeCompat(of: docs.activeImport?.source?.documentId) { _, _ in
                    Task { await loadCardsAndGrade() }
                }
                // 导入收尾把卡转待办后才写 pending_card；只等 activeImport
                // 变化会漏掉「导入槽已释放但卡稍后落库」的时序，详情保持空态。
                .onChangeCompat(of: docs.pendingVersion) { _, _ in
                    Task { await loadCardsAndGrade() }
                }
                .sheet(item: $detailSheet, onDismiss: handleSheetDismiss) { sheet in
                    sheetContent(sheet)
                }
                // 缩略图即原图内容：退后台时随系统隐私遮罩隐去（与原件页同纪律）。
                .privacySensitive(scenePhase != .active)
                .interactiveDismissDisabled(!dirtyCards.isEmpty)
                .alert(L10n.chatMediaElementSaveFailed,
                       isPresented: Binding(get: { elementSaveError != nil },
                                            set: { if !$0 { elementSaveError = nil } })) {
                    if let id = pendingCardAfterSaveFailure {
                        Button(L10n.chatMediaGoConfirm) {
                            elementSaveError = nil
                            pendingCardAfterSaveFailure = nil
                            dismissRefresh = .cards
                            detailSheet = .pending(id: id)
                        }
                        Button(L10n.commonCancel, role: .cancel) {
                            elementSaveError = nil
                            pendingCardAfterSaveFailure = nil
                        }
                    } else {
                        Button(L10n.onboard_gotIt, role: .cancel) { elementSaveError = nil }
                    }
                } message: {
                    Text(elementSaveError ?? "")
                }
                .confirmationDialog(L10n.chatMediaDiscardEditsTitle,
                                    isPresented: $showDiscardEdits,
                                    titleVisibility: .visible) {
                    Button(L10n.chatMediaDiscardEditsAction, role: .destructive) {
                        dismiss()
                    }
                    Button(L10n.commonCancel, role: .cancel) {}
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: DetailSheet) -> some View {
        switch sheet {
        case .original(let page):
            DocumentSourcePageView(documentId: documentId, patientId: patientId,
                                   pageIndex: page)
        case .pending(let id):
            NavigationStack {
                PendingCardResumeRouteView(cardId: id)
            }
        case .actions:
            ChatMediaActionsSheet(documentId: documentId, patientId: patientId,
                                   title: title, pageCount: totalPageCount,
                                   conversationID: conversationID,
                                   conversationTitle: conversationTitle)
        case .sourceLine(let cardID, let fieldKey, let rowID, _, let lines, let canQuote):
            SourceLineSheet(lines: lines,
                            highlight: elementSourceLine(cardID: cardID, key: fieldKey, rowID: rowID),
                            onPick: canQuote ? { (lines: [String], indices: [Int]) in
                                quoteElement(cardID: cardID, fieldKey: fieldKey,
                                             rowID: rowID, lines: lines, indices: indices)
                            } : nil)
        case .sourceCrop(let pageIndex, let lineIndex, let sourceText):
            ChatMediaSourceCropView(documentId: documentId, patientId: patientId,
                                     pageIndex: pageIndex, lineIndex: lineIndex,
                                     sourceText: sourceText)
        }
    }

    private func handleSheetDismiss() {
        let refresh = dismissRefresh
        dismissRefresh = .none
        switch refresh {
        case .none:
            return
        case .cards:
            Task { await loadCardsAndGrade() }
        case .all:
            Task { await loadBasics() }
        }
    }

    // MARK: - 媒体卡（每张一个缩略图）

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                documentStatusTag
                Spacer(minLength: 0)
            }
            Text(L10n.chatMediaSummary(thumbnailCount, totalPageCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
            thumbnailStrip
                .padding(.top, 4)
            if case .failed = docState {
                unavailableBlock { Task { await loadBasics() } }
                    .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 标题旁简化来源态：只留「待确认/已确认」，不再重复 D + 识别未确认 + 待确认。
    @ViewBuilder
    private var documentStatusTag: some View {
        if case .loaded(let grade) = docState {
            if grade == GradeBadge.gradeConfirmed {
                PillBadge(text: L10n.assistantMediaConfirmed, style: .success, bold: true)
            } else if grade == GradeBadge.gradeMachineUnconfirmed {
                PillBadge(text: L10n.gradeBadgePending, style: .warning, bold: true)
            }
        }
    }

    /// 页状态 → 文案：识别原文页头与页级提示共用一份映射（避免两处漂移）。
    private func pageStatusText(_ status: String) -> String? {
        switch status {
        case "no_text": return L10n.assistantMediaPageNoText
        case "failed": return L10n.assistantMediaPageFailed
        case "skipped": return L10n.assistantMediaPageSkipped
        default: return nil
        }
    }

    /// 文档真实页数（识别文本逐页数；读取完成前按 1）。
    private var totalPageCount: Int {
        switch textState {
        case .pages(let pages): return max(1, pages.count)
        case .legacy, .loading, .empty, .failed: return 1
        }
    }

    /// 已落页的附件起始页（读到逐页文本后只保留真实存在的页；空则回落旧口径）。
    private var resolvedPageOffsets: [Int]? {
        guard let attachmentPageOffsets, !attachmentPageOffsets.isEmpty else { return nil }
        if case .pages(let pages) = textState, !pages.isEmpty {
            let clipped = attachmentPageOffsets.filter { $0 >= 0 && $0 < pages.count }
            return clipped.isEmpty ? nil : clipped
        }
        return attachmentPageOffsets
    }

    /// 缩略图数 = 附件数（2026-10-30 业主：多附件每个附件一张；单份多页
    /// PDF 仍是一份附件）。附件数未知时回落页数。
    /// 新快照优先用逐附件起始页（多页 PDF 在前时后续附件页号整体偏移）；
    /// 旧快照按附件序=页序回落。读到逐页文本后按真实页数钳制——否则
    /// 截断导入的旧记录 itemCount 可能大于实际页数致尾图空占位。
    private var thumbnailCount: Int {
        if let resolvedPageOffsets { return resolvedPageOffsets.count }
        guard let attachmentCount, attachmentCount > 0 else { return totalPageCount }
        if case .pages(let pages) = textState, !pages.isEmpty {
            return max(1, min(attachmentCount, pages.count))
        }
        return attachmentCount
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(0..<thumbnailCount, id: \.self) { index in
                    thumbnailButton(index: index)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.thumbs")
    }

    /// 第 N 张缩略图 = 第 N 个附件的**起始页**（有偏移表时），否则第 N 页。
    private func thumbnailButton(index: Int) -> some View {
        let page = resolvedPageOffsets?[index] ?? index
        return Button {
            dismissRefresh = .none
            detailSheet = .original(page: page)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ChatMediaThumbnail(documentId: documentId, patientId: patientId,
                                   size: 84, cornerRadius: 12,
                                   pageIndex: page,
                                   fallbackSymbol: "photo", auditsSensitive: index == 0,
                                   preloaded: thumbPreload)
                if thumbnailCount > 1 {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.chatMediaPageAccessibility(index + 1, thumbnailCount))
        .accessibilityIdentifier("chat.mediaDetail.thumb.\(index)")
    }

    private var tabPicker: some View {
        Picker(L10n.assistantMediaDetailTitle, selection: $tab) {
            ForEach(Tab.allCases) { candidate in
                Text(candidate.label).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .accessibilityIdentifier("chat.mediaDetail.tabs")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .text:
            textTab
        case .elements:
            elementsTab
        case .cards:
            cardsTab
        }
    }

    // MARK: - 识别原文（按页显示；2026-11-03 业主）

    @ViewBuilder
    private var textTab: some View {
        switch textState {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        case .failed:
            errorBlock { Task { await loadBasics() } }
        case .empty:
            emptyNote(L10n.assistantMediaTextEmpty)
        case .legacy(let text):
            textPageCard(text: text, index: 0, pageCount: 1, status: "ok")
        case .pages(let pages):
            if pages.isEmpty {
                emptyNote(L10n.assistantMediaTextEmpty)
            } else {
                let index = min(max(textPageIndex, 0), pages.count - 1)
                let page = pages[index]
                textPageCard(text: page.text ?? "", index: index,
                             pageCount: pages.count, status: page.status)
                if pages.count > 1 {
                    textPager(count: pages.count, index: index)
                }
            }
        }
    }

    private func textPageCard(text: String, index: Int, pageCount: Int, status: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.assistantMediaTextPageHeader(index + 1))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let label = pageStatusText(status) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(status == "failed"
                                         ? Color("semantic-danger", bundle: .main)
                                         : .secondary)
                }
            }
            // 外层详情已是 ScrollView：原文直接铺开（长文本随页面滚动），
            // 不再嵌套内层滚动视图（无固定高度时内层只会撑满、白增手势层）。
            Text(text.isEmpty ? L10n.assistantMediaPageNoText : text)
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.text.page")
    }

    private func textPager(count: Int, index: Int) -> some View {
        HStack(spacing: 18) {
            Button { textPageIndex = max(0, index - 1) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(index <= 0)
            .accessibilityLabel(L10n.chatMediaPreviousPage)
            .accessibilityIdentifier("chat.mediaDetail.text.previous")

            Text(L10n.entityCardHeaderPage(index + 1, count))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Button { textPageIndex = min(count - 1, index + 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(index >= count - 1)
            .accessibilityLabel(L10n.chatMediaNextPage)
            .accessibilityIdentifier("chat.mediaDetail.text.next")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 数据信息元（可修正的字段卡；确认仍走既有卡级）

    @ViewBuilder
    private var elementsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.chatMediaElementsP1Note)
                .font(.caption2)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .fixedSize(horizontal: false, vertical: true)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color("semantic-warning", bundle: .main).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            switch pendingState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            case .failed:
                errorBlock { Task { await loadCards() } }
            case .loaded(let cards):
                let rows = elementRows(from: cards)
                if rows.isEmpty {
                    // 空态只留说明；重新识别由底部固定动作行承担（不重复入口）。
                    emptyNote(L10n.chatMediaElementsEmpty)
                } else {
                    sectionHeader(L10n.chatMediaElementsGroupHeader)
                    ForEach(rows) { row in
                        elementGroup(row)
                    }
                    .onAppear { ensureExpandedElementGroup(ids: rows.map(\.id)) }
                    .onChangeCompat(of: rows.map(\.id)) { _, ids in
                        ensureExpandedElementGroup(ids: ids)
                    }
                }
            }

            if !dirtyCards.isEmpty {
                Button {
                    Task { await saveAllElementCards() }
                } label: {
                    Text(L10n.chatMediaElementSaveAll)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .disabled(!savingCards.isEmpty)
                .accessibilityIdentifier("chat.mediaDetail.elements.saveAll")
            }

            HStack(spacing: 10) {
                NavigationLink {
                    DocumentReviewRouteView(documentId: documentId, patientId: patientId,
                                            reprocess: true, suppressAutoMirror: true) {
                        Task { await loadBasics() }
                    }
                } label: {
                    Label(L10n.chatMediaReRecognize, systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat.mediaDetail.elements.reprocess")

                Button {
                    Task {
                        await saveAllElementCards()
                        if dirtyCards.isEmpty { tab = .cards }
                    }
                } label: {
                    Text(L10n.chatMediaElementsToCards)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chat.mediaDetail.elements.toCards")
            }

            Text(L10n.chatMediaElementsFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 页级识别状态必须可见（旧「文件」页签删掉后不能连失败页一起消失）：
    /// 读取失败可重试；识别失败/纯影像页/跳过页逐页标注，用户不得误以为整份已识别。
    /// 整份文档的状态，两个页签共用。
    @ViewBuilder
    private var pageStatusNotices: some View {
        switch textState {
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                Text(L10n.assistantMediaLoadFailed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.retry) { Task { await loadBasics() } }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("semantic-warning", bundle: .main).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .pages(let pages):
            let broken = pages.filter {
                $0.status == "failed" || $0.status == "no_text" || $0.status == "skipped"
            }
            if !broken.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(broken, id: \.index) { page in
                        Label {
                            Text("\(page.index + 1) · ").font(.caption2)
                                + Text(pageStatusText(page.status) ?? L10n.assistantMediaPageFailed)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color("semantic-warning", bundle: .main).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .loading, .legacy, .empty:
            EmptyView()
        }
    }

    private func elementRows(from cards: [PendingCard]) -> [ElementRow] {
        cards.flatMap { card -> [ElementRow] in
            let matched = try? card.matchedCard()   // try?-ok: 旧卡缺页身份时回落 partialData 投影
            let pageIndex = card.sourcePage ?? matched?.pageIndex ?? 0
            let kindName = L10n.entityCardKindName(card.cardKind)
            let draft = elementDrafts[card.id]
            let groups: [ChatMediaElementGroup]
            if let draft {
                groups = ChatMediaElementGrouping.groups(cardID: card.id, card: draft, includeEmpty: true)
            } else if let matched {
                groups = ChatMediaElementGrouping.groups(cardID: card.id, card: matched)
            } else {
                let shared = Self.legacyFields(card.partialData.shared)
                let rowFields = card.partialData.rows.map(Self.legacyFields)
                groups = ChatMediaElementGrouping.groups(cardID: card.id, shared: shared,
                                                         rows: rowFields)
            }
            return groups.map { group in
                let title = group.rowIndex.map {
                    L10n.chatMediaElementRowTitle(kindName, $0 + 1)
                } ?? kindName
                return ElementRow(
                    group: group,
                    cardID: card.id,
                    pageIndex: pageIndex,
                    title: title,
                    subtitle: L10n.chatMediaElementSubtitle(pageIndex + 1, group.fields.count),
                    editable: draft != nil,
                    sharedLocked: docs.pendingReviews[card.id]?.sharedCommitted == true)
            }
        }
    }

    private static func legacyFields(_ values: [String: String]) -> [FieldDraft] {
        values.sorted { $0.key < $1.key }.map {
            FieldDraft(key: $0.key, value: $0.value, confidence: 0)
        }
    }

    /// 共享面：任一行已提交后只读（行内保存会被 store 的合并规则拒绝）；
    /// 行面仍可编辑——已提交行自身另有 C 级只读判定。
    private func allowsInlineEdit(_ row: ElementRow) -> Bool {
        row.editable && !(row.sharedLocked && row.group.rowId == nil)
    }

    private func elementGroup(_ row: ElementRow) -> some View {
        let expanded = expandedElementGroup == row.group.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    didInitializeExpandedGroup = true
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedElementGroup = expanded ? nil : row.group.id
                    }
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .animation(.easeInOut(duration: 0.2), value: expanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel(row.title)
                .accessibilityValue(expanded ? L10n.chatMediaElementCollapse
                                               : L10n.chatMediaElementExpand)
                .accessibilityIdentifier("chat.mediaDetail.elementGroup.toggle.\(row.group.id)")

                switch ChatMediaElementGrouping.groupAction(
                    editable: allowsInlineEdit(row),
                    saving: savingCards.contains(row.cardID),
                    dirty: dirtyCards.contains(row.cardID),
                    saved: savedCards.contains(row.cardID)) {
                case .none:
                    EmptyView()
                case .saving:
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L10n.chatMediaElementSaving)
                case .save:
                    Button(L10n.chatMediaElementSave) {
                        Task { await saveElementCard(row.cardID) }
                    }
                    .font(.caption.weight(.bold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("chat.mediaDetail.elements.save.\(row.cardID)")
                case .saved:
                    Label(L10n.chatMediaElementSaved, systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color("semantic-success", bundle: .main))
                        .accessibilityIdentifier("chat.mediaDetail.elements.saved.\(row.cardID)")
                }
            }
            if expanded {
                if row.sharedLocked, row.group.rowId == nil {
                    Text(L10n.chatMediaElementSharedLocked)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(row.group.fields) { field in
                    elementFieldCard(field, row: row)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.elementGroup.\(row.group.id)")
    }

    /// 首次加载默认展开第一组；用户手动全收起后，刷新不强行重开。
    private func ensureExpandedElementGroup(ids: [String]) {
        guard !ids.isEmpty else {
            expandedElementGroup = nil
            return
        }
        if !didInitializeExpandedGroup {
            expandedElementGroup = ids.first
            didInitializeExpandedGroup = true
            return
        }
        if let current = expandedElementGroup, !ids.contains(current) {
            expandedElementGroup = nil
        }
    }

    private func elementFieldCard(_ field: ChatMediaElementField, row: ElementRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(DocumentsDisplay.fieldLabel(forKey: field.key))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if field.isRejected {
                    Text(L10n.docConfirmReject)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    GradeBadge(grade: field.grade)
                }
                Spacer(minLength: 0)
            }
            // 已拒绝=用户显式否定，已确认 C=已落库行：行内键入不得静默撤销拒绝
            // 或改写已提交数据（BR-003；与确认页 readOnly/rejected 同口径）。
            if allowsInlineEdit(row), !field.isRejected, field.grade != GradeBadge.gradeConfirmed {
                HStack(spacing: 5) {
                    TextField("", text: elementValueBinding(field, row: row))
                        .font(.subheadline.weight(.semibold))
                        .textFieldStyle(.plain)
                        .accessibilityLabel(DocumentsDisplay.fieldLabel(forKey: field.key))
                        .accessibilityIdentifier("chat.mediaDetail.element.value.\(field.id)")
                    if let unit = field.unit, !unit.isEmpty {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .frame(minHeight: 44)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(field.value)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(field.isRejected)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unit = field.unit, !unit.isEmpty {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button(L10n.chatMediaSourceText) {
                    dismissRefresh = .none
                    detailSheet = .sourceLine(cardID: row.cardID, fieldKey: field.key,
                                              rowID: row.group.rowId, pageIndex: row.pageIndex,
                                              lines: sourceLines(for: field, row: row),
                                              // 合成回落行（页文本缺失时）不提供引用：
                                              // SourceLineSheet 按数组下标回写行号，会对
                                              // 字段锚点写入假的行 0。只许展示原行，不许引用。
                                              canQuote: allowsInlineEdit(row) && !field.isRejected
                                                  && field.grade != GradeBadge.gradeConfirmed
                                                  && pageIndexHasText(row.pageIndex))
                }
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .disabled(!pageIndexHasText(row.pageIndex) && field.sourceText.isEmpty)
                .accessibilityIdentifier("chat.mediaDetail.element.source.\(field.id)")

                Button(L10n.chatMediaViewSourceImage) {
                    dismissRefresh = .none
                    detailSheet = .sourceCrop(pageIndex: row.pageIndex,
                                              lineIndex: field.sourceLineIndex,
                                              text: sourceTextForCrop(field, row: row))
                }
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.mediaDetail.element.crop.\(field.id)")

                Button(L10n.chatMediaGoConfirm) {
                    dismissRefresh = .cards
                    if dirtyCards.contains(row.cardID) {
                        Task {
                            // 保存窗口内继续键入时再存一次，带着未保存编辑去核对会丢改动。
                            var saved = false
                            repeat {
                                saved = await saveElementCard(row.cardID, offerOpenCardOnFailure: true)
                            } while saved && dirtyCards.contains(row.cardID)
                            if saved { detailSheet = .pending(id: row.cardID) }
                        }
                    } else {
                        detailSheet = .pending(id: row.cardID)
                    }
                }
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.mediaDetail.element.confirm.\(field.id)")

                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.element.\(field.id)")
    }

    private func elementValueBinding(_ field: ChatMediaElementField,
                                     row: ElementRow) -> Binding<String> {
        Binding(
            get: { currentElementValue(field, row: row) },
            set: { setElementValue($0, field: field, row: row) })
    }

    private func currentElementValue(_ field: ChatMediaElementField, row: ElementRow) -> String {
        guard let card = elementDrafts[row.cardID] else { return field.value }
        if let rowID = row.group.rowId {
            return card.rows.first { $0.id == rowID }?
                .fields.first { $0.key == field.key }?.value ?? field.value
        }
        return card.shared.first { $0.key == field.key }?.value ?? field.value
    }

    private func setElementValue(_ value: String, field: ChatMediaElementField,
                                 row: ElementRow) {
        guard var card = elementDrafts[row.cardID] else { return }
        if currentElementValue(field, row: row) == value { return }
        // 逐键只改草稿值；修订留痕/证据键失效/编码失效在保存时一次性归并
        // （`draftApplyingEdits`），避免每键入一字符追加一条 revisionHistory。
        if let rowID = row.group.rowId {
            guard let r = card.rows.firstIndex(where: { $0.id == rowID }),
                  let i = card.rows[r].fields.firstIndex(where: { $0.key == field.key }) else { return }
            card.rows[r].fields[i].value = value
        } else {
            guard let i = card.shared.firstIndex(where: { $0.key == field.key }) else { return }
            card.shared[i].value = value
        }
        elementDrafts[row.cardID] = card
        dirtyCards.insert(row.cardID)
        savedCards.remove(row.cardID)
    }

    /// 引原文行：优先存储页原文；页文本读取失败时回落字段自带原始行
    /// （卡片载荷里始终有值），不得让证据入口静默消失。
    private func sourceLines(for field: ChatMediaElementField, row: ElementRow) -> [String] {
        let lines = pageLines(row.pageIndex)
        if !lines.isEmpty { return lines }
        let fallback = field.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? [] : [fallback]
    }

    /// 裁片匹配文本只取原始行（field.rawText → 存储页原文行），绝不使用当前编辑值：
    /// 编辑值不是来源，拿它搜会匹配到无关行。
    private func sourceTextForCrop(_ field: ChatMediaElementField, row: ElementRow) -> String {
        if !field.sourceText.isEmpty { return field.sourceText }
        let lines = pageLines(row.pageIndex)
        if let index = field.sourceLineIndex, lines.indices.contains(index) {
            return lines[index]
        }
        return ""
    }

    private func elementSourceLine(cardID: String, key: String, rowID: UUID?) -> Int? {
        guard let card = elementDrafts[cardID] else { return nil }
        if let rowID {
            return card.rows.first { $0.id == rowID }?
                .fields.first { $0.key == key }?.sourceLineIndex
        }
        return card.shared.first { $0.key == key }?.sourceLineIndex
    }

    private func quoteElement(cardID: String, fieldKey: String, rowID: UUID?,
                              lines: [String], indices: [Int]) {
        guard var card = elementDrafts[cardID] else { return }
        CardConfirmationRules.quote(&card, key: fieldKey, rowId: rowID,
                                    lines: lines, sourceLineIndices: indices)
        elementDrafts[cardID] = card
        dirtyCards.insert(cardID)
        savedCards.remove(cardID)
    }

    @discardableResult
    private func saveElementCard(_ cardID: String, offerOpenCardOnFailure: Bool = false) async -> Bool {
        // 保存/去核对重复点按：等待同一次在途落库，不得静默返回失败。
        if let inFlight = saveTasks[cardID] {
            return await inFlight.value
        }
        guard let card = elementDrafts[cardID] else { return false }
        // 以最后一次落库快照为基线归并编辑：修订留痕每字段只记一条，
        // 证据键失效/编码失效也在这次应用（逐键路径不再调用 reviseDraft）。
        let finalCard = storedMatchedCard(cardID).map {
            CardConfirmationRules.draftApplyingEdits(base: $0, edited: card)
        } ?? card
        let task = Task { @MainActor in
            defer { saveTasks[cardID] = nil }
            savingCards.insert(cardID)
            defer { savingCards.remove(cardID) }
            let saved = await docs.updatePendingCardDraft(id: cardID, card: finalCard)
            guard saved else {
                // 「去核对」触发失败时，弹窗直接给「去核对」（打开现有卡）；
                // 保存按钮触发的失败只陈述失败，不把用户强行带离当前页。
                // 不用三元表达式：`? cardID : nil` 会被类型层门禁误读为
                // `cardID: nil` 实参（族 N 假阳性），显式分支更清楚。
                if offerOpenCardOnFailure {
                    pendingCardAfterSaveFailure = cardID
                    elementSaveError = L10n.chatMediaElementSaveFailedOpenCard
                } else {
                    pendingCardAfterSaveFailure = nil
                    elementSaveError = L10n.chatMediaElementSaveFailed
                }
                return false
            }
            // 落库窗口内继续键入：新值尚未落库，不得显示「已保存」。
            // 草稿已被外部归档/移除（nil）时不得再标脏：脏卡没有可保存的
            // 草稿会永久卡住保存全部与「去卡片页查看」。
            if elementDrafts[cardID] == card {
                dirtyCards.remove(cardID)
                savedCards.insert(cardID)
            } else if elementDrafts[cardID] != nil {
                dirtyCards.insert(cardID)
                savedCards.remove(cardID)
            } else {
                dirtyCards.remove(cardID)
                savedCards.remove(cardID)
            }
            await refreshPendingCards()
            return true
        }
        saveTasks[cardID] = task
        return await task.value
    }

    private func saveAllElementCards() async {
        // 单卡失败不得中止整批：否则失败卡之后的脏卡永远不落库，
        // 且「去卡片页查看」会因 dirty 非空永久禁用（真机反馈）。
        for cardID in dirtyCards.sorted() {
            _ = await saveElementCard(cardID)
        }
    }

    /// 待核对区的落库快照（行内编辑归并的基线）；解析失败时由调用方退回编辑值。
    private func storedMatchedCard(_ cardID: String) -> MatchedCard? {
        guard case .loaded(let cards) = pendingState,
              let pending = cards.first(where: { $0.id == cardID }) else { return nil }
        return try? pending.matchedCard()   // try?-ok: 旧卡无身份 → 不归并
    }

    /// 行内保存后同步「医疗信息卡片」区的待核对摘要（不重放编辑草稿）。
    private func refreshPendingCards() async {
        let projection = await docs.pendingCards(documentId: documentId, patientId: patientId)
        guard case .loaded(let cards) = projection else { return }
        pendingState = .loaded(cards)
        syncElementDrafts(from: cards)
    }

    private func pageIndexHasText(_ pageIndex: Int) -> Bool {
        switch textState {
        case .pages: return pagesWithText.contains(pageIndex)
        case .legacy(let text): return !text.isEmpty
        case .loading, .empty, .failed: return false
        }
    }

    private func pageLines(_ pageIndex: Int) -> [String] {
        switch textState {
        case .pages(let pages):
            return pages.first { $0.index == pageIndex }?.text?
                .components(separatedBy: "\n") ?? []
        case .legacy(let text):
            return text.components(separatedBy: "\n")
        case .loading, .empty, .failed:
            return []
        }
    }

    // MARK: - 信息卡片

    /// 业主 2026-10-29：信息卡片分两区——「需要修改」（待核对/过期补办）
    /// 在前，「已确认」（修改之后）在后；聊天流不再承载卡片。
    @ViewBuilder
    private var cardsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(L10n.chatMediaCardsAssemblyNote)
            pendingCardsSection
            committedCardsSection
            Text(L10n.chatMediaCardsFootnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var pendingCardsSection: some View {
        switch pendingState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 72)
        case .failed:
            errorBlock { Task { await loadCards() } }
        case .loaded(let cards):
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(L10n.assistantMediaCardsPendingSection)
                    ForEach(cards, id: \.id) { card in
                        pendingCardRow(card)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var committedCardsSection: some View {
        switch cardsState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 72)
        case .failed:
            errorBlock { Task { await loadCards() } }
        case .loaded(let cards):
            if cards.isEmpty {
                // 只在待核对区确认「已读且为空」时显示空态；待核对区仍在读取
                // 或读取失败时不得先画「还没有信息卡片」的误导结论。
                if case .loaded(let pending) = pendingState, pending.isEmpty {
                    emptyWithReprocess(L10n.assistantMediaCardsEmpty)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(L10n.assistantMediaCardsCommittedSection)
                    ForEach(cards) { card in
                        cardRow(card)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func pendingCardRow(_ card: PendingCard) -> some View {
        let spec = CardKindIcon.spec(cardKind: card.cardKind)
        let canRestore = PendingCardLifecycleRules.canRestore(
            status: card.status, resolvedBy: card.resolvedBy)
        let fields = pendingFieldRows(card)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                dismissRefresh = .cards
                detailSheet = .pending(id: card.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: spec.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(spec.tint)
                        .frame(width: 34, height: 34)
                        .background(spec.tint.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.entityCardKindName(card.cardKind))
                            .font(.subheadline.weight(.semibold))
                        // 业主裁决 A（2026-10-30）：到期归档卡可补办——行内如实标注，
                        // 点按即解除归档并打开确认页（resume route 统一处理+审计）。
                        Text(canRestore ? L10n.assistantMediaArchivedRestore
                                        : L10n.assistantMediaNeedsConfirm)
                            .font(.caption)
                            .foregroundStyle(canRestore
                                ? Color("text-secondary", bundle: .main)
                                : Color("semantic-warning", bundle: .main))
                    }
                    Spacer(minLength: 8)
                    GradeBadge(grade: GradeBadge.gradeMachineUnconfirmed)
                    Image(systemName: canRestore
                        ? "arrow.uturn.backward.circle" : "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canRestore
                            ? Color("text-secondary", bundle: .main) : Color.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.mediaDetail.pending.\(card.id)")
            if !fields.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { item in
                        LabeledContent {
                            Text(item.element.value)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } label: {
                            Text(DocumentsDisplay.fieldLabel(forKey: item.element.key))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 待核对卡的可读字段摘要（shared 优先，其次首行；排除内部键与空值，最多 4 条）。
    private func pendingFieldRows(_ card: PendingCard) -> [(key: String, value: String)] {
        var seen: Set<String> = []
        var rows: [(String, String)] = []
        let candidates = card.partialData.shared.sorted { $0.key < $1.key }
            + (card.partialData.rows.first ?? [:]).sorted { $0.key < $1.key }
        for (key, value) in candidates {
            guard key != "metric_key", !seen.contains(key),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            seen.insert(key)
            rows.append((key, value))
            if rows.count == 4 { break }
        }
        return rows.map { (key: $0.0, value: $0.1) }
    }

    private func cardRow(_ card: CommittedCard) -> some View {
        let spec = CardKindIcon.spec(cardKind: card.kind)
        return NavigationLink {
            MedicalCardDetailView(kind: card.kind, entityId: card.id, patientId: patientId)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: spec.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(spec.tint)
                    .frame(width: 34, height: 34)
                    .background(spec.tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text(L10n.entityCardKindName(card.kind))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color("semantic-success", bundle: .main))
                    .accessibilityLabel(L10n.assistantMediaConfirmed)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.mediaDetail.card.\(card.id.uuidString)")
    }

    // MARK: - 块级状态件

    /// 空态必须给出重新识别入口：OCR 可能识别成功但未抽出结构化信息元，
    /// 或整页识别失败；只写「没有待核对要素」会让用户无路可走（2026-11-03）。
    private func emptyWithReprocess(_ text: String) -> some View {
        VStack(spacing: 10) {
            emptyNote(text)
            NavigationLink {
                DocumentReviewRouteView(documentId: documentId, patientId: patientId,
                                        reprocess: true, suppressAutoMirror: true) {
                    Task { await loadBasics() }
                }
            } label: {
                Label(L10n.chatMediaReRecognize, systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("chat.mediaDetail.reprocess")
        }
    }

    private func emptyNote(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(16)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.empty")
    }

    private func errorBlock(_ retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .accessibilityHidden(true)
            Text(L10n.assistantMediaLoadFailed)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(L10n.retry, action: retry)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.mediaDetail.retry")
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(16)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func unavailableBlock(_ retry: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .accessibilityHidden(true)
            Text(L10n.assistantMediaLoadFailed)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(L10n.retry, action: retry)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.mediaDetail.retry.doc")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 载入

    private func loadBasics() async {
        // 重新识别/更新卡片会改变页数：页码回到首页，避免停在越界后被
        // min/max 悄悄夹到最后一页（原实现只在渲染时夹取）。
        textPageIndex = 0
        textState = .loading
        docState = .loading
        switch await docs.mediaText(id: documentId, patientId: patientId) {
        case .pages(let pages):
            textState = .pages(pages)
            pagesWithText = Set(pages.compactMap { page in
                guard let text = page.text, !text.isEmpty else { return nil }
                return page.index
            })
        case .legacy(let text):
            textState = .legacy(text: text)
            pagesWithText = text.isEmpty ? [] : [0]
        case .empty:
            textState = .empty
            pagesWithText = []
        case .failed:
            textState = .failed
            pagesWithText = []
        }
        await loadCards()
        await refreshGrade()
    }

    /// 待核对卡关闭后：刷卡片两区（待核对 + 已确认）+ 文档徽章
    /// （最后一张确认 D→C），不重置识别文本与滚动位（V4.89 纪律；
    /// 2026-10-30 复核：只刷已确认区会让刚确认的卡仍留在待核对区）。
    private func loadCardsAndGrade() async {
        await loadCards()
        await refreshGrade()
    }

    private func refreshGrade() async {
        if let doc = await docs.documentRow(id: documentId), doc.patientId == patientId {
            docState = .loaded(grade: doc.grade)
            // 缩略图条一次解析文档行/meta，N 张共享（此前每张各自读行+JSON）。
            if let json = doc.metaJSON,
               let meta = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],   // try?-ok: meta 损坏=缩略图占位态
               let path = meta["original_path"] as? String,
               let resolved = docs.resolveMediaPath(path) {
                thumbPreload = ChatMediaThumbnail.Preloaded(
                    path: resolved.path,
                    mimeType: doc.mimeType ?? "image/jpeg",
                    isSensitive: doc.isSensitive,
                    title: doc.title ?? "",
                    cacheIdentity: doc.sha256 ?? "t\(doc.createdAt.timeIntervalSince1970)")
            } else {
                thumbPreload = nil
            }
        } else {
            docState = .failed
            thumbPreload = nil
        }
    }

    /// 两区独立三值：待核对失败不得把已确认区涂空，反之亦然。
    private func loadCards() async {
        cardsState = .loading
        pendingState = .loading
        switch await docs.committedCards(documentId: documentId, patientId: patientId) {
        case .loaded(let kindIds):
            cardsState = .loaded(kindIds.map { CommittedCard(kind: $0.kind, id: $0.id) })
        case .failed:
            cardsState = .failed
        }
        switch await docs.pendingCards(documentId: documentId, patientId: patientId) {
        case .loaded(let cards):
            pendingState = .loaded(cards)
            syncElementDrafts(from: cards)
            ensureExpandedElementGroup(ids: elementRows(from: cards).map(\.id))
        case .failed:
            pendingState = .failed
        }
    }

    /// 待办卡刷新时同步编辑草稿：未保存的编辑不得被外部刷新覆盖；
    /// 已消失的卡（确认/丢弃）清掉草稿与状态。
    private func syncElementDrafts(from cards: [PendingCard]) {
        let ids = Set(cards.map(\.id))
        elementDrafts = elementDrafts.filter { ids.contains($0.key) }
        dirtyCards.formIntersection(ids)
        savedCards.formIntersection(ids)
        savingCards.formIntersection(ids)
        for card in cards {
            // 归档卡只读：先走[去核对]补办恢复，行内保存不得直写归档卡。
            // 归档判定先于 dirty 保护——外部归档后未保存草稿不得继续可编辑。
            if card.status == "archived" {
                elementDrafts.removeValue(forKey: card.id)
                dirtyCards.remove(card.id)
                savedCards.remove(card.id)
                continue
            }
            guard !dirtyCards.contains(card.id) else { continue }
            if let matched = try? card.matchedCard() {   // try?-ok: 旧卡无身份 → 只读投影
                elementDrafts[card.id] = matched
            } else {
                elementDrafts.removeValue(forKey: card.id)
            }
        }
    }
}
