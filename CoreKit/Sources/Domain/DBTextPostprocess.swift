import Foundation

/// PP-OCR DB 文本检测后处理（2026-11-04 Paddle 主轨批）。
///
/// 纯函数、只用 Foundation：输入检测模型输出的概率图（行优先 `[Float]`，
/// 尺寸 `height × width`），输出归一化文本框（左上原点、0…1）。
/// 参数与官方 `inference.yml` 的 `DBPostProcess` 同源：
/// `thresh / box_thresh / unclip_ratio / max_candidates`。
///
/// 与 OpenCV 参考实现的差异（有意为之、可回归验证）：
/// - 连通域用 8 邻接泛洪，近似 `cv2.findContours` 的外轮廓；
/// - unclip 用「按面积/周长外扩的轴对齐矩形」近似多边形外扩；
/// - 不返回旋转矩形——下游裁片本来就是轴对齐裁剪，旋转框会引入
///   另一套坐标约定而无实际收益。
public enum DBTextPostprocess {

    public struct Options: Sendable, Equatable {
        /// 概率图二值化阈值。
        public var thresh: Double
        /// 连通域平均概率下限。
        public var boxThresh: Double
        /// 外扩系数（官方 1.4）。
        public var unclipRatio: Double
        /// 最多保留的候选框数（官方 3000）。
        public var maxCandidates: Int
        /// 连通域最小边（像素）。
        public var minSize: Int

        public init(thresh: Double = 0.2, boxThresh: Double = 0.45,
                    unclipRatio: Double = 1.4, maxCandidates: Int = 3000,
                    minSize: Int = 3) {
            self.thresh = thresh
            self.boxThresh = boxThresh
            self.unclipRatio = unclipRatio
            self.maxCandidates = maxCandidates
            self.minSize = minSize
        }

        /// 官方 `PP-OCRv6_small_det` 的 `inference.yml` 参数。
        public static let ppocrv6SmallDet = Options()
    }

    /// 归一化文本框（左上原点）。`score` 为连通域平均概率。
    public struct Box: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var score: Double

        public init(x: Double, y: Double, width: Double, height: Double, score: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.score = score
        }

        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
    }

    /// 概率图 → 归一化文本框（未排序；调用方用 `ordered(_:)` 排阅读序）。
    public static func boxes(probabilities: [Float], height: Int, width: Int,
                             options: Options = .ppocrv6SmallDet) -> [Box] {
        guard height > 0, width > 0, probabilities.count == height * width else { return [] }
        let total = height * width
        var mask = [Bool](repeating: false, count: total)
        for index in 0..<total where Double(probabilities[index]) >= options.thresh {
            mask[index] = true
        }
        if !mask.contains(true) { return [] }

        var visited = [Bool](repeating: false, count: total)
        var stack: [Int] = []
        var boxes: [Box] = []
        let minSize = max(1, options.minSize)

        for start in 0..<total {
            guard mask[start], !visited[start] else { continue }
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var minX = width, maxX = -1, minY = height, maxY = -1
            var sum = 0.0, count = 0
            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                sum += Double(probabilities[index])
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                let yStart = y > 0 ? y - 1 : y
                let yEnd = y + 1 < height ? y + 1 : y
                let xStart = x > 0 ? x - 1 : x
                let xEnd = x + 1 < width ? x + 1 : x
                for ny in yStart...yEnd {
                    let row = ny * width
                    for nx in xStart...xEnd {
                        let next = row + nx
                        if mask[next], !visited[next] {
                            visited[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            guard count > 0 else { continue }
            let boxWidth = maxX - minX + 1
            let boxHeight = maxY - minY + 1
            guard boxWidth >= minSize, boxHeight >= minSize else { continue }
            let score = sum / Double(count)
            guard score >= options.boxThresh else { continue }

            // 面积/周长外扩：官方 unclip 的多边形版本在轴对齐矩形上的等价近似。
            let area = Double(boxWidth * boxHeight)
            let perimeter = Double(2 * (boxWidth + boxHeight))
            let distance = perimeter > 0 ? area * options.unclipRatio / perimeter : 0
            let left = Double(minX) - distance
            let top = Double(minY) - distance
            let right = Double(maxX + 1) + distance
            let bottom = Double(maxY + 1) + distance

            let clampedLeft = min(max(left, 0), Double(width))
            let clampedTop = min(max(top, 0), Double(height))
            let clampedRight = min(max(right, 0), Double(width))
            let clampedBottom = min(max(bottom, 0), Double(height))
            guard clampedRight > clampedLeft, clampedBottom > clampedTop else { continue }
            boxes.append(Box(x: clampedLeft / Double(width),
                             y: clampedTop / Double(height),
                             width: (clampedRight - clampedLeft) / Double(width),
                             height: (clampedBottom - clampedTop) / Double(height),
                             score: score))
        }

        if boxes.count > options.maxCandidates {
            boxes.sort { $0.score > $1.score }
            boxes = Array(boxes.prefix(options.maxCandidates))
        }
        return boxes
    }

    /// 阅读序：先按竖直中心聚行（容差 = 行高 60%），行内按 x 升序。
    ///
    /// 与 PaddleOCR `sorted_boxes` 同目标，但不使用需要额外参数的
    /// 「高度中位数」——直接以当前行高自适应，避免小字号页与大字标题页
    /// 共用同一固定阈值。
    public static func ordered(_ boxes: [Box]) -> [Box] {
        readingOrder(boxes, box: { $0 })
    }

    /// 同 `ordered(_:)`，用于任意附带了框的元素（识别行、版面块等）。
    public static func readingOrder<T>(_ items: [T], box: (T) -> Box) -> [T] {
        guard items.count > 1 else { return items }
        let indexed = items.enumerated().map { (offset: $0.offset, box: box($0.element)) }
        let sorted = indexed.sorted { a, b in
            a.box.midY == b.box.midY ? a.box.midX < b.box.midX : a.box.midY < b.box.midY
        }
        var rows: [[(offset: Int, box: Box)]] = []
        var current: [(offset: Int, box: Box)] = []
        var rowY = 0.0
        var rowHeight = 0.0
        for entry in sorted {
            if current.isEmpty {
                current = [entry]
                rowY = entry.box.midY
                rowHeight = entry.box.height
                continue
            }
            let tolerance = max(rowHeight, entry.box.height) * 0.6
            if abs(entry.box.midY - rowY) <= tolerance {
                current.append(entry)
                rowY = current.reduce(0.0) { $0 + $1.box.midY } / Double(current.count)
                rowHeight = max(rowHeight, entry.box.height)
            } else {
                rows.append(current)
                current = [entry]
                rowY = entry.box.midY
                rowHeight = entry.box.height
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows.flatMap { $0.sorted { $0.box.x < $1.box.x } }.map { items[$0.offset] }
    }
}
