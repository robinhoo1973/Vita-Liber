import SwiftUI
import Domain
import Infrastructure
import Perception

/// 聊天媒体详情（2026-10-29 批三 · mock v4 对照落地；2026-10-30 业主五点复核后）。
///
/// 结构对齐 mock `chat-import-staging.html`（2026-11-01 业主）：
/// - 上=媒体卡：标题 + 附件/页数摘要 + 来源徽章（GradeBadge 单一出口）。
/// - 下=三 tab：文件（原件 / 识别文本、重新识别、页状态；提交后只读）/
///   识别结果（按卡类 + 页 + 行分组，去核对仍进现有卡级）/
///   信息卡片（「需要修改」在前、「已确认」在后；BR-003 页脚）。
/// - 工具栏「更多操作」→ 查看原图 / 重新识别 / 文档信息（存储位置）/ 导出副本。
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

    /// 2026-11-01 业主（mock `chat-import-staging.html`）：文件 / 识别结果 /
    /// 信息卡片三页。文件页只读；要素确认仍走既有卡级，不新建第二套管线。
    private enum Tab: String, CaseIterable, Identifiable {
        case files, elements, cards
        var id: String { rawValue }
        var label: String {
            switch self {
            case .files: return L10n.assistantMediaTabFiles
            case .elements: return L10n.assistantMediaTabElements
            case .cards: return L10n.assistantMediaTabCards
            }
        }
    }

    private enum FileMode: String, CaseIterable, Identifiable {
        case original, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return L10n.chatMediaFilesOriginal
            case .text: return L10n.chatMediaFilesText
            }
        }
    }

    /// 识别结果页的分组投影（卡片是保存单位，本页只读索引）。
    private struct ElementRow: Identifiable {
        let group: ChatMediaElementGroup
        let cardID: String
        let title: String
        let subtitle: String
        let rawText: String
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
        case reprocess
        case sourceText(title: String, text: String)

        var id: String {
            switch self {
            case .original(let page): return "original-\(page)"
            case .pending(let id): return "pending-\(id)"
            case .actions: return "actions"
            case .reprocess: return "reprocess"
            case .sourceText(let title, _): return "source-\(title)"
            }
        }
    }

    @State private var tab: Tab = .files
    @State private var fileMode: FileMode = .original
    @State private var textState: TextState = .loading
    @State private var cardsState: CardsState = .loading
    @State private var pendingState: PendingState = .loading
    @State private var docState: DocState = .loading
    /// 缩略图条共享的文档元数据（一次读行/解析 meta；2026-10-30 效率批）。
    @State private var thumbPreload: ChatMediaThumbnail.Preloaded?
    @State private var detailSheet: DetailSheet?
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
                        tabContent
                    }
                    .padding(16)
                }
                .navigationTitle(L10n.chatMediaResultTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismissRefresh = .all
                            detailSheet = .actions
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(L10n.chatMediaMoreActions)
                        .accessibilityIdentifier("chat.mediaDetail.more")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.assistantClose) { dismiss() }
                    }
                }
                .task(id: documentId) { await loadBasics() }
                // OCR 收尾后卡才从导入会话转入待办表（聊天页释放导入槽）；
                // 详情若先打开，必须在该时点重读两区，不能停在空态。
                .onChangeCompat(of: docs.activeImport?.source?.documentId) { _, _ in
                    Task { await loadCardsAndGrade() }
                }
                .sheet(item: $detailSheet, onDismiss: handleSheetDismiss) { sheet in
                    sheetContent(sheet)
                }
                // 缩略图即原图内容：退后台时随系统隐私遮罩隐去（与原件页同纪律）。
                .privacySensitive(scenePhase != .active)
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
        case .reprocess:
            NavigationStack {
                DocumentReviewRouteView(documentId: documentId, patientId: patientId,
                                        reprocess: true, suppressAutoMirror: true)
            }
        case .sourceText(let sourceTitle, let text):
            NavigationStack {
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle(sourceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.assistantClose) { detailSheet = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
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
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(L10n.chatMediaSummary(thumbnailCount, totalPageCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if case .failed = docState {
                unavailableBlock { Task { await loadBasics() } }
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                if case .loaded(let grade) = docState,
                   grade == GradeBadge.gradeMachineUnconfirmed
                    || grade == GradeBadge.gradeConfirmed {
                    GradeBadge(grade: grade)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        case .files:
            filesTab
        case .elements:
            elementsTab
        case .cards:
            cardsTab
        }
    }

    // MARK: - 文件（原件 / 识别文本）

    @ViewBuilder
    private var filesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.chatMediaFilesOriginal, selection: $fileMode) {
                ForEach(FileMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .accessibilityIdentifier("chat.mediaDetail.fileMode")

            if fileMode == .original {
                thumbnailStrip
            } else {
                textTab
            }

            Button {
                dismissRefresh = .all
                detailSheet = .reprocess
            } label: {
                Label(L10n.chatMediaReRecognize, systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("chat.mediaDetail.reprocess")

            Text(L10n.chatMediaFilesReadOnlyNote)
                .font(.caption2)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .fixedSize(horizontal: false, vertical: true)

            pageStatusSection
        }
    }

    @ViewBuilder
    private var pageStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(L10n.chatMediaPageStatusSection)
            switch textState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            case .failed:
                errorBlock { Task { await loadBasics() } }
            case .empty:
                emptyNote(L10n.assistantMediaTextEmpty)
            case .legacy(let text):
                pageStatusRow(ordinal: 1, status: text.isEmpty ? "failed" : "ok",
                              lineCount: Self.lineCount(text))
            case .pages(let pages):
                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { offset, page in
                        pageStatusRow(ordinal: page.index + 1, status: page.status,
                                      lineCount: Self.lineCount(page.text ?? ""))
                        if offset < pages.count - 1 { Divider() }
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func pageStatusRow(ordinal: Int, status: String, lineCount: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.entityCardHeaderPage(ordinal, max(ordinal, totalPageCount)))
                    .font(.subheadline.weight(.semibold))
                Text(status == "ok"
                     ? L10n.chatMediaPageStatusDone(lineCount)
                     : status == "failed" ? L10n.chatMediaPageStatusFailed
                                          : L10n.chatMediaPageStatusPending)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if status == "ok" {
                Text(L10n.chatMediaStatusOK)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color("semantic-success", bundle: .main), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }

    private static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    // MARK: - 识别文本

    @ViewBuilder
    private var textTab: some View {
        switch textState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failed:
            errorBlock { Task { await loadBasics() } }
        case .empty:
            emptyNote(L10n.assistantMediaTextEmpty)
        case .legacy(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.assistantMediaLegacyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .pages(let pages):
            let total = pages.count
            VStack(alignment: .leading, spacing: 12) {
                // DocumentStore.Page 非 Identifiable：以页号做稳定身份。
                ForEach(pages, id: \.index) { page in
                    pageSection(page, total: total)
                }
            }
        }
    }

    private func pageSection(_ page: DocumentStore.Page, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.entityCardHeaderPage(page.index + 1, max(total, page.index + 1)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                pageStatusLabel(page.status)
            }
            if let text = page.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(page.status == "failed" ? L10n.assistantMediaPageFailed : L10n.assistantMediaPageNoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 容器标识 + contain：防标识符掩蔽子元素（L0 第 18 节同族纪律）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.page.\(page.index)")
    }

    @ViewBuilder
    private func pageStatusLabel(_ status: String) -> some View {
        switch status {
        case "ok":
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color("semantic-success", bundle: .main))
                .accessibilityHidden(true)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    // MARK: - 识别结果（按卡/行分组，只读索引）

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
                    emptyNote(L10n.chatMediaElementsEmpty)
                } else {
                    sectionHeader(L10n.chatMediaElementsGroupHeader)
                    ForEach(rows) { row in
                        elementGroupCard(row)
                    }
                }
            }

            Button {
                tab = .cards
            } label: {
                Text(L10n.chatMediaElementsToCards)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chat.mediaDetail.elements.toCards")

            Text(L10n.chatMediaElementsFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func elementRows(from cards: [PendingCard]) -> [ElementRow] {
        cards.flatMap { card -> [ElementRow] in
            let matched = try? card.matchedCard()   // try?-ok: 旧卡缺页身份时回落 partialData 投影
            let pageIndex = card.sourcePage ?? matched?.pageIndex ?? 0
            let kindName = L10n.entityCardKindName(card.cardKind)
            let shared = matched?.shared ?? Self.legacyFields(card.partialData.shared)
            let rowFields = matched?.rows.map(\.fields)
                ?? card.partialData.rows.map(Self.legacyFields)
            return ChatMediaElementGrouping
                .groups(cardID: card.id, shared: shared, rows: rowFields)
                .map { group in
                    let title = group.rowIndex.map {
                        L10n.chatMediaElementRowTitle(kindName, $0 + 1)
                    } ?? kindName
                    return ElementRow(
                        group: group,
                        cardID: card.id,
                        title: title,
                        subtitle: L10n.chatMediaElementSubtitle(pageIndex + 1, group.fields.count),
                        rawText: card.rawText)
                }
        }
    }

    private static func legacyFields(_ values: [String: String]) -> [FieldDraft] {
        values.sorted { $0.key < $1.key }.map {
            FieldDraft(key: $0.key, value: $0.value, confidence: 0)
        }
    }

    private func elementGroupCard(_ row: ElementRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                    Text(row.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("0/\(row.group.fields.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color("brand-primary", bundle: .main))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottom) { Divider() }

            VStack(spacing: 0) {
                ForEach(Array(row.group.fields.enumerated()), id: \.offset) { index, field in
                    elementFieldRow(field: field, row: row)
                    if index < row.group.fields.count - 1 { Divider() }
                }
            }
            .background(Color(.systemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.elementGroup.\(row.group.id)")
    }

    private func elementFieldRow(field: ChatMediaElementField, row: ElementRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(DocumentsDisplay.fieldLabel(forKey: field.key))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                GradeBadge(grade: GradeBadge.gradeMachineUnconfirmed)
                Spacer(minLength: 0)
            }
            Text(field.value)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L10n.chatMediaGoConfirm) {
                    dismissRefresh = .cards
                    detailSheet = .pending(id: row.cardID)
                }
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.mediaDetail.element.confirm.\(field.id)")

                Button(L10n.chatMediaSourceText) {
                    let source = field.sourceText.isEmpty ? row.rawText : field.sourceText
                    detailSheet = .sourceText(title: L10n.chatMediaSourceTextTitle,
                                              text: source)
                }
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .disabled(field.sourceText.isEmpty
                          && row.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat.mediaDetail.element.source.\(field.id)")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    emptyNote(L10n.assistantMediaCardsEmpty)
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
        textState = .loading
        docState = .loading
        switch await docs.mediaText(id: documentId, patientId: patientId) {
        case .pages(let pages): textState = .pages(pages)
        case .legacy(let text): textState = .legacy(text: text)
        case .empty: textState = .empty
        case .failed: textState = .failed
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
        case .loaded(let cards): pendingState = .loaded(cards)
        case .failed: pendingState = .failed
        }
    }
}
