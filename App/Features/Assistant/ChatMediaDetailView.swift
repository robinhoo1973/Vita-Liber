import SwiftUI
import Domain
import Infrastructure
import Perception

/// 聊天媒体详情（2026-10-29 批三 · mock v4 对照落地；业主六项 UI/UX 复核后）。
/// 骨架与语音速记详情一致：上=媒体卡（小圆角缩略 + 页数 + 「点按看原图」→ 既有
/// `DocumentSourcePageView` 全屏原图），下=双 tab：
/// - 识别文本：`document_page` 逐页原文；无页行的旧资料回落文档级 `ocr_text`；
/// - 信息卡片：分「需要修改」（待核对/过期补办）与「已确认」两区；聊天流不再承载卡片。
/// 三值状态纪律：文本/已确认卡/待核对卡/文档行各自 loading/loaded/failed，
/// 读取失败必须可见并可重试——不得把失败涂成空态（「没有可显示的识别文本」是陈述，不是兜底）。
struct ChatMediaDetailView: View {
    let documentId: UUID
    let patientId: UUID
    let title: String

    @Environment(DocumentsState.self) private var docs
    @Environment(AppSettingsStore.self) private var settingsStore
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

    private struct PendingReviewTarget: Identifiable {
        let id: String
    }

    private enum DocState: Equatable {
        case loading
        case loaded(grade: String)
        case failed
    }

    @State private var tab: Tab = .text
    @State private var textState: TextState = .loading
    @State private var cardsState: CardsState = .loading
    @State private var pendingState: PendingState = .loading
    @State private var docState: DocState = .loading
    @State private var showOriginal = false
    @State private var pendingReview: PendingReviewTarget?
    /// 文档行敏感真值（出口文案依赖；nil=未知，缩略图留痕由 ChatMediaThumbnail 承担）。
    @State private var docSensitive: Bool?

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
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.assistantClose) { dismiss() }
                    }
                }
                // 文本/卡片/文档行先就绪（缩略图不 gate 内容）。
                .task(id: documentId) { await loadBasics() }
                .sheet(isPresented: $showOriginal) {
                    DocumentSourcePageView(documentId: documentId, patientId: patientId, pageIndex: 0)
                }
                // 待核对卡 → 既有复核页；关闭后重读「需要修改/已确认」两区。
                .sheet(item: $pendingReview, onDismiss: {
                    // 确认/放弃卡后文档 grade 也可能 D→C，整页重读。
                    Task { await loadCardsOnly() }
                }) { target in
                    NavigationStack {
                        PendingCardResumeRouteView(cardId: target.id)
                    }
                }
                // 缩略图即原图内容：退后台时随系统隐私遮罩隐去（与原件页同纪律）。
                .privacySensitive(scenePhase != .active)
            }
        }
    }

    // MARK: - 媒体卡（小缩略 + 页数 + 看原图）

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if case .loaded(let grade) = docState {
                    // 业主 2026-10-29：D 级不再显示文字徽章，统一用橘红编辑/
                    // 绿色勾图标（与聊天气泡同一出口）。
                    ChatMediaGradeIcon(grade: grade)
                }
            }
            if case .failed = docState {
                unavailableBlock { Task { await loadBasics() } }
            } else {
                originalButton
            }
            // 出口边界文案随真实设置：自动镜像开启且资料非敏感时，提交件会生成
            // 「文件」App 副本——不得再宣称「仅存本机」。敏感真值未知时按镜像
            // 已开启的保守口径提示，避免低报对外副本。
            Text(autoMirrorEnabled && docSensitive != true
                ? L10n.assistantMediaEgressNoteMirror : L10n.assistantMediaEgressNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 自动镜像设置真值（与 AppSession 判定同口径）。
    private var autoMirrorEnabled: Bool {
        settingsStore.values[.filesExportAutoMirror] == "true"
    }

    private var pageCount: Int? {
        switch textState {
        case .pages(let pages): return pages.count
        case .legacy: return 1
        // 读取完成前不猜页数（选项数不等于 PDF 页数）。
        case .loading: return nil
        case .empty, .failed: return nil
        }
    }

    /// 业主 2026-10-29：详情页只留一个小圆角缩略图（不占大半屏），点按看原图。
    /// 缩略图即原图内容：FR14.2 留痕与退后台遮罩由 ChatMediaThumbnail 统一承担。
    private var originalButton: some View {
        Button {
            showOriginal = true
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    ChatMediaThumbnail(documentId: documentId, patientId: patientId,
                                       size: 76, cornerRadius: 12,
                                       fallbackSymbol: "photo", auditsSensitive: true)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .padding(5)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let count = pageCount, count > 1 {
                        Text(L10n.entityCardHeaderPage(1, count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.assistantMediaOpenOriginal)
                        .font(.caption)
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.mediaDetail.original")
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
        return Button {
            pendingReview = PendingReviewTarget(id: card.id)
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
                    Text(L10n.assistantMediaNeedsConfirm)
                        .font(.caption)
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                }
                Spacer(minLength: 8)
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityHidden(true)
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
        .accessibilityIdentifier("chat.mediaDetail.pending.\(card.id)")
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

    /// 只刷新卡片区（核对 sheet 关闭后）：正文/缩略图/文档行保持已读状态，
    /// 避免整页塌回 ProgressView、滚动位置丢失（审查席 P2）。
    private func loadCardsOnly() async {
        switch await docs.committedCards(documentId: documentId, patientId: patientId) {
        case .loaded(let kindIds):
            cardsState = .loaded(kindIds.map { CommittedCard(kind: $0.kind, id: $0.id) })
        case .failed:
            cardsState = .failed
        }
    }

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
        if let doc = await docs.documentRow(id: documentId), doc.patientId == patientId {
            docState = .loaded(grade: doc.grade)
            docSensitive = doc.isSensitive
        } else {
            docState = .failed
            docSensitive = nil
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
