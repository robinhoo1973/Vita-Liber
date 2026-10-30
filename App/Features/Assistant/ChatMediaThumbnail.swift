import SwiftUI
import UIKit
import PDFKit
import Domain
import Infrastructure
import Perception

/// 聊天媒体缩略图（2026-10-29 审查批）：气泡与速记详情共用的小圆角方块。
/// 单一加载实现（不再各自复制 resolve→读盘→解码）：图像走 ImageIO 降采样，
/// PDF 走页缩略图；按内容身份缓存，重复开关详情不重复读盘/解码。
/// BR-007：缩略图即原图内容，退后台随系统隐私遮罩隐去（与原件页同纪律）。
struct ChatMediaThumbnail: View {
    let documentId: UUID
    let patientId: UUID
    /// 方块边长（pt）。解码按 2x 上限降采样，不把原图整幅读进内存。
    var size: CGFloat = 76
    var cornerRadius: CGFloat = 12
    /// PDF/合并多页文档的页号（业主 2026-10-30：多附件各出缩略图）。
    /// 位图只有第 0 页；越界由渲染器失败态承接。
    var pageIndex: Int = 0
    var fallbackSymbol: String = "photo"
    /// FR14.2 查看留痕（速记详情用；聊天气泡不逐条留痕，避免打开会话即刷屏）。
    var auditsSensitive = false
    /// 详情缩略图条预解析的文档元数据（父视图一次读行/解析 meta，N 张共享；
    /// 2026-10-30 效率批：此前每张各自 documentRow+JSON 解析）。
    struct Preloaded: Sendable {
        let path: String
        let mimeType: String
        let isSensitive: Bool
        let title: String
        /// 内容身份（sha256 或 createdAt 时间戳）——缓存键组成部分。
        let cacheIdentity: String
    }
    var preloaded: Preloaded? = nil

    @Environment(DocumentsState.self) private var docs
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var image: UIImage?
    @State private var failed = false
    @State private var didAudit = false
    /// 已装载的文档身份：视图复用换 documentId 时先清旧图，避免新件读取
    /// 失败还继续显示上一件的缩略图（跨件内容泄漏/误导；2026-10-29 round2）。
    @State private var loadedDocumentId: UUID?
    @State private var loadedPageIndex = 0
    /// 内容身份（docId+sha/createdAt+size）：同一 documentId 复核/重导入换内容时
    /// 也必须先清旧图——否则新图读取失败会继续显示上一版医学影像。
    @State private var loadedCacheKey: String?
    /// 文档行读不到时不知道 MIME；读到后 PDF 用文档图标占位（不冒充相片）。
    @State private var resolvedFallback = ""

    /// UIImage 跨执行器装箱（与 DocumentSourcePageView 的 RenderedImageBox 同模式）。
    private final class Box: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: resolvedFallback.isEmpty ? fallbackSymbol : resolvedFallback)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .privacySensitive(scenePhase != .active)
        // 预载元数据到达后重跑一次（此前任务只按 doc|page 触发，先失败/
        // 先逐张读行的缩略图不会因父视图一次解析完成而受益）。
        .task(id: "\(documentId.uuidString)|\(pageIndex)|\(preloaded?.cacheIdentity ?? "-")") {
            await load()
        }
        .accessibilityHidden(true)
    }

    private func load() async {
        failed = false
        if loadedDocumentId != documentId || loadedPageIndex != pageIndex {
            loadedDocumentId = documentId
            loadedPageIndex = pageIndex
            image = nil
            didAudit = false
            resolvedFallback = ""
        }
        let info: (path: String, mime: String, sensitive: Bool, title: String, identity: String)
        if let preloaded {
            info = (preloaded.path, preloaded.mimeType, preloaded.isSensitive,
                    preloaded.title, preloaded.cacheIdentity)
        } else {
            guard let doc = await docs.documentRow(id: documentId), doc.patientId == patientId,
                  let json = doc.metaJSON,
                  let meta = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],   // try?-ok: 元数据损坏=缩略图占位态
                  let path = meta["original_path"] as? String,
                  let resolved = docs.resolveMediaPath(path) else {
                if !Task.isCancelled, loadedDocumentId == documentId,
                   loadedPageIndex == pageIndex { failed = true }
                return
            }
            let identity = doc.sha256 ?? "t\(doc.createdAt.timeIntervalSince1970)"
            info = (resolved.path, doc.mimeType ?? "image/jpeg",
                    doc.isSensitive, doc.title ?? "", identity)
        }
        guard !Task.isCancelled, loadedDocumentId == documentId else { return }
        resolvedFallback = (info.mime == "application/pdf") ? "doc.fill" : fallbackSymbol
        let key = ChatMediaThumbnailCache.key(documentId: documentId, identity: info.identity,
                                              size: size, pageIndex: pageIndex)
        if loadedCacheKey != (key as String) {
            loadedCacheKey = key as String
            image = nil
            didAudit = false
        }
        if let cached = ChatMediaThumbnailCache.image(for: key) {
            image = cached
            auditIfNeeded(isSensitive: info.sensitive, title: info.title)
            return
        }
        let mime = info.mime
        let filePath = info.path
        // PDF 页面渲染按 pt 的 2x 输出；位图由 ImageIO 内置降采样处理。
        let maxDimension = Int(size * 2)
        let renderPage = pageIndex
        do {
            if mime == "application/pdf" {
                // PDF 走共享 actor：同一文件只解析一次 PDFDocument，页缩略图串行渲染
                //（2026-10-30 效率批：此前 N 页=N 次全量解析，10–30MB 文件滚动即卡）。
                let box = try await ChatMediaPDFThumbnailRenderer.shared.thumbnail(
                    path: filePath, page: renderPage, maxDimension: maxDimension)
                guard !Task.isCancelled, loadedDocumentId == documentId,
                      loadedPageIndex == pageIndex else { return }
                image = box.image
                ChatMediaThumbnailCache.store(box.image, for: key)
                auditIfNeeded(isSensitive: info.sensitive, title: info.title)
                return
            }
            // detached 不继承父任务取消：用 cancellation handler 把视图消失/
            // 换 documentId 的取消显式转给解码任务，避免大图/PDF 解码跑完
            // 后才发现结果已无人接收。
            let job = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                // mappedIfSafe：大文件不先整段复制进堆；ImageIO/PDFKit 仍按需读页。
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
                try Task.checkCancellation()
                return Box(try DocumentSourceRenderer.image(data: data, mimeType: mime,
                                                            pageIndex: renderPage, maxDimension: maxDimension))
            }
            let box = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            // 页号也要校验：视图复用换页后旧页结果不得写回（缓存键含页号，
            // 写回守卫原先只看 documentId，快速翻页会显示错页；2026-10-30 复审）。
            guard !Task.isCancelled, loadedDocumentId == documentId,
                  loadedPageIndex == pageIndex else { return }
            image = box.image
            ChatMediaThumbnailCache.store(box.image, for: key)
            auditIfNeeded(isSensitive: info.sensitive, title: info.title)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    private func auditIfNeeded(isSensitive: Bool, title: String) {
        guard auditsSensitive, isSensitive, !didAudit else { return }
        app.auditViewSensitiveOriginal(documentId: documentId, title: title)
        didAudit = true
    }
}

/// PDF 页缩略图：同一文件缓存 PDFDocument，跨页串行渲染。
/// PDFKit 文档对象不声明 Sendable；所有访问收敛在本 actor 内，避免
/// 每张缩略图各自 PDFDocument(data:) 全量解析与跨线程共享。
actor ChatMediaPDFThumbnailRenderer {
    enum Failure: Error { case unreadable, pageMissing }

    static let shared = ChatMediaPDFThumbnailRenderer()

    private struct Cached {
        let key: String
        let document: PDFDocument
    }
    private var cache: [Cached] = []
    private let capacity = 4

    func thumbnail(path: String, page: Int, maxDimension: Int) throws -> ChatMediaPDFBox {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(mtime)"
        let document: PDFDocument
        if let hit = cache.first(where: { $0.key == key }) {
            document = hit.document
            cache.removeAll { $0.key == key }
            cache.insert(hit, at: 0)
        } else {
            guard let fresh = PDFDocument(url: URL(fileURLWithPath: path)), !fresh.isLocked else {
                throw Failure.unreadable
            }
            document = fresh
            cache.insert(Cached(key: key, document: fresh), at: 0)
            if cache.count > capacity { cache.removeLast() }
        }
        guard page >= 0, let pdfPage = document.page(at: page) else {
            throw Failure.pageMissing
        }
        let bounds = pdfPage.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw Failure.unreadable
        }
        let limit = CGFloat(max(64, maxDimension))
        let scale = min(1, limit / max(bounds.width, bounds.height))
        let image = pdfPage.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox)
        return ChatMediaPDFBox(image)
    }
}

/// UIImage 跨执行器装箱（与视图内 Box 同模式）。
struct ChatMediaPDFBox: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

/// 缩略图缓存：键含内容身份（sha256/创建时间）——复核不改原件不失效，
/// 重新导入换内容即换键，不会显示旧图。
enum ChatMediaThumbnailCache {
    /// NSCache 无 Sendable 标注（自身线程安全）；用 Sendable 箱承载，
    /// 满足 Swift 6 静态共享状态纪律（与 SensitiveAssetStore.CacheBox 同模式）。
    private final class CacheBox: @unchecked Sendable {
        let cache: NSCache<NSString, UIImage> = {
            let cache = NSCache<NSString, UIImage>()
            cache.countLimit = 200
            return cache
        }()
    }

    private static let box = CacheBox()

    static func key(documentId: UUID, contentHash: String?, createdAt: Date, size: CGFloat,
                    pageIndex: Int = 0) -> NSString {
        key(documentId: documentId,
            identity: contentHash ?? "t\(createdAt.timeIntervalSince1970)",
            size: size, pageIndex: pageIndex)
    }

    static func key(documentId: UUID, identity: String, size: CGFloat,
                    pageIndex: Int = 0) -> NSString {
        "\(documentId.uuidString)|\(identity)|\(Int(size))|p\(pageIndex)" as NSString
    }

    static func image(for key: NSString) -> UIImage? {
        box.cache.object(forKey: key)
    }

    static func store(_ image: UIImage, for key: NSString) {
        box.cache.setObject(image, forKey: key)
    }
}
