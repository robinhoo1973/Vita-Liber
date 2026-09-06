import SwiftUI
import UIKit
import Domain
import Infrastructure
import Protocols

/// FR5.2 四角选区 + 透视矫正：拍摄/选取图片后，先手动圈定 OCR 有效区域
/// （自动检测预置初始位置，用户可拖拽四角微调对齐纸张边缘），确认后把选区
/// 矫正为正视矩形图。矫正结果与原图都需要落盘（BR-002），由调用方在导入
/// 确认阶段一并持久化（`DocumentsState.persistOriginal`）。
struct ScanRegionEditorView: View {
    let image: UIImage
    /// 完成回调：(原图, 矫正后的正视图)
    let onConfirm: (UIImage, UIImage) -> Void
    let onSkip: () -> Void

    @State private var corners: QuadCorners = .fullImageInset
    @State private var errorMessage: String?
    @State private var correcting = false
    @Environment(\.dismiss) private var dismiss

    private let preprocessor: any ImagePreprocessing = EngineRegistry.shared.resolve(ImagePreprocessingFactory.self)
    private let space = "scanRegionSpace"

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = imageFrame(in: geo.size)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                    QuadOverlay(corners: $corners, frame: frame, space: space)
                }
                .coordinateSpace(name: space)
            }
            .overlay(alignment: .top) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                        .accessibilityIdentifier("SP-11.scanRegion.error")
                }
            }
            .navigationTitle(L10n.scanRegionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { onSkip(); dismiss() }
                        .accessibilityIdentifier("SP-11.scanRegion.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.scanRegionConfirm) { confirm() }
                        .disabled(correcting)
                        .accessibilityIdentifier("SP-11.scanRegion.confirm")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Text(L10n.scanRegionHint).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.scanRegionReset) { corners = .fullImageInset }
                        .accessibilityIdentifier("SP-11.scanRegion.reset")
                }
            }
            .task { await autoDetect() }
        }
    }

    private func autoDetect() async {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        if let quad = await preprocessor.detectQuad(data) {
            corners = quad
        } else {
            errorMessage = L10n.scanRegionAutoDetectFailed
        }
    }

    private func confirm() {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        correcting = true
        errorMessage = nil
        Task {
            do {
                let correctedData = try await preprocessor.correctPerspective(data, corners: corners)
                guard let corrected = UIImage(data: correctedData) else {
                    errorMessage = L10n.scanRegionCorrectionFailed
                    correcting = false
                    return
                }
                onConfirm(image, corrected)
                dismiss()
            } catch {
                errorMessage = L10n.scanRegionCorrectionFailed
                correcting = false
            }
        }
    }

    /// 图片在 `.scaledToFit()` 容器内实际渲染的矩形（居中留白 letterbox 之后的区域）。
    private func imageFrame(in containerSize: CGSize) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let renderedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - renderedSize.width) / 2,
                             y: (containerSize.height - renderedSize.height) / 2)
        return CGRect(origin: origin, size: renderedSize)
    }
}

/// 四角拖拽叠层：把归一化 `QuadCorners`（0...1，左上原点）映射到实际渲染帧
/// （aspectFit 留白之后的图像区域），四个可拖拽圆形手柄 + 连线四边形。
/// 拖拽用命名坐标空间取绝对位置（非 `.local`）——`.local` 会相对手柄自身
/// 28pt 的小帧回报坐标，与 `frame`（相对父级）的坐标系不一致，导致跟手错位。
private struct QuadOverlay: View {
    @Binding var corners: QuadCorners
    let frame: CGRect
    let space: String

    var body: some View {
        ZStack {
            Path { path in
                let pts = [point(corners.topLeft), point(corners.topRight),
                          point(corners.bottomRight), point(corners.bottomLeft)]
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            .fill(Color("brand-primary", bundle: .main).opacity(0.15))
            Path { path in
                let pts = [point(corners.topLeft), point(corners.topRight),
                          point(corners.bottomRight), point(corners.bottomLeft)]
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            .stroke(Color("brand-primary", bundle: .main), lineWidth: 2)

            handle(\.topLeft, id: "topLeft")
            handle(\.topRight, id: "topRight")
            handle(\.bottomLeft, id: "bottomLeft")
            handle(\.bottomRight, id: "bottomRight")
        }
    }

    private func point(_ p: Domain.NormalizedPoint) -> CGPoint {
        CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height)
    }

    @ViewBuilder
    private func handle(_ keyPath: WritableKeyPath<QuadCorners, Domain.NormalizedPoint>, id: String) -> some View {
        let p = point(corners[keyPath: keyPath])
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color("brand-primary", bundle: .main), lineWidth: 3))
            .frame(width: 28, height: 28)
            .position(p)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        let clampedX = min(max(value.location.x, frame.minX), frame.maxX)
                        let clampedY = min(max(value.location.y, frame.minY), frame.maxY)
                        guard frame.width > 0, frame.height > 0 else { return }
                        // 显式 Domain 限定：iOS 18+ Vision 亦有 NormalizedPoint（原点在左下、
                        // y 向上），与 Domain（原点左上、y 向下）语义镜像——免限定会在
                        // 本文件引入 Vision 时静默绑定错类型（16ccc60 已实证撞名）
                        corners[keyPath: keyPath] = Domain.NormalizedPoint(x: (clampedX - frame.minX) / frame.width,
                                                                           y: (clampedY - frame.minY) / frame.height)
                    }
            )
            .accessibilityIdentifier("SP-11.scanRegion.handle.\(id)")
    }
}
