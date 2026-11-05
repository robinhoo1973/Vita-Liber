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
        /// 每块消费的 Paddle 行原始框（逐行，不合并）；诊断按单行框查裁剪/rec 指标。
        public var blockPaddleRects: [[LayoutRect]]
        public var blockVisionText: [String]
        /// Vision 副轨的页级置信（0..1）；无 Vision 版面 = nil。
        public var visionPageConfidence: Double?

        public init(lines: [String], layout: PageLayout, replaced: Int, keptVision: Int,
                    appended: Int, consumed: Int, blockPaddleText: [String?],
                    blockPaddleConfidence: [Double?],
                    blockPaddleRects: [[LayoutRect]], blockVisionText: [String],
                    visionPageConfidence: Double? = nil) {
            self.lines = lines; self.layout = layout; self.replaced = replaced
            self.keptVision = keptVision; self.appended = appended; self.consumed = consumed
            self.blockPaddleText = blockPaddleText
            self.blockPaddleConfidence = blockPaddleConfidence
            self.blockPaddleRects = blockPaddleRects
            self.blockVisionText = blockVisionText
            self.visionPageConfidence = visionPageConfidence
        }

        /// 页级置信：**沿用 Vision 口径**（有 Vision 版面时）。
        ///
        /// 0.6 卡级确认门槛（`CardConfirmationRules.confirmAllConfidenceFloor`）是按
        /// Vision 置信标定的；Paddle CTC 与 Vision 的置信不可比（同为模型自评，量纲/校准
        /// 不同）。若把两种量纲平均进页级置信，交付文字换主轨会静默平移安全门槛
        /// （Paddle 偏高 → 更多字段一键升 C；偏低 → 全部逐项复核）。逐块置信仍记录
        /// 产出该块文字引擎的原生值，供调试对照；纯 Paddle 页（无 Vision 版面）才用
        /// Paddle 均值。
        public var confidence: Double {
            if let visionPageConfidence { return visionPageConfidence }
            guard !layout.blocks.isEmpty else { return 0 }
            return layout.blocks.map(\.confidence).reduce(0, +) / Double(layout.blocks.count)
        }
    }

    /// 逐 Paddle 行取 Vision 副轨文本，供第三源 token 共识使用。
    ///
    /// 只有「该 Vision 块恰好只归属这一条 Paddle 行」且块文本不含换行时才返回文本；
    /// 一块多行（Vision 合体观察）返回 nil——把整块文本当单行副源会产生跨行噪声，
    /// 宁可放弃该行的 Vision 票，只保留 CnOCR 一票（不足两票即不改写）。
    /// 归属顺序与 `merge` 完全一致：Vision 块按顺序认领尚未归属的行。
    public static func visionTextByLine(paddleLines: [Line], visionLayout: PageLayout?,
                                        centerTolerance: Double = 0.004) -> [String?] {
        var result = [String?](repeating: nil, count: paddleLines.count)
        guard let visionLayout, !visionLayout.blocks.isEmpty else { return result }
        let usable = paddleLines.indices.filter {
            !paddleLines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var claimed = Set<Int>()
        for block in visionLayout.blocks {
            let inside = usable.filter { index in
                guard !claimed.contains(index) else { return false }
                let rect = paddleLines[index].bbox
                let cx = rect.midX, cy = rect.midY
                return block.bbox.x - centerTolerance <= cx
                    && cx <= block.bbox.maxX + centerTolerance
                    && block.bbox.y - centerTolerance <= cy
                    && cy <= block.bbox.maxY + centerTolerance
            }
            guard !inside.isEmpty else { continue }
            inside.forEach { claimed.insert($0) }
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard inside.count == 1, !text.isEmpty, !text.contains("\n") else { continue }
            result[inside[0]] = text
        }
        return result
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
                          blockPaddleRects: ordered.map { [$0.bbox] },
                          blockVisionText: blocks.map { _ in "" },
                          visionPageConfidence: nil)
        }
        let visionPageConfidence = visionConfidences.isEmpty ? nil
            : visionConfidences.reduce(0, +) / Double(visionConfidences.count)

        // 已经归属某个 Vision 块的 Paddle 行下标。
        var claimed = Set<Int>()
        var blocks: [TextBlock] = []
        var replaced = 0
        var keptVision = 0
        var blockPaddleText: [String?] = []
        var blockPaddleConfidence: [Double?] = []
        var blockPaddleRects: [[LayoutRect]] = []
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
            var orderedInside: [Int] = []
            if inside.isEmpty {
                // 块内没有 Paddle 行：Vision 原文兜底（副轨不是失败态）。
                let index = block.lineIndex
                text = index >= 0 && index < visionLines.count ? visionLines[index] : block.text
                confidence = index >= 0 && index < visionConfidences.count
                    ? visionConfidences[index] : block.confidence
                keptVision += 1
            } else {
                inside.forEach { claimed.insert($0) }
                orderedInside = DBTextPostprocess.readingOrder(inside) { box(for: usable[$0]) }
                let texts = orderedInside.map { usable[$0].text }
                // 全仓唯一 CJK 边界规则：中日韩字符之间不插空格，拉丁词之间补一个空格。
                text = TranscriptJoiner.join(texts)
                let sum = orderedInside.reduce(0.0) { $0 + usable[$1].confidence }
                confidence = sum / Double(orderedInside.count)
                replaced += 1
            }
            let visionText = block.lineIndex >= 0 && block.lineIndex < visionLines.count
                ? visionLines[block.lineIndex] : block.text
            if inside.isEmpty {
                blockPaddleText.append(nil)
                blockPaddleConfidence.append(nil)
                blockPaddleRects.append([])
            } else {
                blockPaddleText.append(text)
                blockPaddleConfidence.append(confidence)
                blockPaddleRects.append(orderedInside.map { usable[$0].bbox })
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
            blockPaddleRects.append([line.bbox])
            blockVisionText.append("")
            blocks.append(TextBlock(text: line.text, bbox: line.bbox,
                                    lineIndex: blocks.count, confidence: line.confidence))
        }

        // 版式结构保留 Vision 的几何，但**格内/段落文字必须跟随块文字**（Paddle 主轨）：
        // `RuleExtractor` 直接从 `TableCell.text` 抽字段，若只替换块文字而格文字仍是
        // Vision 原文，表格类单据（化验单等）会继续交付副轨文本，与「文字以 Paddle 为准」
        // 的契约分叉。`lineIndices` 索引的是合并前 Vision 块号，而 `blocks` 前 N 项与
        // Vision 块一一对应（追加项不影响既有索引），可直接按号取新文字。
        let tables = visionLayout.tables.map { table in
            TableRegion(id: table.id, bbox: table.bbox,
                        rows: table.rows.map { remapText($0, blocks: blocks) },
                        header: table.header.map { remapText($0, blocks: blocks) })
        }
        let paragraphs = visionLayout.paragraphs.map { paragraph in
            var paragraph = paragraph
            let texts = paragraph.lineIndices.compactMap { text(at: $0, blocks: blocks) }
            if !texts.isEmpty { paragraph.text = TranscriptJoiner.join(texts) }
            return paragraph
        }
        let layout = PageLayout(blocks: blocks, tables: tables, paragraphs: paragraphs)
        return Result(lines: blocks.map(\.text), layout: layout, replaced: replaced,
                      keptVision: keptVision, appended: orderedLeftovers.count,
                      consumed: claimed.count + orderedLeftovers.count,
                      blockPaddleText: blockPaddleText,
                      blockPaddleConfidence: blockPaddleConfidence,
                      blockPaddleRects: blockPaddleRects,
                      blockVisionText: blockVisionText,
                      visionPageConfidence: visionPageConfidence)
    }

    /// 格文字跟随合并后的块文字；`lineIndices` 为空（Vision 未映射到行）时保留原文。
    private static func remapText(_ row: TableRow, blocks: [TextBlock]) -> TableRow {
        TableRow(cells: row.cells.map { cell in
            var cell = cell
            let texts = cell.lineIndices.compactMap { text(at: $0, blocks: blocks) }
            if !texts.isEmpty { cell.text = TranscriptJoiner.join(texts) }
            return cell
        })
    }

    private static func text(at index: Int, blocks: [TextBlock]) -> String? {
        blocks.indices.contains(index) ? blocks[index].text : nil
    }

    private static func box(for line: Line) -> DBTextPostprocess.Box {
        DBTextPostprocess.Box(x: line.bbox.x, y: line.bbox.y,
                              width: line.bbox.width, height: line.bbox.height,
                              score: line.confidence)
    }
}
