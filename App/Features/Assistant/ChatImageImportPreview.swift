import SwiftUI
import UIKit

/// 导入前图片检查（2026-10-30 业主：拍照/选图后先放大检查、可旋转方向再识别）。
///
/// 背景：相机/相册原图常带 EXIF 方向或拍反，直接 OCR 会把侧躺/倒置文字
/// 识别成噪声。本页在进入识别链**之前**提供确定性预处理阶段：
/// - 逐张查看（多张合并导入时保持选择顺序）；
/// - 双指放大（1–4 倍）检查清晰度/完整度；
/// - 每张可 90° 顺时针旋转，确认后按旋转结果重绘为方向 `.up` 的图像。
///
/// 只处理图片；PDF 不在此页（PDF 页方向由原件决定，不走 OCR 预处理）。
/// 确认后回调的是**已归一化方向**的 UIImage 数组，调用方直接编码/合并。
struct ChatImageImportPreview: View {
    let onConfirm: ([UIImage]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var images: [UIImage]
    @State private var pageIndex = 0
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    /// 放大后平移检查边缘（1x 时归零）。
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    init(images: [UIImage], onConfirm: @escaping ([UIImage]) -> Void) {
        self.onConfirm = onConfirm
        _images = State(initialValue: images)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                imageStage
                if images.count > 1 {
                    pageIndicator
                }
                hintRow
                confirmBar
            }
            .background(Color.black)
            .navigationTitle(L10n.chatImagePreviewTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        rotateCurrent()
                    } label: {
                        Image(systemName: "rotate.right")
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(L10n.chatImagePreviewRotate)
                    .accessibilityIdentifier("chat.imagePreview.rotate")
                }
            }
            .privacySensitive(scenePhase != .active)
        }
    }

    // MARK: - 画布

    private var imageStage: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(4, max(1, baseScale * value))
                                }
                                .onEnded { _ in
                                    baseScale = scale
                                    offset = clamped(offset, in: geometry.size, scale: scale)
                                    baseOffset = offset
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    guard scale > 1.01 else { return }
                                    let proposed = CGSize(
                                        width: baseOffset.width + value.translation.width,
                                        height: baseOffset.height + value.translation.height)
                                    offset = clamped(proposed, in: geometry.size, scale: scale)
                                }
                                .onEnded { _ in
                                    baseOffset = offset
                                }
                        )
                        .animation(.easeOut(duration: 0.2), value: scale)
                        .accessibilityLabel(L10n.chatImagePreviewImage)
                        .accessibilityIdentifier("chat.imagePreview.image")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // 双击在原始比例与 2 倍之间切换（快速核对细节）。
                scale = scale > 1.01 ? 1 : 2
                baseScale = scale
                offset = .zero
                baseOffset = .zero
            }
        }
    }

    /// 平移上限按视口尺寸与倍数估算；宁可留少量黑边也不让画面被拖出视口。
    private func clamped(_ proposed: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.01 else { return .zero }
        let maxX = max(0, size.width * (scale - 1) / 2)
        let maxY = max(0, size.height * (scale - 1) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private var pageIndicator: some View {
        VStack(spacing: 8) {
            Text(String(format: L10n.chatImagePreviewPageFmt, pageIndex + 1, images.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 10) {
                Button {
                    show(pageIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .disabled(pageIndex == 0)
                .accessibilityLabel(L10n.chatImagePreviewPrevious)

                HStack(spacing: 6) {
                    ForEach(images.indices, id: \.self) { index in
                        Circle()
                            .fill(index == pageIndex
                                ? Color.white : Color.white.opacity(0.35))
                            .frame(width: 7, height: 7)
                            .frame(height: 44)
                            .accessibilityHidden(true)
                    }
                }
                // 2026-10-30 触控面积修复：整条 44pt 高命中 + 位置映射，
                // 原 7pt 圆点各自 onTapGesture，手指几乎点不中。
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    let slot = Int(value.location.x / 13)   // 7pt 点 + 6pt 间距
                    show(slot)
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: L10n.chatImagePreviewPageFmt,
                                           pageIndex + 1, images.count))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: show(pageIndex + 1)
                    case .decrement: show(pageIndex - 1)
                    default: break
                    }
                }

                Button {
                    show(pageIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .disabled(pageIndex >= images.count - 1)
                .accessibilityLabel(L10n.chatImagePreviewNext)
            }
            .foregroundStyle(.white)
        }
        .padding(.vertical, 8)
    }

    private var hintRow: some View {
        Text(L10n.chatImagePreviewHint)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
    }

    private var confirmBar: some View {
        Button {
            onConfirm(images)
            dismiss()
        } label: {
            Text(L10n.chatImagePreviewConfirm)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color("brand-primary", bundle: .main))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .accessibilityIdentifier("chat.imagePreview.confirm")
    }

    // MARK: - 动作

    private var currentImage: UIImage? {
        guard images.indices.contains(pageIndex) else { return nil }
        return images[pageIndex]
    }

    private func show(_ index: Int) {
        guard images.indices.contains(index) else { return }
        pageIndex = index
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    /// 90° 顺时针；离屏重绘，结果方向恒为 `.up`（EXIF 方向已合入像素）。
    private func rotateCurrent() {
        guard images.indices.contains(pageIndex) else { return }
        images[pageIndex] = Self.rotatedClockwise(images[pageIndex])
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    static func rotatedClockwise(_ image: UIImage) -> UIImage {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let targetSize = CGSize(width: sourceSize.height, height: sourceSize.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
            cg.rotate(by: .pi / 2)
            image.draw(in: CGRect(x: -sourceSize.width / 2, y: -sourceSize.height / 2,
                                  width: sourceSize.width, height: sourceSize.height))
        }
    }
}
