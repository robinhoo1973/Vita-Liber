import SwiftUI
import UIKit
import Domain
import Infrastructure
import Perception

/// 聊天媒体详情（2026-10-29 批三 · mock v4 对照落地；UX 席 P1 修复后）。
/// 骨架与语音速记详情一致：上=媒体卡（首屏缩略 + 页数 + 「点按看原图」→ 既有
/// `DocumentSourcePageView` 全屏原图），下=双 tab：
/// - 识别文本：`document_page` 逐页原文；无页行的旧资料回落文档级 `ocr_text`；
/// - 信息卡片：该文档已确认实体卡（`OCRCardStore.cards` → `MedicalCardDetailView`）。
/// 三值状态纪律（UX 席 2026-10-29）：文本/卡片/文档/缩略图各自 loading/loaded/failed，
/// 读取失败必须可见并可重试——不得把失败涂成空态（「没有可显示的识别文本」是陈述，不是兜底）。
struct ChatMediaDetailView: View {
    let documentId: UUID
    let patientId: UUID
    let title: String
    let itemCount: Int

    @Environment(DocumentsState.self) private var docs
    @Environment(AppState.self) private var app
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

    /// UIImage 跨执行器装箱（与 DocumentSourcePageView 的 RenderedImageBox 同模式）。
    private final class ThumbnailBox: @unchecked Sendable {
        let image: UIImage
        init(image: UIImage) {
            self.image = image
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

    private enum DocState: Equatable {
        case loading
        case loaded(grade: String)
        case failed
    }

    private enum ThumbState: Equatable {
        case loading
        case ready(UIImage)
        case failed
    }

    @State private var tab: Tab = .text
    @State private var textState: TextState = .loading
    @State private var cardsState: CardsState = .loading
    @State private var docState: DocState = .loading
    @State private var thumbState: ThumbState = .loading
    @State private var showOriginal = false
    /// 文档行敏感真值（缩略图 = 原图内容，FR14.2 查看留痕与文案共同依赖）。
    @State private var docSensitive = false
    @State private var didAuditThumbnail = false

    var body: some View {
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
            // 文本/卡片/文档行先就绪（缩略图不 gate 内容，UX 席 P1-4）。
            .task(id: documentId) { await loadBasics() }
            .task(id: documentId) { await loadThumbnail() }
            .sheet(isPresented: $showOriginal) {
                DocumentSourcePageView(documentId: documentId, patientId: patientId, pageIndex: 0)
            }
            // 缩略图即原图内容：退后台时随系统隐私遮罩隐去（与原件页同纪律）。
            .privacySensitive(scenePhase != .active)
        }
    }

    // MARK: - 媒体卡（缩略 + 页数 + 看原图）

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if case .loaded(let grade) = docState {
                    GradeBadge(grade: grade)
                }
            }
            if case .failed = docState {
                unavailableBlock { Task { await loadBasics() } }
            } else {
                originalButton
                if let count = pageCount, count > 1 {
                    Text(L10n.entityCardHeaderPage(1, count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // 出口边界文案随真实设置（开发席 P2-3）：自动镜像开启且资料
            // 非敏感时，提交件会生成「文件」App 副本——不得再宣称「仅存本机」。
            Text(autoMirrorEnabled && !docSensitive
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
        case .loading: return itemCount > 1 ? itemCount : nil
        case .empty, .failed: return nil
        }
    }

    private var originalButton: some View {
        Button {
            showOriginal = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color("brand-primary", bundle: .main).opacity(0.08))
                switch thumbState {
                case .ready(let image):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                case .loading:
                    ProgressView()
                case .failed:
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        // 缩略图失败与「无原件路径」同形：原图入口仍可用，
                        // 真正的失败在原件页里如实呈现（UX 席 P1-4）。
                        Text(L10n.assistantMediaOpenOriginal)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 280)
            .overlay(alignment: .bottomTrailing) {
                Label(L10n.assistantMediaOpenOriginal, systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(10)
            }
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

    @ViewBuilder
    private var cardsTab: some View {
        switch cardsState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failed:
            errorBlock { Task { await loadBasics() } }
        case .loaded(let cards):
            if cards.isEmpty {
                emptyNote(L10n.assistantMediaCardsEmpty)
            } else {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        cardRow(card)
                    }
                }
            }
        }
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
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .accessibilityIdentifier("chat.mediaDetail.retry")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 载入

    private func loadBasics() async {
        textState = .loading
        cardsState = .loading
        docState = .loading
        switch await docs.mediaText(id: documentId, patientId: patientId) {
        case .pages(let pages): textState = .pages(pages)
        case .legacy(let text): textState = .legacy(text: text)
        case .empty: textState = .empty
        case .failed: textState = .failed
        }
        switch await docs.committedCards(documentId: documentId, patientId: patientId) {
        case .loaded(let kindIds):
            cardsState = .loaded(kindIds.map { CommittedCard(kind: $0.kind, id: $0.id) })
        case .failed:
            cardsState = .failed
        }
        if let doc = await docs.fetch(id: documentId), doc.patientId == patientId {
            docState = .loaded(grade: doc.grade)
            docSensitive = doc.isSensitive
        } else {
            docState = .failed
        }
    }

    private func loadThumbnail() async {
        thumbState = .loading
        guard let doc = await docs.fetch(id: documentId), doc.patientId == patientId,
              let json = doc.metaJSON,
              let meta = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],   // try?-ok: 元数据损坏=缩略图失败态
              let path = meta["original_path"] as? String,
              let resolved = docs.resolveMediaPath(path) else {
            thumbState = .failed
            return
        }
        let mime = doc.mimeType ?? "image/jpeg"
        let filePath = resolved.path
        do {
            let box = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                return ThumbnailBox(image: try DocumentSourceRenderer.image(data: data, mimeType: mime, pageIndex: 0))
            }.value
            // 页面已关闭时丢弃迟到结果（与原件页 operation 取消同纪律）。
            guard !Task.isCancelled else { return }
            thumbState = .ready(box.image)
            // FR14.2：敏感原图的缩略图展示同样留痕（一次/页面）。
            if doc.isSensitive, !didAuditThumbnail {
                app.auditViewSensitiveOriginal(documentId: documentId, title: doc.title ?? "")
                didAuditThumbnail = true
            }
        } catch {
            guard !Task.isCancelled else { return }
            thumbState = .failed
        }
    }
}
