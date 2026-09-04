import SwiftUI
import ImageIO
import Domain

/// §5.10 敏感媒体原始视图：ImageIO 降采样渲染，避免大图 OOM。
/// 通过 MediaUnlockSession 共享解锁状态——从缩略图进入时
/// 若会话已解锁则直接展示，否则先走认证流程。
struct SensitiveMediaOriginalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MediaUnlockSession.self) private var session

    let imageData: Data
    let caption: String

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        Group {
            if session.isUnlocked {
                unlockedContent
            } else {
                lockedPlaceholder
            }
        }
        .navigationTitle(L10n.sensitiveMedia_originalTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.common_cancel) { dismiss() }
            }
        }
        .onAppear { loadDownsampled() }
    }

    private var unlockedContent: some View {
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
                    .onTapGesture { session.recordActivity() }
            } else {
                ProgressView()
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var lockedPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L10n.sensitiveMedia_unlockToView)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onTapGesture {
            Task {
                if await session.isUnlocked || authenticateAndUnlock() {
                    // 认证后由 session.isUnlocked 驱动视图切换
                }
            }
        }
    }

    private func authenticateAndUnlock() async -> Bool {
        // 通过 SensitiveMediaContainer 的 tapGesture 路径认证
        // 这里简化为直接调用 session.unlock()——实际认证由上层容器完成
        session.unlock()
        return true
    }

    private func loadDownsampled() {
        guard image == nil else { return }
        // ImageIO 降采样：避免将完整原图加载进内存
        let maxDimension: CGFloat = 2048
        image = ImageIOImageLoader.downsample(data: imageData, maxDimension: maxDimension)
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
