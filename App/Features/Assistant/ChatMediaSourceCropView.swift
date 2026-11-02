import SwiftUI
import UIKit
import Domain
import Infrastructure
import Perception

/// 数据信息元的「识别来源」裁片（2026-11-02 业主真机）：
/// 只显示该字段对应的原文行区域，而不是整页原图。
///
/// 版面不持久化：按需对当前页重新跑同一条本机 OCR 管线，取得 `PageLayout` 的
/// 实测 bbox；按 `sourceLineIndex` + 原文行双重锚定，匹配不上则诚实显示整页
/// 并标注「未定位」，绝不伪造裁片。零网络。
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
        let layout: PageLayout
        init(_ layout: PageLayout) { self.layout = layout }
    }

    private final class LayoutCache: @unchecked Sendable {
        let store = NSCache<NSString, LayoutBox>()
    }

    /// 页级版面缓存：同一文档/页的多个字段共重复用，避免每次点「看图」都跑 Vision。
    private static let layoutCache = LayoutCache()

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
            let cacheKey = "\(documentId.uuidString)#\(page)#\(doc.sha256 ?? doc.createdAt.timeIntervalSince1970.description)" as NSString
            let box = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
                let pageImage = try DocumentSourceRenderer.image(data: data, mimeType: mime,
                                                                  pageIndex: page, maxDimension: 2048)
                return ImageBox(image: pageImage)
            }.value
            guard !Task.isCancelled else { return }
            let layout: PageLayout
            if let cached = Self.layoutCache.store.object(forKey: cacheKey) {
                layout = cached.layout
            } else {
                guard let jpeg = box.image.jpegData(compressionQuality: 0.9) else { throw CropError.unreadable }
                let pipeline = OCRPipeline(recognizer: VisionImageRecognizer(),
                                           grayscaleDecoder: GrayscaleImageDecoder())
                let result = try await pipeline.run(imageData: jpeg)
                guard !Task.isCancelled else { return }
                // 只有实测版面才裁片；linesOnly 的等分块不是真实来源区域。
                guard let measured = result.layout, !measured.blocks.isEmpty else {
                    image = box.image
                    usedFullPage = true
                    loading = false
                    return
                }
                layout = measured
                Self.layoutCache.store.setObject(LayoutBox(measured), forKey: cacheKey)
            }
            if let rect = matchingRect(in: layout) {
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

    /// 优先按字段行号取 bbox；行号与复跑结果不一致时按原文文本匹配。
    private func matchingRect(in layout: PageLayout) -> LayoutRect? {
        // 无原文文本时不猜：旧行号可能已被编辑/重排，直接整页 + 未定位提示。
        let target = Self.normalized(sourceText)
        guard !target.isEmpty else { return nil }
        if let lineIndex, layout.blocks.indices.contains(lineIndex) {
            let block = layout.blocks[lineIndex]
            if Self.normalized(block.text).contains(target)
                || target.contains(Self.normalized(block.text)) {
                return block.bbox
            }
        }
        let matches = layout.blocks.filter {
            let text = Self.normalized($0.text)
            return !text.isEmpty && (text.contains(target) || target.contains(text))
        }
        // 多个候选行视为歧义：不猜，整页 + 未定位提示。
        return matches.count == 1 ? matches[0].bbox : nil
    }

    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
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
