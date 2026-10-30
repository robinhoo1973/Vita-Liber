import SwiftUI
import UIKit
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
        .task(id: "\(documentId.uuidString)|\(pageIndex)") { await load() }
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
        guard let doc = await docs.documentRow(id: documentId), doc.patientId == patientId,
              let json = doc.metaJSON,
              let meta = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],   // try?-ok: 元数据损坏=缩略图占位态
              let path = meta["original_path"] as? String,
              let resolved = docs.resolveMediaPath(path) else {
            if !Task.isCancelled, loadedDocumentId == documentId,
               loadedPageIndex == pageIndex { failed = true }
            return
        }
        guard !Task.isCancelled, loadedDocumentId == documentId else { return }
        resolvedFallback = (doc.mimeType == "application/pdf") ? "doc.fill" : fallbackSymbol
        let key = ChatMediaThumbnailCache.key(documentId: documentId, contentHash: doc.sha256,
                                              createdAt: doc.createdAt, size: size,
                                              pageIndex: pageIndex)
        if loadedCacheKey != (key as String) {
            loadedCacheKey = key as String
            image = nil
            didAudit = false
        }
        if let cached = ChatMediaThumbnailCache.image(for: key) {
            image = cached
            auditIfNeeded(isSensitive: doc.isSensitive, title: doc.title ?? "")
            return
        }
        let mime = doc.mimeType ?? "image/jpeg"
        let filePath = resolved.path
        // PDF 页面渲染按 pt 的 2x 输出；位图由 ImageIO 内置降采样处理。
        let maxDimension = Int(size * 2)
        let renderPage = pageIndex
        do {
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
            auditIfNeeded(isSensitive: doc.isSensitive, title: doc.title ?? "")
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
        let identity = contentHash ?? "t\(createdAt.timeIntervalSince1970)"
        return "\(documentId.uuidString)|\(identity)|\(Int(size))|p\(pageIndex)" as NSString
    }

    static func image(for key: NSString) -> UIImage? {
        box.cache.object(forKey: key)
    }

    static func store(_ image: UIImage, for key: NSString) {
        box.cache.setObject(image, forKey: key)
    }
}
