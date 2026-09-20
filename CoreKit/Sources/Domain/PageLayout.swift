import Foundation

/// FR5.5 版面值对象（整改 §4.1 / 2026-09-14 子项目 E1）：识别层此前只丢「文本 + 置信」
/// → 表格多药不成行（round2 O-N3/O-N4 上游根因）。本文件把块/bbox/表格/段落带入 Domain，
/// 供 CardExtractionEngine（E2+）按行身份建卡。
///
/// 坐标归一化到 0…1、**原点左上**（Vision 左下原点在 Infrastructure 翻转后进入）。
/// 命名避让：Vision Swift API 自带 `NormalizedRect`，Domain 矩形命名 `LayoutRect`。
public struct LayoutRect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var midY: Double { y + height / 2 }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var maxX: Double { x + width }
    /// 两矩形最小外接矩形。
    public func union(_ other: LayoutRect) -> LayoutRect {
        let x0 = min(x, other.x), y0 = min(y, other.y)
        return LayoutRect(x: x0, y: y0,
                          width: max(maxX, other.maxX) - x0,
                          height: max(maxY, other.maxY) - y0)
    }
    /// 点（归一化坐标）是否落在矩形内（闭区间）。
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }
    /// 一组矩形的最小外接矩形；空集 → nil（round4 P-2：三处 `dropFirst().reduce(union)` 收敛）。
    public static func union(of rects: [LayoutRect]) -> LayoutRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}

/// 识别出的一行文本块：`id = "b<lineIndex>"`，`lineIndex` 与 `Recognition.lines` 下标一一对应。
public struct TextBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let bbox: LayoutRect
    public let lineIndex: Int
    public let confidence: Double
    public init(text: String, bbox: LayoutRect, lineIndex: Int, confidence: Double) {
        self.id = "b\(lineIndex)"; self.text = text; self.bbox = bbox
        self.lineIndex = lineIndex; self.confidence = confidence
    }
}

/// 表格单元格（iOS 26 `RecognizeDocumentsRequest` 出表；`lineIndices` = 中心落在格内的行）。
public struct TableCell: Codable, Sendable, Equatable {
    public var text: String, bbox: LayoutRect, columnIndex: Int, lineIndices: [Int]
    public init(text: String, bbox: LayoutRect, columnIndex: Int, lineIndices: [Int]) {
        self.text = text; self.bbox = bbox; self.columnIndex = columnIndex; self.lineIndices = lineIndices
    }
}

public struct TableRow: Codable, Sendable, Equatable {
    public var cells: [TableCell]
    public init(cells: [TableCell]) { self.cells = cells }
}

/// 表格区域：`header` 由 Domain 后续按列别名判定（E3），识别层恒给 nil。
public struct TableRegion: Codable, Sendable, Equatable {
    public var id: String, bbox: LayoutRect, rows: [TableRow], header: TableRow?
    public init(id: String, bbox: LayoutRect, rows: [TableRow], header: TableRow? = nil) {
        self.id = id; self.bbox = bbox; self.rows = rows; self.header = header
    }
}

public struct Paragraph: Codable, Sendable, Equatable {
    public var text: String, bbox: LayoutRect, lineIndices: [Int]
    public init(text: String, bbox: LayoutRect, lineIndices: [Int]) {
        self.text = text; self.bbox = bbox; self.lineIndices = lineIndices
    }
}

/// 单页版面：`blocks` 恒有（iOS 16 路径亦有 bbox）；`tables`/`paragraphs` 仅 iOS 26 结构化路径填充。
public struct PageLayout: Codable, Sendable, Equatable {
    public var blocks: [TextBlock], tables: [TableRegion], paragraphs: [Paragraph]
    public init(blocks: [TextBlock], tables: [TableRegion] = [], paragraphs: [Paragraph] = []) {
        self.blocks = blocks; self.tables = tables; self.paragraphs = paragraphs
    }
    /// 表格占用的行号集（正文格 + 表头格）。round4 P-3：此前 `OCRPipeline` 与 `extractionRegions` 各自定义，
    /// 归并与抽取对「哪些行属表格」若不同源，表格行会被一边禁合、另一边当段落——单点定义。
    /// 拆子表达式（2026-09-20 告警清除）：单式超类型检查预算。
    public var tableLineIndices: Set<Int> {
        let body: [Int] = tables.flatMap { $0.rows.flatMap { $0.cells.flatMap(\.lineIndices) } }
        let header: [Int] = tables.flatMap { $0.header?.cells.flatMap(\.lineIndices) ?? [] }
        return Set(body + header)
    }

    /// 兼容退化（design §4.4「都不可用时」）：每行一块、竖直等分——引擎仍可工作，只是行身份弱。
    public static func linesOnly(_ lines: [String]) -> PageLayout {
        let h = 1.0 / Double(max(lines.count, 1))
        return PageLayout(blocks: lines.enumerated().map { i, t in
            TextBlock(text: t, bbox: LayoutRect(x: 0, y: Double(i) * h, width: 1, height: h),
                      lineIndex: i, confidence: 0)
        })
    }
}

/// 几何聚行产物：一格 = 一块；`columnIndex` 为页内 x 对齐簇序。
public struct LayoutCell: Codable, Sendable, Equatable {
    public var blockId: String, text: String, lineIndex: Int, columnIndex: Int, bbox: LayoutRect
    public init(blockId: String, text: String, lineIndex: Int, columnIndex: Int, bbox: LayoutRect) {
        self.blockId = blockId; self.text = text; self.lineIndex = lineIndex
        self.columnIndex = columnIndex; self.bbox = bbox
    }
}

public struct LayoutRow: Codable, Sendable, Equatable {
    public var id: String, cells: [LayoutCell], bbox: LayoutRect
    public init(id: String, cells: [LayoutCell], bbox: LayoutRect) {
        self.id = id; self.cells = cells; self.bbox = bbox
    }
    public var text: String { cells.map(\.text).joined(separator: " ") }
    public var lineIndices: [Int] { cells.map(\.lineIndex) }
}

/// 几何聚行（iOS < 26 无表格结构时的行身份来源）：确定性、与输入顺序无关。
public enum LayoutRowBuilder {
    /// 按 (midY, x, lineIndex) 排序；块与当前行**首块**竖向重叠 ≥ `overlapRatio`×min(高)
    /// 或 |ΔmidY| ≤ 0.6×中位块高 → 同行（锚定首块、不随尾块漂移）；行内按 x 排。
    public static func rows(from blocks: [TextBlock], overlapRatio: Double = 0.5) -> [LayoutRow] {
        let sorted = blocks.sorted {
            ($0.bbox.midY, $0.bbox.x, $0.lineIndex) < ($1.bbox.midY, $1.bbox.x, $1.lineIndex)
        }
        guard !sorted.isEmpty else { return [] }
        let median = sorted.map(\.bbox.height).sorted()[sorted.count / 2]
        var groups: [[TextBlock]] = []
        for block in sorted {
            if let anchor = groups.last?.first {
                let overlap = min(anchor.bbox.maxY, block.bbox.maxY) - max(anchor.bbox.y, block.bbox.y)
                if overlap >= overlapRatio * min(anchor.bbox.height, block.bbox.height)
                    || abs(anchor.bbox.midY - block.bbox.midY) <= 0.6 * median {
                    groups[groups.count - 1].append(block)
                    continue
                }
            }
            groups.append([block])
        }
        var rows = groups.enumerated().map { index, group -> LayoutRow in
            let cells = group
                .sorted { ($0.bbox.x, $0.lineIndex) < ($1.bbox.x, $1.lineIndex) }
                .map { LayoutCell(blockId: $0.id, text: $0.text, lineIndex: $0.lineIndex, columnIndex: 0, bbox: $0.bbox) }
            // group 非空（每组至少一块），union(of:) 非 nil；`?? cells[0].bbox` 仅为类型闭合。
            let bbox = LayoutRect.union(of: cells.map(\.bbox)) ?? cells[0].bbox
            return LayoutRow(id: "r\(index)", cells: cells, bbox: bbox)
        }
        assignColumns(&rows, tolerance: max(0.02, median))
        return rows
    }

    /// 列对齐：全部 cell 左边界一维排序，相邻差 > tolerance 即开新簇；簇序 = columnIndex。
    static func assignColumns(_ rows: inout [LayoutRow], tolerance: Double) {
        var starts: [Double] = []
        var previous: Double?
        for x in rows.flatMap({ $0.cells.map(\.bbox.x) }).sorted() {
            if let p = previous, x - p <= tolerance { previous = x; continue }
            starts.append(x); previous = x
        }
        for r in rows.indices {
            for c in rows[r].cells.indices {
                let x = rows[r].cells[c].bbox.x
                rows[r].cells[c].columnIndex = starts.lastIndex { $0 <= x + 1e-9 } ?? 0
            }
        }
    }
}
