import SwiftUI
import UIKit
import Domain
import Infrastructure
import Protocols   // EngineRegistry（裁剪复跑 OCR 的引擎解析）
import Perception

/// 数据信息元的「识别来源」裁片（2026-11-02 业主真机）：
/// 只显示该字段对应的原文行区域，而不是整页原图。
///
/// 版面优先取自落库快照 `meta.ocr_review`（与抽取时的 `sourceLineIndex` 同源）；
/// 旧文档无快照时才按需重跑同一条本机 OCR 管线（经 EngineRegistry 解析引擎）。
/// 按 `sourceLineIndex` + 原文行双重锚定；`PageLayout.linesOnly` 等分块不是实测
/// 几何，一律按未定位处理并显示整页，绝不伪造裁片。零网络。
struct ChatMediaSourceCropView: View {
    let documentId: UUID
    let patientId: UUID
    let pageIndex: Int
    let lineIndex: Int?
    let sourceText: String

    @Environment(DocumentsState.self) private var docs
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var usedFullPage = false
    @State private var loading = true
    @State private var failed = false
    @State private var loadID = UUID()
    @State private var didAudit = false

    private struct ImageBox: @unchecked Sendable {
        let image: UIImage
    }

    private final class LayoutBox: NSObject {
        /// nil = 该页确认无实测版面（负缓存，避免每次点「看图」重跑 Vision）。
        let layout: PageLayout?
        init(_ layout: PageLayout?) { self.layout = layout }
    }

    private final class LayoutCache: @unchecked Sendable {
        let store = NSCache<NSString, LayoutBox>()
        init() {
            store.countLimit = 200
        }
    }

    /// 页级版面缓存：同一文档/页的多个字段共重复用，避免每次点「看图」都跑 Vision。
    private static let layoutCache = LayoutCache()

    /// 落库快照里本页的实测版面（ReviewSnapshot.pages[].layout）。
    private struct StoredReview: Decodable {
        struct Page: Decodable {
            let index: Int
            let layout: PageLayout?
        }
        let pages: [Page]
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView(L10n.chatMediaCropLoading)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if failed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                        Text(L10n.chatMediaCropFailed)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(L10n.retry) { reload() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("chat.mediaDetail.crop.retry")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if let image {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 360)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityIdentifier("chat.mediaDetail.crop.image")
                            if usedFullPage {
                                Text(L10n.chatMediaCropFullPageNote)
                                    .font(.caption2)
                                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                            }
                            Text(sourceText.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(L10n.chatMediaCropTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.assistantClose) { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
            .privacySensitive(scenePhase != .active)
            .task(id: loadID) { await load() }
        }
    }

    private func reload() {
        loadID = UUID()
        loading = true
        failed = false
        image = nil
        usedFullPage = false
    }

    private func load() async {
        loading = true
        failed = false
        image = nil
        usedFullPage = false
        do {
            guard let doc = await docs.documentRow(id: documentId), doc.patientId == patientId,
                  let json = doc.metaJSON,
                  let meta = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],   // try?-ok: 元数据损坏=裁片失败态
                  let path = meta["original_path"] as? String,
                  let resolved = docs.resolveMediaPath(path) else {
                throw CropError.unreadable
            }
            if doc.isSensitive, !didAudit {
                app.auditViewSensitiveOriginal(documentId: documentId, title: doc.title ?? "")
                didAudit = true
            }
            let mime = doc.mimeType ?? "image/jpeg"
            let filePath = resolved.path
            let page = pageIndex
            // 快照串参与缓存键：重新识别会重写 ocr_review 而 sha/createdAt 不变。
            let reviewJSON = meta["ocr_review"] as? String
            let snapshotIdentity = reviewJSON?.hashValue ?? 0
            let cacheKey = "\(documentId.uuidString)#\(page)#\(snapshotIdentity)#\(doc.sha256 ?? doc.createdAt.timeIntervalSince1970.description)" as NSString
            // detached 不继承父任务取消：把 .task(id:) 的取消显式转给解码任务，
            // 避免视图关闭/重试后旧解码与旧 Vision 仍占 CPU（同 ChatMediaThumbnail 纪律）。
            let decodeJob = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
                try Task.checkCancellation()
                let pageImage = try DocumentSourceRenderer.image(data: data, mimeType: mime,
                                                                  pageIndex: page, maxDimension: 2048)
                return ImageBox(image: pageImage)
            }
            let box = try await withTaskCancellationHandler {
                try await decodeJob.value
            } onCancel: {
                decodeJob.cancel()
            }
            guard !Task.isCancelled else { return }
            let layout: PageLayout?
            if let cached = Self.layoutCache.store.object(forKey: cacheKey) {
                layout = cached.layout
            } else {
                // 优先用落库快照（与抽取同一次 OCR），旧文档才重跑。
                let stored = Self.storedLayout(from: reviewJSON, page: page)
                if let stored {
                    layout = stored
                    Self.layoutCache.store.setObject(LayoutBox(stored), forKey: cacheKey)
                } else if docs.canRunOCR {
                    let pipeline = OCRPipeline(
                        recognizer: EngineRegistry.shared.resolve(OCRRecognizerFactory.self),
                        grayscaleDecoder: GrayscaleImageDecoder())
                    // JPEG 编码 + Vision 均在工作线程；主线程只挂结果。
                    let ocrJob = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        guard let jpeg = box.image.jpegData(compressionQuality: 0.9) else {
                            throw CropError.unreadable
                        }
                        return try await pipeline.run(imageData: jpeg)
                    }
                    let result = try await withTaskCancellationHandler {
                        try await ocrJob.value
                    } onCancel: {
                        ocrJob.cancel()
                    }
                    guard !Task.isCancelled else { return }
                    let measured = result.layout.flatMap { Self.measured($0) }
                    layout = measured
                    Self.layoutCache.store.setObject(LayoutBox(measured), forKey: cacheKey)
                } else {
                    // FR14.1 授权关闭：不得为裁片另起 OCR，诚实退化整页；
                    // 且不缓存「无版面」，重新开启后仍可再试。
                    layout = nil
                }
            }
            if let layout, let rect = matchingRect(in: layout) {
                let cropped = Self.crop(box.image, to: rect)
                image = cropped ?? box.image
                usedFullPage = cropped == nil
            } else {
                image = box.image
                usedFullPage = true
            }
            loading = false
        } catch is CancellationError {
            return
        } catch {
            loading = false
            failed = true
        }
    }

    private enum CropError: Error { case unreadable }

    /// `meta.ocr_review` 是嵌套 JSON 字符串（ReviewSnapshot）；取本页实测版面。
    private static func storedLayout(from reviewJSON: String?, page: Int) -> PageLayout? {
        guard let reviewJSON, let data = reviewJSON.data(using: .utf8),
              let review = try? JSONDecoder().decode(StoredReview.self, from: data),   // try?-ok: 快照损坏=无版面，回落重跑
              let layout = review.pages.first(where: { $0.index == page })?.layout else { return nil }
        return measured(layout)
    }

    /// `PageLayout.linesOnly` 的等分块不是来源区域：只接受实测几何。
    private static func measured(_ layout: PageLayout) -> PageLayout? {
        guard !layout.blocks.isEmpty else { return nil }
        let h = 1.0 / Double(layout.blocks.count)
        let synthetic = layout.blocks.enumerated().allSatisfy { index, block in
            block.confidence == 0
                && block.bbox.x == 0 && block.bbox.width == 1
                && block.bbox.height == h && block.bbox.y == Double(index) * h
        }
        return synthetic ? nil : layout
    }

    /// 优先按字段行号取 bbox；行号与复跑结果不一致时按原文文本匹配。
    private func matchingRect(in layout: PageLayout) -> LayoutRect? {
        // 无原文文本时不猜：旧行号可能已被编辑/重排，直接整页 + 未定位提示。
        let target = Self.normalized(sourceText)
        guard !target.isEmpty else { return nil }
        if let lineIndex, layout.blocks.indices.contains(lineIndex) {
            let block = layout.blocks[lineIndex]
            if Self.textMatches(block.text, target) { return block.bbox }
        }
        let matches = layout.blocks.filter {
            Self.textMatches($0.text, target)
        }
        // 多个候选行视为歧义：不猜，整页 + 未定位提示。
        return matches.count == 1 ? matches[0].bbox : nil
    }

    /// 归一后匹配：正向包含始终可信；反向（字段原文包含整块）须覆盖足够原文，
    /// 避免短块（「2026」）被唯一匹配成整行来源。
    private static func textMatches(_ blockText: String, _ target: String) -> Bool {
        let text = normalized(blockText)
        guard !text.isEmpty else { return false }
        if text.contains(target) { return true }
        guard target.contains(text) else { return false }
        return Double(text.count) >= 0.4 * Double(target.count)
    }

    /// 与抽取锚定同一归一化口径（NFKC + 全角冒号折叠 + 去空白），不另起一套。
    private static func normalized(_ text: String) -> String {
        ExtractionGrounding.folded(text).lowercased()
    }

    private static func crop(_ image: UIImage, to rect: LayoutRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        var crop = CGRect(x: rect.x * width, y: rect.y * height,
                          width: rect.width * width, height: rect.height * height)
        guard crop.width > 1, crop.height > 1 else { return nil }
        let padX = max(4, width * 0.02)
        let padY = max(4, height * 0.02)
        crop = crop.insetBy(dx: -padX, dy: -padY)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard crop.width > 1, crop.height > 1,
              let cropped = cg.cropping(to: crop.integral) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}
