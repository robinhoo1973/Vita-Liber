import SwiftUI
import UIKit
import PencilKit

/// FR5.4 入库前遮挡工具（V3.72 点亮）：涂鸦方式遮住身份证号、地址等
/// 无关区域后再入库——遮挡**不可逆**（保存遮挡后的展示版本，原始帧
/// 另行受保护保存，BR-002）。PencilKit 为平台成熟实现（ADR-025）。
///
/// 交互：原图铺底 + PKCanvasView 透明叠层（工具=黑色马克笔/橡皮），
/// [跳过] 不遮挡直接继续；[遮挡完成] 合成像素涂写后的展示版本。
struct OcclusionEditorView: View {
    let originalImage: UIImage
    /// 完成回调：返回遮挡后的展示版本（跳过时 = 原图）
    let onComplete: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OcclusionCanvas(image: originalImage)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(L10n.occlusionTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.occlusionSkip) {
                            onComplete(originalImage)
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.occlusionDone) {
                            // 合成失败（极端布局窗口/空帧）回落原图——绝不因
                            // 合成失败卡死完成按钮；涂写为空时合成=原图。
                            onComplete(OcclusionCanvas.render(image: originalImage,
                                                              drawing: OcclusionCanvas.sharedDrawing)
                                       ?? originalImage)
                            dismiss()
                        }
                        .accessibilityIdentifier("SP-11.occlusion.done")
                    }
                }
                // 第七轮全仓审查修复（BR-007 内存卫生）：会话结束即清共享涂写——
                // 敏感文档的遮挡笔迹不得在进程内滞留到下一份文档（与 makeUIView
                // 的创建时重置互为双保险：本行在 dismiss 后清，画布创建再兜底）
                .onDisappear { OcclusionCanvas.sharedDrawing = PKDrawing() }
        }
    }
}

/// PencilKit 叠层（UIViewRepresentable）：UIImageView 原图铺底 + 透明画布
/// 叠于其上，工具黑色马克笔。容器为同一 UIView，画布坐标 = 屏点坐标，
/// 与用户所见的原图显示位置 1:1 对应。
struct OcclusionCanvas: UIViewRepresentable {
    let image: UIImage
    /// 共享画布状态（渲染时取用；单编辑器实例无并发）。
    /// 第六轮全仓审查修复：原实现只把 sharedDrawing 拷贝进画布、从不回写——
    /// 用户涂写只存在于 PKCanvasView 内部，「遮挡完成」合成的是空画布，
    /// 证件号/地址等敏感区域原样保存（FR5.4 名存实亡 + BR-007 暴露面）。
    /// nonisolated(unsafe) 理由（L10n 静态表同款先例）：PKCanvasView 委托
    /// 回调与合成读取均只发生在主线程，无跨线程竞争面。
    nonisolated(unsafe) static var sharedDrawing = PKDrawing()
    /// 原图在当前屏幕上的显示矩形（屏点坐标，aspect-fit 计算）——合成时
    /// 把涂写从屏点坐标映射回图像坐标的唯一依据。layoutSubviews 时更新。
    nonisolated(unsafe) static var sharedImageFrame: CGRect = .zero

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CanvasContainerView {
        // 第七轮全仓审查修复：每次新画布创建即重置共享涂写——上一份文档的
        // 遮挡笔迹若不清除，会被预载进新文档画布并在「遮挡完成」时永久合成
        // 进新文档（BR-002 展示版污染 + BR-007 未遮挡区域暴露）。
        Self.sharedDrawing = PKDrawing()
        Self.sharedImageFrame = .zero
        let container = CanvasContainerView()
        container.imageView.image = image
        container.imageView.contentMode = .scaleAspectFit
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.marker, color: .black, width: 24)
        canvas.drawing = Self.sharedDrawing
        canvas.delegate = context.coordinator
        container.canvas = canvas
        container.imageView.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(container.imageView)
        container.addSubview(canvas)
        NSLayoutConstraint.activate([
            container.imageView.topAnchor.constraint(equalTo: container.topAnchor),
            container.imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            container.imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateUIView(_ container: CanvasContainerView, context: Context) {}

    /// 画布变更回调：把最新涂写回写共享状态（合成读取的唯一事实源）
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            OcclusionCanvas.sharedDrawing = canvasView.drawing
        }
    }

    /// 合成：原图 + 涂写（像素级合成，不可逆遮挡语义）。
    ///
    /// 审查修复（P0 坐标错配 + 盲涂）：原实现画布无原图铺底（用户对着
    /// 空白屏盲涂），且 `drawing.image(from: size)` 把画布屏点坐标
    /// （~393×852pt）原样叠到图像坐标（数千点）上——涂写只会落在最终图
    /// 左上角缩小区域，与被涂位置完全不对应，敏感区大概率漏遮即入库。
    /// 现按 sharedImageFrame（原图显示矩形，屏点）截取涂写并等比例
    /// 映射到图像坐标——aspect-fit 等比缩放，涂写位置与所见一致。
    static func render(image: UIImage, drawing: PKDrawing) -> UIImage? {
        let size = image.size
        let frame = sharedImageFrame
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            // 仅截取显示矩形内的涂写（屏点 1pt/px），再画满整图——等比缩放
            let strokeImage = drawing.image(from: frame, scale: 1)
            strokeImage.draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: 1)
        }
    }
}

/// 画布容器：原图 + 涂写画布同坐标系；layoutSubviews 时把原图的
/// aspect-fit 显示矩形写回共享状态供合成映射。
final class CanvasContainerView: UIView {
    let imageView = UIImageView()
    var canvas: PKCanvasView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let img = imageView.image,
              img.size.width > 0, img.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / img.size.width, bounds.height / img.size.height)
        let dw = img.size.width * scale
        let dh = img.size.height * scale
        OcclusionCanvas.sharedImageFrame = CGRect(
            x: (bounds.width - dw) / 2, y: (bounds.height - dh) / 2,
            width: dw, height: dh)
    }
}
