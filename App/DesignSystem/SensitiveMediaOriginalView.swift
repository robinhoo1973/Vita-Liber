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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var app

    /// 评审修正第二轮（BR-007 读取时序）：原图字节必须在**设备所有者认证通过后**
    /// 才落内存——此前调用方在认证前预取原图并持有（认证取消仍驻留）。
    /// 有 loader 时走「认证后拉取」路径（imageData 可为 nil）；无 loader 的
    /// 调用方（演示/预览）仍可直接传入 imageData。
    let imageData: Data?
    let caption: String
    /// 资产锚点（评审修正）：解锁成功后的审计锚点；nil = 无资产来源（如演示场景）
    var assetId: UUID?
    /// 认证通过后按需拉取原图字节的加载器（LockedMediaStrip 注入；nil = 用 imageData）
    var originalLoader: (() async -> Data?)?

    @State private var image: UIImage?
    @State private var displayData: Data?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var unlocked = false
    /// 第七轮修复：加载失败态（loader 返回 nil/空 = 文件不可读/已清理）——
    /// 原实现 unlocked=true 但 image/displayData 均 nil，永远转圈无出口
    @State private var loadFailed = false
    @State private var relockTask: Task<Void, Never>?
    /// 解锁在途守卫：同步置位——连点两次只触发一次系统认证（二次并发
    /// LAContext 求值必败且可能双弹认证层）
    @State private var unlocking = false
    /// 解锁在途任务句柄（第十一轮审查）：onDisappear/relock 必须能取消在途
    /// 解锁——认证已通过但 originalLoader 仍在读盘时用户关闭视图，任务恢复
    /// 后会把原图字节重新解进内存、再武装 30s TTL 并写「已查看」审计，
    /// 用户从未看到内容（BR-007「重锁 = 回到认证前内存态」对离开场景失效，
    /// onDisappear 重锁拦不住无句柄的在途任务）
    @State private var unlockTask: Task<Void, Never>?

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
        .onAppear {
            // 第七轮修复（BR-007 时序）：预传 imageData 的路径也把**解码**推迟到
            // 认证通过之后——原实现在 onAppear 即降采样渲染，认证取消时解码图
            // 仍驻留内存（文件头契约「认证通过后才落内存」对非 loader 路径失效）
            displayData = imageData
            if unlocked { loadDownsampled() }
        }
        // 评审修正（BR-007/008）：任务切换器快照防护——SensitiveMediaContainer
        // 已在 inactive 时重锁，本视图此前缺失同款处理，退后台后快照可能
        // 仍展示已解锁原图（AppRootView 遮罩提交与系统快照竞态）。
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, unlocked {
                relock()
            }
        }
        // 与 SensitiveMediaContainer 同纪律：离开即重锁并取消空闲计时——
        // 原视图弹出销毁后 relockTask 仍持有解码图至 30s TTL（BR-007
        // 「重锁 = 回到认证前内存态」对离开场景失效）
        .onDisappear { relock() }
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
            } else if loadFailed {
                ContentUnavailableView(L10n.sensitiveMedia_loadFailed,
                                       systemImage: "exclamationmark.triangle")
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
        .background(Color("bg-grouped", bundle: .main))   // 语义令牌（token-only 纪律）
        .onTapGesture {
            guard !unlocking else { return }   // 解锁在途守卫（连点只认证一次）
            unlocking = true
            // 占位视图仅在 !unlocked 时渲染，故此处无需再查 unlocked——
            // authenticateAndUnlock 内部有取消检查，relock() 会取消本任务。
            unlockTask = Task {
                _ = await authenticateAndUnlock()
                unlocking = false
            }
        }
    }

    private func authenticateAndUnlock() async -> Bool {
        // FR1.9：每次查看原图都是一次独立的系统设备所有者认证（Face ID/Touch ID
        // + 设备密码兜底），与 SensitiveMediaContainer 同路径，绝不允许无认证直通。
        guard await app.requestUnlock(reason: L10n.sensitive_unlockReason) else { return false }
        // 认证途中视图已离开（relock 取消了本任务）：不得继续——原图字节、
        // 30s TTL 与「已查看」审计都不能在用户从未看到内容的场景下复活。
        guard !Task.isCancelled else { return false }
        // BR-007 时序：认证通过后才拉取原图字节（loader 路径）——取消认证
        // 的用户从未让原图进内存。加载失败回落直接传入的 imageData（若有）；
        // 两者皆无 = 加载失败态（第七轮修复：明示失败，不再永远转圈）。
        loadFailed = false
        if let originalLoader {
            if let loaded = await originalLoader(), !loaded.isEmpty {
                // 读盘期间视图已离开：同样不得复活解码与审计
                guard !Task.isCancelled else { return false }
                displayData = loaded
                image = nil
                loadDownsampled()
            } else if displayData == nil {
                loadFailed = true
            }
        } else if displayData == nil {
            // 预传 imageData 路径：空闲重锁已把 displayData 镜像清空（BR-007
            // 清内存），重新解锁须从不可变的 imageData 源重建——否则
            // loadDownsampled 的 guard 落空，解锁后永久转圈无出口
            displayData = imageData
            if imageData == nil { loadFailed = true }
        }
        unlocked = true
        if !loadFailed, image == nil { loadDownsampled() }   // 预传 imageData 路径的解码（认证后）
        scheduleRelock()
        // FR14.2 审计：敏感原图查看留痕（评审修正——原视图零审计锚点）
        if let assetId { app.auditViewSensitiveOriginal(documentId: assetId, title: caption) }
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
        unlockTask?.cancel()   // 取消在途解锁（离开/重锁后认证结果不得复活解码与审计）
        unlockTask = nil
        unlocking = false      // 立即释放守卫：被取消任务的复位有调度延迟，置位可避免回场首击被吞
        unlocked = false
        // 第六轮全仓审查修复：重锁必须把已解码的降采样字节一并清出——
        // 原实现只翻转 unlocked，解码图仍驻留内存（下次解锁直接从内存
        // 渲染），「重锁 = 回到认证前内存态」的 BR-007 快照防护语义
        // 名存实亡
        image = nil
        displayData = nil
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
            // 失败态，与既有失败出口（ContentUnavailableView）同路径。
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
