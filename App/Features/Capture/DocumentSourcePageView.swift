import SwiftUI
import UIKit
import PDFKit
import Domain
import Infrastructure
import Perception

struct DocumentSourcePageReference: Equatable {
    let documentId: UUID
    let pageIndex: Int

    init?(sourceRef: String) {
        let parts = sourceRef.components(separatedBy: "#p")
        guard parts.count == 2, parts[0].hasPrefix("doc:"),
              let document = UUID(uuidString: String(parts[0].dropFirst(4))),
              let page = Int(parts[1]), page >= 0 else { return nil }
        documentId = document; pageIndex = page
    }
}

/// UI-only rendering: PDF pages are addressed explicitly, never passed to UIImage(data:).
@MainActor
enum DocumentSourceRenderer {
    enum Failure: Error { case unreadable, pageMissing }

    static func pageCount(data: Data, mimeType: String) throws -> Int {
        guard mimeType == "application/pdf" || data.starts(with: Data("%PDF".utf8)) else { return 1 }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw Failure.unreadable }
        return pdf.pageCount
    }

    static func image(data: Data, mimeType: String, pageIndex: Int) throws -> UIImage {
        if mimeType == "application/pdf" || data.starts(with: Data("%PDF".utf8)) {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pageIndex >= 0,
                  let page = pdf.page(at: pageIndex) else { throw Failure.pageMissing }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw Failure.unreadable }
            let scale = min(1, 2048 / max(bounds.width, bounds.height))
            return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        }
        guard pageIndex == 0, let image = ImageIOImageLoader.downsample(data: data, maxDimension: 2048) else { throw Failure.unreadable }
        return image
    }
}

struct DocumentSourcePageView: View {
    private enum Source {
        case document(UUID, UUID)
        case draft(DocumentsState.ImportDraft)
    }
    private let source: Source
    @State private var pageIndex: Int
    @State private var pageCount = 1
    @State private var patientId: UUID
    @State private var sensitive = true
    @State private var originalPath: String?
    @State private var mimeType = ""
    @State private var data: Data?
    @State private var image: UIImage?
    @State private var loading = true
    @State private var failed = false
    @State private var unlocked = false
    @State private var unlocking = false
    @State private var scale: CGFloat = 1
    @State private var operation: Task<Void, Never>?
    /// 空闲重锁计时器（审查修复：第四份手写 relockTask 脚手架收敛进共享
    /// MediaRelockTimer——改 TTL 语义/取消纪律只此一处机制）
    @State private var relockTimer = MediaRelockTimer()
    /// 认证成功时刻（inactive 重锁宽限锚点，MediaUnlockPolicy 判定用）
    @State private var unlockedAt: Date?
    /// 活跃信号合并（MediaUnlockPolicy.activityCoalescingWindow）
    @State private var lastActivity: Date?
    /// 原文行高亮区（归一化 0…1，来自识别层实测 bbox；nil = 不画）。
    /// 框级锚定三纪律：测量来源 / fail-closed（匹配不上不画）/
    /// 归一化坐标——越界即不画，绝不伪造。
    private let highlight: LayoutRect?
    @Environment(DocumentsState.self) private var docs
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(documentId: UUID, patientId: UUID, pageIndex: Int, highlight: LayoutRect? = nil) {
        source = .document(documentId, patientId)
        _patientId = State(initialValue: patientId)
        _pageIndex = State(initialValue: pageIndex)
        self.highlight = highlight
    }

    init(draft: DocumentsState.ImportDraft, pageIndex: Int, highlight: LayoutRect? = nil) {
        source = .draft(draft)
        _patientId = State(initialValue: draft.patientId)
        _pageIndex = State(initialValue: pageIndex)
        self.highlight = highlight
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 12) {
                    OCRReviewOwnerRow(patientId: patientId).padding(.horizontal)
                    if loading { ProgressView() }
                    else if failed {
                        VLUnavailableView {
                            Label(L10n.sensitiveMedia_loadFailed, systemImage: "exclamationmark.triangle")
                        } actions: { Button(L10n.retry) { startLoad() } }
                    } else if sensitive && !unlocked {
                        Button { unlock() } label: {
                            Label(L10n.sensitiveMedia_unlockToView, systemImage: "lock.fill")
                                .frame(maxWidth: .infinity, minHeight: 64)
                        }.disabled(unlocking)
                    } else if let image {
                        GeometryReader { geometry in
                            ScrollView([.horizontal, .vertical]) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: geometry.size.width * scale)
                                    .overlay {
                                        // 框级锚定高亮：归一化 bbox → 适配帧内
                                        // 描边矩形（fail-closed：越界不画）
                                        if let highlight, highlight.x >= 0, highlight.y >= 0,
                                           highlight.x + highlight.width <= 1,
                                           highlight.y + highlight.height <= 1 {
                                            GeometryReader { inner in
                                                let fittedHeight = inner.size.width
                                                    * (image.size.height / max(image.size.width, 1))
                                                Rectangle()
                                                    .stroke(Color("semantic-warning", bundle: .main), lineWidth: 2)
                                                    .frame(width: max(0, inner.size.width * highlight.width),
                                                           height: max(0, fittedHeight * highlight.height))
                                                    .position(x: inner.size.width * (highlight.x + highlight.width / 2),
                                                              y: fittedHeight * (highlight.y + highlight.height / 2))
                                            }
                                        }
                                    }
                                    .accessibilityIdentifier("OCR.source.page.\(pageIndex)")
                            }
                            .gesture(MagnificationGesture().onChanged { scale = min(5, max(1, $0)); scheduleRelock() })
                            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in scheduleRelock() })
                        }
                        Stepper(L10n.entityCardHeaderPage(pageIndex + 1, pageCount), value: $pageIndex, in: 0...max(0, pageCount - 1))
                            .padding(.horizontal)
                    }
                    Spacer(minLength: 0)
                }
                .navigationTitle(L10n.docViewOriginal)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.onboard_gotIt) { dismiss() } }
                }
            }
            .privacySensitive(scenePhase != .active)
            .task { await prepareMetadata() }
            .onChangeCompat(of: pageIndex) { _, _ in renderPage(); scheduleRelock() }
            .onChangeCompat(of: scenePhase) { _, phase in
                // background = 真离开恒立即重锁；inactive 可能是认证浮层
                // 收起瞬态——解锁后 5 秒内不重锁（MediaUnlockPolicy，
                // 业主「最低认证要求至少 5 秒」，同 SensitiveMedia 族）
                if phase == .background { relock() }
                else if phase != .active, unlocked,
                        MediaUnlockPolicy.shouldRelockOnInactive(lastUnlockAt: unlockedAt ?? Date(), now: Date()) {
                    relock()
                }
            }
            .onDisappear { operation?.cancel(); relock() }
        }
    }

    private func prepareMetadata() async {
        loading = true; failed = false
        do {
            switch source {
            case .draft(let draft):
                sensitive = draft.isSensitive; mimeType = draft.mimeType
                pageCount = max(1, draft.pages.count)
            case .document(let id, let patient):
                guard let doc = await docs.fetch(id: id), doc.patientId == patient,
                      let json = doc.metaJSON,
                      let meta = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let path = meta["original_path"] as? String else { throw DocumentSourceRenderer.Failure.unreadable }
                guard !Task.isCancelled else { return }
                sensitive = doc.isSensitive; originalPath = path; mimeType = doc.mimeType ?? "image/jpeg"
            }
            loading = false
            if !sensitive { await loadMedia() }
        } catch { loading = false; failed = true }
    }

    private func startLoad() {
        operation?.cancel()
        operation = Task {
            await prepareMetadata()
            if sensitive && unlocked && !failed { await loadMedia() }
        }
    }

    private func unlock() {
        guard !unlocking else { return }
        unlocking = true
        let task = Task {
            let allowed = await app.requestUnlock(reason: L10n.sensitive_unlockReason)
            guard !Task.isCancelled else { return }
            unlocking = false
            guard allowed else { return }
            unlocked = true
            unlockedAt = Date()
            lastActivity = Date()
            await loadMedia()
            guard !Task.isCancelled, !failed else { return }
            if case .document(let id, _) = source { app.auditViewSensitiveOriginal(documentId: id, title: "") }
            scheduleRelock()
        }
        operation = task
        relockTimer.trackUnlock(task)
    }

    private func loadMedia() async {
        loading = true; failed = false
        do {
            let bytes: Data
            switch source {
            case .draft(let draft): bytes = draft.mimeType == "application/pdf" ? draft.originalData : draft.processedData
            case .document(let documentID, let patient):
                guard let document = await docs.fetch(id: documentID), document.patientId == patient else {
                    throw DocumentSourceRenderer.Failure.unreadable
                }
                guard !Task.isCancelled else { return }
                if document.isSensitive && !unlocked {
                    sensitive = true; image = nil; data = nil; loading = false
                    return
                }
                guard let originalPath else { throw DocumentSourceRenderer.Failure.unreadable }
                bytes = try Data(contentsOf: URL(fileURLWithPath: originalPath))
            }
            guard !Task.isCancelled else { return }
            pageCount = try DocumentSourceRenderer.pageCount(data: bytes, mimeType: mimeType)
            data = bytes
            renderPage()
            loading = false
        } catch { loading = false; failed = true }
    }

    private func renderPage() {
        guard !sensitive || unlocked, let data else { return }
        do {
            image = try DocumentSourceRenderer.image(data: data, mimeType: mimeType, pageIndex: pageIndex)
            scale = 1; failed = false
        } catch { image = nil; failed = true }
    }

    private func scheduleRelock() {
        guard sensitive && unlocked else { return }
        // 活跃信号合并（MediaUnlockPolicy.activityCoalescingWindow）
        let now = Date()
        if let lastActivity, !MediaUnlockPolicy.shouldRecordActivity(lastInteraction: lastActivity, now: now) { return }
        self.lastActivity = now
        relockTimer.schedule(onExpiry: { relock() })
    }

    private func relock() {
        relockTimer.cancelAll()
        operation?.cancel(); operation = nil
        unlocked = false; unlocking = false; data = nil; image = nil
        // 审查修复（缩放跨解锁周期泄漏）：重锁必须回到初始适配视图——
        // 下一位认证用户不得看到上一人的取景位置（SensitiveMediaOriginalView
        // 同族修复，本视图此前漏修）。
        scale = 1
        unlockedAt = nil
        lastActivity = nil
        loading = false
    }
}
