import Testing
import Foundation
@testable import Domain

/// DB 检测后处理（Paddle 主轨）纯几何回归。
@Suite("SU-M15-PADDLEDET · DBTextPostprocess")
struct DBTextPostprocessTests {

    /// 在 `width × height` 的概率图上填一个矩形。
    private func map(width: Int, height: Int, rect: (x: Int, y: Int, w: Int, h: Int),
                     value: Float, background: Float = 0) -> [Float] {
        var values = [Float](repeating: background, count: width * height)
        for y in rect.y..<(rect.y + rect.h) {
            for x in rect.x..<(rect.x + rect.w) {
                values[y * width + x] = value
            }
        }
        return values
    }

    @Test("单个连通域 → 一个框，中心与几何一致")
    func singleBox() {
        let values = map(width: 100, height: 100, rect: (x: 10, y: 10, w: 20, h: 10), value: 0.9)
        let boxes = DBTextPostprocess.boxes(probabilities: values, height: 100, width: 100)
        #expect(boxes.count == 1)
        let box = boxes[0]
        // 外扩后中心不变；w=20,h=10,area=200,perimeter=60,d=4.667
        #expect(abs(box.midX - 0.20) < 0.001)
        #expect(abs(box.midY - 0.15) < 0.001)
        #expect(abs(box.width - (2 * 4.667 + 20) / 100) < 0.001)
        #expect(abs(box.height - (2 * 4.667 + 10) / 100) < 0.001)
        #expect(abs(box.score - 0.9) < 0.001)
    }

    @Test("平均概率低于 box_thresh 的连通域被丢弃")
    func lowScoreFiltered() {
        let values = map(width: 40, height: 40, rect: (x: 5, y: 5, w: 10, h: 10), value: 0.3)
        #expect(DBTextPostprocess.boxes(probabilities: values, height: 40, width: 40).isEmpty)
    }

    @Test("低于二值化阈值 → 无框")
    func belowThreshold() {
        let values = map(width: 40, height: 40, rect: (x: 5, y: 5, w: 10, h: 10), value: 0.1)
        #expect(DBTextPostprocess.boxes(probabilities: values, height: 40, width: 40).isEmpty)
    }

    @Test("小于 minSize 的连通域被丢弃")
    func tinyFiltered() {
        let values = map(width: 40, height: 40, rect: (x: 5, y: 5, w: 2, h: 2), value: 0.9)
        #expect(DBTextPostprocess.boxes(probabilities: values, height: 40, width: 40).isEmpty)
    }

    @Test("maxCandidates 按分数截断")
    func candidateCap() {
        var values = [Float](repeating: 0, count: 200 * 200)
        for index in 0..<5 {
            let x = 10 + index * 30
            for y in 10..<20 {
                for px in x..<(x + 10) { values[y * 200 + px] = Float(0.5 + Double(index) * 0.09) }
            }
        }
        var options = DBTextPostprocess.Options.ppocrv6SmallDet
        options.maxCandidates = 2
        let boxes = DBTextPostprocess.boxes(probabilities: values, height: 200, width: 200,
                                            options: options)
        #expect(boxes.count == 2)
        #expect(boxes.allSatisfy { $0.score >= 0.7 })
    }

    @Test("阅读序：按行分组，行内从左到右")
    func readingOrder() {
        let boxes = [
            DBTextPostprocess.Box(x: 0.60, y: 0.10, width: 0.10, height: 0.05, score: 0.9),
            DBTextPostprocess.Box(x: 0.10, y: 0.40, width: 0.10, height: 0.05, score: 0.9),
            DBTextPostprocess.Box(x: 0.10, y: 0.11, width: 0.10, height: 0.05, score: 0.9),
            DBTextPostprocess.Box(x: 0.60, y: 0.41, width: 0.10, height: 0.05, score: 0.9),
        ]
        let ordered = DBTextPostprocess.ordered(boxes)
        // 第 1 行：左 → 右；第 2 行：左 → 右
        #expect(abs(ordered[0].midX - 0.15) < 0.001)
        #expect(abs(ordered[1].midX - 0.65) < 0.001)
        #expect(abs(ordered[2].midY - 0.425) < 0.001)
        #expect(abs(ordered[3].midX - 0.65) < 0.001)
    }

    @Test("尺寸与概率数不一致 → 空结果")
    func invalidShape() {
        #expect(DBTextPostprocess.boxes(probabilities: [0.9], height: 2, width: 2).isEmpty)
        #expect(DBTextPostprocess.boxes(probabilities: [], height: 0, width: 0).isEmpty)
    }

    @Test("外扩后越界的框被裁到页面内")
    func clampToPage() {
        let values = map(width: 20, height: 20, rect: (x: 0, y: 0, w: 4, h: 4), value: 0.9)
        let boxes = DBTextPostprocess.boxes(probabilities: values, height: 20, width: 20)
        #expect(boxes.count == 1)
        #expect(boxes[0].x >= 0 && boxes[0].y >= 0)
        #expect(boxes[0].x + boxes[0].width <= 1.0001)
        #expect(boxes[0].y + boxes[0].height <= 1.0001)
    }
}
