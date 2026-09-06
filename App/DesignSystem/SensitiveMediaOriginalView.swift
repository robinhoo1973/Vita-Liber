import SwiftUI
import ImageIO
import Domain

/// §5.10 敏感媒体原始视图：ImageIO 降采样渲染，避免大图 OOM。
/// 通过 MediaUnlockSession 共享解锁状态——从缩略图进入时
/// 若会话已解锁则直接展示，否则先走认证流程。
/// FR1.9 逐次解锁（V3.72）：解锁态为本视图私有——每次查看原图都是一次
/// 独立系统认证，不再经全局会话顺带解锁（与 SensitiveMediaContainer 同纪律）。
struct SensitiveMediaOriginalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let imageData: Data
    let caption: String

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var unlocked = false
    @State private var relockTask: Task<Void, Never>?

    var body: some View {
        Group {
            if unlocked {
                unlockedContent
            } else {
                lockedPlaceholder
            }
        }
        .navigationTitle(L10n.sensitiveMedia_originalTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.commonCancel) { dismiss() }
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
                            .onChanged {
                                scale = $0
                                scheduleRelock()   // 缩放亦属活跃，否则持续缩放 >30s 被中途重锁
                            }
                            .onEnded { scale = max(1, $0) }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged {
                                offset = $0.translation
                                scheduleRelock()
                            }
                            .onEnded { _ in
                                // 超过边界回弹
                                let maxX = (geo.size.width * (scale - 1)) / 2
                                let maxY = (geo.size.height * (scale - 1)) / 2
                                offset.width = min(maxX, max(-maxX, offset.width))
                                offset.height = min(maxY, max(-maxY, offset.height))
                            }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onTapGesture { scheduleRelock() }
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
                if !unlocked {
                    _ = await authenticateAndUnlock()
                }
            }
        }
    }

    private func authenticateAndUnlock() async -> Bool {
        // FR1.9：每次查看原图都是一次独立的系统设备所有者认证（Face ID/Touch ID
        // + 设备密码兜底），与 SensitiveMediaContainer 同路径，绝不允许无认证直通。
        guard await app.requestUnlock(reason: L10n.sensitive_unlockReason) else { return false }
        unlocked = true
        scheduleRelock()
        return true
    }

    private func scheduleRelock() {
        relockTask?.cancel()
        let ttl = MediaUnlockPolicy.idleTTL
        relockTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))   // try?-ok: 空闲重锁计时被取消即停，sleep 失败无副作用
            guard !Task.isCancelled else { return }
            relock()
        }
    }

    private func relock() {
        relockTask?.cancel()
        relockTask = nil
        unlocked = false
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
