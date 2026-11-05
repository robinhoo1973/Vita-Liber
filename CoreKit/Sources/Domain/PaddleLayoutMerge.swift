import Foundation

/// Paddle 主轨文字 + Vision 副轨版式的合并（2026-11-04 Paddle 主轨批）。
///
/// 契约：
/// - **文字以 Paddle 为准**：Vision 块内命中 Paddle 行时，块文本替换为 Paddle 行；
/// - **版式以 Vision 为准**：块顺序、表格、段落结构原样保留（Vision 是副轨，
///   但它是唯一的段落/表格来源）；
/// - **不丢字**：块内没有 Paddle 行（或 Paddle 文本为空）时保留 Vision 原文；
/// - Vision 漏掉而 Paddle 检出的文本按阅读序追加为新块，不覆盖既有结构；
/// - 输出满足 `blocks[i].lineIndex == i`、`lines[i] == blocks[i].text`，
///   与 `PageLayout` 既有不变量一致。
///
/// 纯 Foundation，Linux 可测；不涉及任何图像 API。
public enum PaddleLayoutMerge {

    /// 一条已识别的 Paddle 行（归一化坐标、左上原点）。
    public struct Line: Sendable, Equatable {
        public var text: String
        public var bbox: LayoutRect
        public var confidence: Double
        public init(text: String, bbox: LayoutRect, confidence: Double) {
            self.text = text; self.bbox = bbox; self.confidence = confidence
        }
    }

    public struct Result: Sendable, Equatable {
        public var lines: [String]
        public var layout: PageLayout
        /// 文本被 Paddle 替换的 Vision 块数。
        public var replaced: Int
        /// 保留 Vision 原文的块数（未命中或 Paddle 空文本）。
        public var keptVision: Int
        /// Vision 未覆盖、由 Paddle 追加的块数。
        public var appended: Int
        /// 已消费的 Paddle 行数。
        public var consumed: Int
        /// 逐块来源（诊断用）：与 `layout.blocks` 等长；nil = 该块保留 Vision 原文。
        public var blockPaddleText: [String?]
        public var blockPaddleConfidence: [Double?]
        public var blockPaddleBBox: [LayoutRect?]
        public var blockVisionText: [String]

        public init(lines: [String], layout: PageLayout, replaced: Int, keptVision: Int,
                    appended: Int, consumed: Int, blockPaddleText: [String?],
                    blockPaddleConfidence: [Double?], blockPaddleBBox: [LayoutRect?],
                    blockVisionText: [String]) {
            self.lines = lines; self.layout = layout; self.replaced = replaced
            self.keptVision = keptVision; self.appended = appended; self.consumed = consumed
            self.blockPaddleText = blockPaddleText
            self.blockPaddleConfidence = blockPaddleConfidence
            self.blockPaddleBBox = blockPaddleBBox
            self.blockVisionText = blockVisionText
        }

        public var confidence: Double {
            guard !layout.blocks.isEmpty else { return 0 }
            return layout.blocks.map(\.confidence).reduce(0, +) / Double(layout.blocks.count)
        }
    }

    /// 合并。`visionLayout == nil` 时直接用 Paddle 行构建版面。
    ///
    /// - Parameter centerTolerance: 判定「Paddle 行属于该块」的中心点容差（归一化）。
    ///   0 表示严格落在块矩形内；小容差吸收检测框比 Vision 行框略大的常态。
    public static func merge(paddleLines: [Line], visionLines: [String],
                             visionLayout: PageLayout?, visionConfidences: [Double],
                             centerTolerance: Double = 0.004) -> Result {
        let usable = paddleLines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let visionLayout, !visionLayout.blocks.isEmpty else {
            let ordered = DBTextPostprocess.readingOrder(usable) { box(for: $0) }
            var blocks: [TextBlock] = []
            for line in ordered {
                blocks.append(TextBlock(text: line.text, bbox: line.bbox,
                                        lineIndex: blocks.count, confidence: line.confidence))
            }
            return Result(lines: blocks.map(\.text), layout: PageLayout(blocks: blocks),
                          replaced: 0, keptVision: 0, appended: blocks.count,
                          consumed: blocks.count,
                          blockPaddleText: blocks.map(\.text),
                          blockPaddleConfidence: blocks.map(\.confidence),
                          blockPaddleBBox: blocks.map(\.bbox),
                          blockVisionText: blocks.map { _ in "" })
        }

        // 已经归属某个 Vision 块的 Paddle 行下标。
        var claimed = Set<Int>()
        var blocks: [TextBlock] = []
        var replaced = 0
        var keptVision = 0
        var blockPaddleText: [String?] = []
        var blockPaddleConfidence: [Double?] = []
        var blockPaddleBBox: [LayoutRect?] = []
        var blockVisionText: [String] = []

        for block in visionLayout.blocks {
            let inside = usable.indices.filter { index in
                guard !claimed.contains(index) else { return false }
                let rect = usable[index].bbox
                let cx = rect.midX, cy = rect.midY
                return block.bbox.x - centerTolerance <= cx
                    && cx <= block.bbox.maxX + centerTolerance
                    && block.bbox.y - centerTolerance <= cy
                    && cy <= block.bbox.maxY + centerTolerance
            }
            let text: String
            let confidence: Double
            if inside.isEmpty {
                // 块内没有 Paddle 行：Vision 原文兜底（副轨不是失败态）。
                let index = block.lineIndex
                text = index >= 0 && index < visionLines.count ? visionLines[index] : block.text
                confidence = index >= 0 && index < visionConfidences.count
                    ? visionConfidences[index] : block.confidence
                keptVision += 1
            } else {
                inside.forEach { claimed.insert($0) }
                let ordered = DBTextPostprocess.readingOrder(inside) { box(for: usable[$0]) }
                let texts = ordered.map { usable[$0].text }
                text = texts.joined(separator: " ")
                let sum = ordered.reduce(0.0) { $0 + usable[$1].confidence }
                confidence = sum / Double(ordered.count)
                replaced += 1
            }
            let visionText = block.lineIndex >= 0 && block.lineIndex < visionLines.count
                ? visionLines[block.lineIndex] : block.text
            if inside.isEmpty {
                blockPaddleText.append(nil)
                blockPaddleConfidence.append(nil)
                blockPaddleBBox.append(nil)
            } else {
                let ordered = DBTextPostprocess.readingOrder(inside) { box(for: usable[$0]) }
                blockPaddleText.append(ordered.map { usable[$0].text }.joined(separator: " "))
                blockPaddleConfidence.append(confidence)
                blockPaddleBBox.append(LayoutRect.union(of: ordered.map { usable[$0].bbox }))
            }
            blockVisionText.append(visionText)
            blocks.append(TextBlock(text: text, bbox: block.bbox, lineIndex: blocks.count,
                                    confidence: confidence))
        }

        // Vision 漏检：未归属任何块的 Paddle 行按阅读序追加。
        let leftovers = usable.indices.filter { !claimed.contains($0) }
        let orderedLeftovers = DBTextPostprocess.readingOrder(leftovers) { box(for: usable[$0]) }
        for index in orderedLeftovers {
            let line = usable[index]
            blockPaddleText.append(line.text)
            blockPaddleConfidence.append(line.confidence)
            blockPaddleBBox.append(line.bbox)
            blockVisionText.append("")
            blocks.append(TextBlock(text: line.text, bbox: line.bbox,
                                    lineIndex: blocks.count, confidence: line.confidence))
        }

        let layout = PageLayout(blocks: blocks, tables: visionLayout.tables,
                                paragraphs: visionLayout.paragraphs)
        return Result(lines: blocks.map(\.text), layout: layout, replaced: replaced,
                      keptVision: keptVision, appended: orderedLeftovers.count,
                      consumed: claimed.count + orderedLeftovers.count,
                      blockPaddleText: blockPaddleText,
                      blockPaddleConfidence: blockPaddleConfidence,
                      blockPaddleBBox: blockPaddleBBox,
                      blockVisionText: blockVisionText)
    }

    private static func box(for line: Line) -> DBTextPostprocess.Box {
        DBTextPostprocess.Box(x: line.bbox.x, y: line.bbox.y,
                              width: line.bbox.width, height: line.bbox.height,
                              score: line.confidence)
    }
}
