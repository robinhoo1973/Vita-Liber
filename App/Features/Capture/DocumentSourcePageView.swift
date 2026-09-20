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

/// 后台解码产物的 Sendable 载体（UIImage 跨执行器回传的装箱；2026-09-20 修复）。
private final class RenderedImageBox: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

/// UI-only rendering: PDF pages are addressed explicitly, never passed to UIImage(data:).
@MainActor
enum DocumentSourceRenderer {
    enum Failure: Error { case unreadable, pageMissing }

    /// nonisolated（2026-09-20 告警清除）：两个静态纯函数在 Task.detached 内被
    /// 调用（Face ID 解锁后的解码不占主线程）——它们只消费入参、不触碰任何
    /// @MainActor 状态，Swift 6 语言模式下主隔离静态从外部调用是错误。
    nonisolated static func pageCount(data: Data, mimeType: String) throws -> Int {
        guard mimeType == "application/pdf" || data.starts(with: Data("%PDF".utf8)) else { return 1 }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw Failure.unreadable }
        return pdf.pageCount
    }

    nonisolated static func image(data: Data, mimeType: String, pageIndex: Int) throws -> UIImage {
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
    /// prepareMetadata 已取到的文档行（2026-09-20 修复：loadMedia 不再二次 fetch——）
    /// 敏感解锁路径此前每开一次页面查两遍同一行，且解锁后重查窗口内文档可被
    /// 并发归档/删除致解锁即失败）
    @State private var loadedDocument: DocumentStore.DocumentRow?
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
            .onChangeCompat(of: pageIndex) { _, _ in Task { await renderPage() }; scheduleRelock() }
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
                loadedDocument = doc
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
            // 2026-09-20 修复：取消路径必须复位在途守卫（SensitiveMediaContainer 同族修复）——
            // 旧实现 return 前置 unlocking 恒 true，无 relock 兜底的取消源会把解锁按钮永久禁用
            guard !Task.isCancelled else { unlocking = false; return }
            unlocking = false
            guard allowed else { return }
            unlocked = true
            unlockedAt = Date()
            lastActivity = Date()
            await loadMedia()
            guard !Task.isCancelled, !failed else { return }
            if case .document(let id, _) = source { app.auditViewSensitiveOriginal(documentId: id, title: "") }
            // 2026-09-20 修复（BR-007）：解锁后**必武装** 30s 空闲自动重锁——旧实现走
            // scheduleRelock()，其活跃信号合并（<1s 丢弃）恰把解锁后的第一次武装吞掉：
            // 不触碰屏幕即无限期解锁。此处直接武装（合并守卫只服务手势热路径）。
            relockTimer.schedule(onExpiry: { relock() })
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
            case .document:
                // 2026-09-20 修复：复用 prepareMetadata 已取的文档行（敏感解锁路径
                // 此前二次 fetch 同一行；且解锁后重查窗口内文档可被并发归档致解锁即失败）
                guard let document = loadedDocument else { throw DocumentSourceRenderer.Failure.unreadable }
                guard !Task.isCancelled else { return }
                if document.isSensitive && !unlocked {
                    sensitive = true; image = nil; data = nil; loading = false
                    return
                }
                guard let originalPath else { throw DocumentSourceRenderer.Failure.unreadable }
                // 大文件读取 + PDF 页数解析移出主 actor（2026-09-20 修复：旧实现
                // Data(contentsOf:) 数十 MB + PDFDocument 整册解析在 Face ID 解锁后
                // 同步跑在主线程——「人脸识别后图片不出来」的卡死/假死主因之一）
                let path = originalPath
                let mime = mimeType
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let read = try Data(contentsOf: URL(fileURLWithPath: path))
                    let count = try DocumentSourceRenderer.pageCount(data: read, mimeType: mime)
                    return (read, count)
                }.value
                bytes = loaded.0
                pageCount = loaded.1
            }
            guard !Task.isCancelled else { return }
            data = bytes
            await renderPage()
            loading = false
        } catch { loading = false; failed = true }
    }

    /// 解码在后台执行器（2026-09-20 修复：PDF 整册解析 + 2048px 缩略图/降采样
    /// 原为同步主线程工作，翻页每次重解析——大扫描件每次数秒级主线程停顿）。
    /// pageIndex 越界钳制（旧卡 pageIndex ≥ 实际页数 → 原实现 pageMissing 必失败）；
    /// 代次守卫防快速翻页时迟到的旧页结果覆盖新页。
    @State private var renderGeneration = 0
    private func renderPage() async {
        guard !sensitive || unlocked, let data else { return }
        let mime = mimeType
        let bytes = data
        let target = min(pageIndex, max(0, pageCount - 1))
        renderGeneration += 1
        let generation = renderGeneration
        do {
            let box = try await Task.detached(priority: .userInitiated) {
                try RenderedImageBox(DocumentSourceRenderer.image(data: bytes, mimeType: mime, pageIndex: target))
            }.value
            guard generation == renderGeneration else { return }   // 迟到的旧页结果弃件
            image = box.image
            scale = 1; failed = false
        } catch {
            guard generation == renderGeneration else { return }
            image = nil; failed = true
        }
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
