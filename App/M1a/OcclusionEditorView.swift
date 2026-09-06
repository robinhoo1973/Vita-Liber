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
                            OcclusionCanvas.render(image: originalImage,
                                                   drawing: OcclusionCanvas.sharedDrawing)
                            .map(onComplete)
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

/// PencilKit 叠层（UIViewRepresentable）：透明画布叠在原图上，工具黑色马克笔。
struct OcclusionCanvas: UIViewRepresentable {
    let image: UIImage
    /// 共享画布状态（渲染时取用；单编辑器实例无并发）。
    /// 第六轮全仓审查修复：原实现只把 sharedDrawing 拷贝进画布、从不回写——
    /// 用户涂写只存在于 PKCanvasView 内部，「遮挡完成」合成的是空画布，
    /// 证件号/地址等敏感区域原样保存（FR5.4 名存实亡 + BR-007 暴露面）。
    /// nonisolated(unsafe) 理由（L10n 静态表同款先例）：PKCanvasView 委托
    /// 回调与合成读取均只发生在主线程，无跨线程竞争面。
    nonisolated(unsafe) static var sharedDrawing = PKDrawing()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        // 第七轮全仓审查修复：每次新画布创建即重置共享涂写——上一份文档的
        // 遮挡笔迹若不清除，会被预载进新文档画布并在「遮挡完成」时永久合成
        // 进新文档（BR-002 展示版污染 + BR-007 未遮挡区域暴露）。
        Self.sharedDrawing = PKDrawing()
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.marker, color: .black, width: 24)
        canvas.drawing = Self.sharedDrawing
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    /// 画布变更回调：把最新涂写回写共享状态（合成读取的唯一事实源）
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            OcclusionCanvas.sharedDrawing = canvasView.drawing
        }
    }

    /// 合成：原图 + 涂写（像素级合成，不可逆遮挡语义）
    static func render(image: UIImage, drawing: PKDrawing) -> UIImage? {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            let strokeImage = drawing.image(from: CGRect(origin: .zero, size: size), scale: image.scale)
            strokeImage.draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: 1)
        }
    }
}
