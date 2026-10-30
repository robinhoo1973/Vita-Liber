import SwiftUI
import Domain
import Infrastructure
import Perception

/// 聊天媒体详情（2026-10-29 批三 · mock v4 对照落地；2026-10-30 业主五点复核后）。
///
/// 结构对齐 mock 第 4/5/6/8 帧：
/// - 上=媒体卡：多附件/多页时**每张一个缩略图**（不再显示「N 份附件」类文字），
///   点任一缩略图直接进原图页；底部只保留来源徽章（GradeBadge 单一出口），
///   不再有右上角编辑图标与「原件保存在本机」长文案。
/// - 下=双 tab：识别文本（`document_page` 逐页原文；旧资料回落 `ocr_text`）/
///   信息卡片（「需要修改」在前、「已确认」在后；待核对卡就地展示 D 级字段
///   摘要与 BR-003 页脚）。
/// - 工具栏「更多操作」→ 查看原图 / 重新识别 / 文档信息（存储位置）/ 导出副本。
/// 三值状态纪律：文本/已确认卡/待核对卡/文档行各自 loading/loaded/failed，
/// 读取失败必须可见并可重试——不得把失败涂成空态。
struct ChatMediaDetailView: View {
    let documentId: UUID
    let patientId: UUID
    let title: String
    /// 会话身份（2026-10-30）：详情内「导出副本」沿用聊天会话目录；
    /// 历史/无会话上下文时为 nil（回落直接导入月桶）。
    var conversationID: UUID?
    var conversationTitle: String?

    @Environment(DocumentsState.self) private var docs
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case text, cards
        var id: String { rawValue }
        var label: String {
            switch self {
            case .text: return L10n.assistantMediaTabText
            case .cards: return L10n.assistantMediaTabCards
            }
        }
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

        var id: String {
            switch self {
            case .original(let page): return "original-\(page)"
            case .pending(let id): return "pending-\(id)"
            case .actions: return "actions"
            }
        }
    }

    @State private var tab: Tab = .text
    @State private var textState: TextState = .loading
    @State private var cardsState: CardsState = .loading
    @State private var pendingState: PendingState = .loading
    @State private var docState: DocState = .loading
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
                .navigationTitle(L10n.assistantMediaDetailTitle)
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
                                   title: title, pageCount: displayPageCount,
                                   conversationID: conversationID,
                                   conversationTitle: conversationTitle)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if case .failed = docState {
                unavailableBlock { Task { await loadBasics() } }
            }
            thumbnailStrip
            HStack(spacing: 8) {
                if case .loaded(let grade) = docState,
                   grade == GradeBadge.gradeMachineUnconfirmed
                    || grade == GradeBadge.gradeConfirmed {
                    GradeBadge(grade: grade)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 缩略图数 = 文档页数（多附件合并 = 每附件一页）；读取完成前至少 1 张。
    private var displayPageCount: Int {
        switch textState {
        case .pages(let pages): return max(1, pages.count)
        case .legacy: return 1
        case .loading, .empty, .failed: return 1
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(0..<displayPageCount, id: \.self) { index in
                    thumbnailButton(page: index)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.mediaDetail.thumbs")
    }

    private func thumbnailButton(page: Int) -> some View {
        Button {
            dismissRefresh = .none
            detailSheet = .original(page: page)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ChatMediaThumbnail(documentId: documentId, patientId: patientId,
                                   size: 84, cornerRadius: 12,
                                   pageIndex: page,
                                   fallbackSymbol: "photo", auditsSensitive: page == 0)
                if displayPageCount > 1 {
                    Text("\(page + 1)")
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
        .accessibilityLabel(L10n.chatMediaPageAccessibility(page + 1, displayPageCount))
        .accessibilityIdentifier("chat.mediaDetail.thumb.\(page)")
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
        case .cards:
            cardsTab
        }
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

    // MARK: - 信息卡片

    /// 业主 2026-10-29：信息卡片分两区——「需要修改」（待核对/过期补办）
    /// 在前，「已确认」（修改之后）在后；聊天流不再承载卡片。
    @ViewBuilder
    private var cardsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        } else {
            docState = .failed
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
