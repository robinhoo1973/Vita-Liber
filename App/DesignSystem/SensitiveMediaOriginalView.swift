import SwiftUI
import ImageIO
import Domain
import Perception

/// §5.10 敏感媒体原始视图：ImageIO 降采样渲染，避免大图 OOM。
/// 2026-10-24 业主裁决 B：App 内直接显示，敏感标记只约束对外分享/导出；
/// 快照遮罩（privacySensitive）与查看审计（FR14.2）保留。
struct SensitiveMediaOriginalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var app

    /// 调用方可直接传入原图字节；有 loader 时优先从存储按需拉取。
    let imageData: Data?
    let caption: String
    /// 资产锚点：查看留痕锚点；nil = 无资产来源（如演示场景）
    var assetId: UUID?
    /// 按需拉取原图字节的加载器（ObservationMediaStrip 注入；nil = 用 imageData）
    var originalLoader: (() async -> Data?)?

    @State private var image: UIImage?
    @State private var displayData: Data?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 加载失败态（loader 返回 nil/空 = 文件不可读/已清理）——不得永远转圈。
    @State private var loadFailed = false
    @State private var loadTask: Task<Void, Never>?
    @State private var didAuditViewing = false

    var body: some View {
        WithPerceptionTracking {
            content
                .navigationTitle(L10n.sensitiveMedia_originalTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                }
                // BR-008：任务切换器快照仍遮罩（对外边界，不随 App 内直接显示退役）。
                .privacySensitive(scenePhase != .active)
                .onAppear {
                    guard loadTask == nil, image == nil, !loadFailed else { return }
                    loadTask = Task { await load() }
                }
                // 离开即取消读盘/解码：大文件任务不得在视图销毁后继续占用内存、
                // 更不得为未看到的原图写「已查看」审计。
                .onDisappear {
                    loadTask?.cancel()
                    loadTask = nil
                }
        }
    }

    private var content: some View {
        GeometryReader { geo in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = $0 }
                            .onEnded { scale = max(1, $0) }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { offset = $0.translation }
                            .onEnded { _ in
                                // 超过边界回弹
                                let maxX = (geo.size.width * (scale - 1)) / 2
                                let maxY = (geo.size.height * (scale - 1)) / 2
                                offset.width = min(maxX, max(-maxX, offset.width))
                                offset.height = min(maxY, max(-maxY, offset.height))
                            }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
            } else if loadFailed {
                // 失败卡给不透明浅底（bg-grouped 令牌），黑底只留给图片内容。
                VLUnavailableView(L10n.sensitiveMedia_loadFailed,
                                       systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color("bg-grouped", bundle: .main))
            } else {
                ProgressView()
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func load() async {
        loadFailed = false
        var bytes = imageData
        if let originalLoader {
            if let loaded = await originalLoader(), !loaded.isEmpty {
                bytes = loaded
            }
        }
        // 读盘期间视图已离开：不得复活解码与审计。
        guard !Task.isCancelled else { return }
        guard let bytes, !bytes.isEmpty else {
            loadFailed = true
            return
        }
        displayData = bytes
        image = nil
        loadDownsampled()
        guard !Task.isCancelled else { return }
        guard !loadFailed else { return }
        // FR14.2 审计：敏感原图查看留痕（直接显示后仍保留）。
        if let assetId, !didAuditViewing {
            app.auditViewSensitiveOriginal(documentId: assetId, title: caption)
            didAuditViewing = true
        }
    }

    private func loadDownsampled() {
        guard image == nil, let data = displayData else { return }
        // ImageIO 降采样：避免将完整原图加载进内存
        let maxDimension: CGFloat = 2048
        if let downsampled = ImageIOImageLoader.downsample(data: data, maxDimension: maxDimension) {
            image = downsampled
        } else {
            // 第八轮全仓审查修复：非空但不可解码的载荷（截断/损坏 JPEG、
            // 误标非图文件）——downsample 返回 nil 而 loadFailed 恒 false，
            // 解锁后永远转圈无出口（第七轮只修了 nil/空数据形态）。明示
            // 失败态，与既有失败出口（VLUnavailableView）同路径。
            loadFailed = true
        }
    }
}

/// ImageIO 降采样工具（tech-spec §5.10：避免大图 OOM）
enum ImageIOImageLoader {
    static func downsample(data: Data, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
        else { return nil }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension * UIScreen.main.scale
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary)
        else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
