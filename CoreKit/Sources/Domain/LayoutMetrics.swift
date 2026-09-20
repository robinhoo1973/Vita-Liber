import Foundation

/// 单页版面度量（round4 P-1/P-4：几何度量此前无宿主——中位行高三处独立计算、「同列 1.5×行高」两处硬编码、
/// `LayoutRowBuilder.rows` 同管线双算）。一次计算、多处只读；阈值以版面自身度量（中位行高）为单位——
/// 与 Tesseract `paragraphs.cpp`（对齐 epsilon 以字距计）/ PaddleOCR `sorted_layout_boxes`（以页宽分数计）同构。
/// 纯值类型、确定性、与输入顺序无关。消费方：`TextLineMerger.merge(blocks:)`、`ParagraphBuilder`、Stage B `OCRConsensus`。
public struct LayoutMetrics: Sendable, Equatable {
    /// 中位行高下限（防退化：全零高块 → 阈值全为 0 → 任何两块都「不同列」）。
    public static let minimumMedianHeight = 0.005
    /// 同列：左缘差 ≤ 此倍数 × 中位行高。
    public static let sameColumnTolerance = 1.5
    /// 纵向相邻上限：下行 y − 上行 maxY ≤ 此倍数 × 中位行高（归并口径；段落聚合用 1.0，见 `paragraphGapTolerance`）。
    public static let adjacentGapTolerance = 0.8
    /// 纵向相邻允许的轻微重叠（Vision 相邻框常有 −0.25×行高级别重叠）。
    public static let adjacentOverlapTolerance = 0.25
    /// 段落聚合行距上限（比归并稍宽：段内行距 ≈ 1 行高）。
    public static let paragraphGapTolerance = 1.0
    /// 「上行写满」判据：`maxX ≥ max(rightEdge − 此倍数×行高, absoluteFillFloor)`。
    public static let fillSlackHeights = 2.0
    /// 「上行写满」绝对下限（半页宽；round3 开发委员窄列收据反例——rightEdge 退化时恒真）。
    public static let absoluteFillFloor = 0.5
    /// 「下行不更长」松弛：`next.width ≤ previous.width + 此倍数×行高`。
    public static let notLongerSlackHeights = 0.5

    public let medianHeight: Double
    /// 全页块右缘的 90 分位（小 n 防退化：n=2 取较大者）。空块 → 0。
    public let rightEdge: Double
    /// 几何聚行（一次计算，供多列判定与段落聚合共用）。
    public let rows: [LayoutRow]
    /// 落在多列视觉行（cells ≥ 2）的行号集——表格样行既不归并也不入段。
    public let multiColumnLineIndices: Set<Int>

    public init(blocks: [TextBlock]) {
        let heights = blocks.map(\.bbox.height).sorted()
        medianHeight = heights.isEmpty ? Self.minimumMedianHeight : max(heights[heights.count / 2], Self.minimumMedianHeight)
        let rights = blocks.map(\.bbox.maxX).sorted()
        if rights.isEmpty {
            rightEdge = 0
        } else {
            let tenth = max(1, Int(Double(rights.count) * 0.1))
            rightEdge = rights[rights.count - tenth]
        }
        rows = LayoutRowBuilder.rows(from: blocks)
        multiColumnLineIndices = Set(rows.filter { $0.cells.count >= 2 }.flatMap(\.lineIndices))
    }

    /// 同列：左缘差 ≤ 1.5×中位行高。
    public func isSameColumn(_ a: LayoutRect, _ b: LayoutRect) -> Bool {
        abs(b.x - a.x) <= Self.sameColumnTolerance * medianHeight
    }

    /// 纵向相邻（归并口径）：允许 −0.25×行高重叠、≤ 0.8×行高间距，且下行确在上行之下。
    public func isVerticallyAdjacent(_ previous: LayoutRect, _ next: LayoutRect) -> Bool {
        let gap = next.y - previous.maxY
        return gap >= -Self.adjacentOverlapTolerance * medianHeight
            && gap <= Self.adjacentGapTolerance * medianHeight
            && next.midY > previous.midY
    }

    /// 段内行距（段落聚合口径）：下行 y − 上行 maxY ≤ 1.0×行高。
    public func isWithinParagraphGap(_ previous: LayoutRect, _ next: LayoutRect) -> Bool {
        next.y - previous.maxY <= Self.paragraphGapTolerance * medianHeight
    }

    /// 上行写满：右缘达 `max(rightEdge − 2×行高, 0.5)`。
    public func fillsLineWidth(_ rect: LayoutRect) -> Bool {
        rect.maxX >= max(rightEdge - Self.fillSlackHeights * medianHeight, Self.absoluteFillFloor)
    }

    /// 下行不比上行长（+0.5×行高松弛）。
    public func isNotLonger(_ next: LayoutRect, than previous: LayoutRect) -> Bool {
        next.width <= previous.width + Self.notLongerSlackHeights * medianHeight
    }
}
