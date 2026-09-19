// [linux-unguard] 双平台纯逻辑文件：守卫解除使 Linux 型检可见（2026-09-19 CI 对等性轮）
import Foundation
import Domain
import Protocols

/// ADR-026 编排层类型（V3.50 承诺、此前缺失）：OCR 管线统一编排点——
/// 解码（灰度）→ 质量评估（FR5.3 模糊/反光提示，不阻止保存）→ 识别 →
/// 归一化文本。上层（App 状态仓）只依赖本类型与能力协议，不直接持有
/// 具体引擎（EAL 纪律）。产出统一为 `lines+confidence` 归一化结果；
/// 确认流与 BR-003 D→C 分级不感知具体引擎实现。
public struct OCRPipeline: Sendable {
    private let recognizer: any ImageTextRecognizing
    private let grayscaleDecoder: any GrayscaleDecoding

    public init(recognizer: any ImageTextRecognizing, grayscaleDecoder: any GrayscaleDecoding) {
        self.recognizer = recognizer
        self.grayscaleDecoder = grayscaleDecoder
    }

    public struct Result: Sendable, Equatable {
        public var lines: [String]
        public var hasText: Bool
        public var confidence: Double
        /// FR5.3 质量提示标签（模糊/过暗/疑似遮挡——提示重拍但不阻止保存）
        public var qualityTags: [String]
        /// FR6.6：识别引擎失败标记——「引擎崩溃」与「页面无文字」必须可区分，
        /// 失败必须走可见错误反馈，绝不静默按「无文字」入库。
        public var failed: Bool
        /// FR5.5 版面（子项目 E1）：透传识别层 `Recognition.layout`（块 bbox / 表格 / 段落）；
        /// 引擎不给版面或失败 → nil，消费方以 `PageLayout.linesOnly(lines)` 退化。
        public var layout: PageLayout?
        public init(lines: [String], hasText: Bool, qualityTags: [String] = [],
                    failed: Bool = false, confidence: Double = 0, layout: PageLayout? = nil) {
            self.lines = lines; self.hasText = hasText
            self.qualityTags = qualityTags; self.failed = failed
            self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
            self.layout = layout
        }
    }

    /// 单图管线：灰度解码 → 质量评估（FR5.3）→ 识别。
    /// 识别引擎失败 → failed=true（FR6.6：调用方必须可见反馈）；
    /// 纯影像页无文字（failed=false）不视为错误流程。
    public func run(imageData: Data) async throws -> Result {
        var tags: [String] = []
        do {
            let grayscale = try grayscaleDecoder.decode(imageData, maxDimension: 256)
            tags = CaptureQualityAssessor.assess(grayscale).tags
        } catch {
            tags = []   // 质量评估失败不阻断识别主链路
        }
        do {
            let recognition = try await recognizer.recognize(imageData)
            // 换行归一 + 拆词归并（单一落点，业主 2026-09-19 第 3 项）：此后
            // 所有消费方——字段抽取、sourceLineIndex 锚定、确认页原文、rawText
            // 往返——看到同一份行数组，锚定坐标系一致。见 normalizeAndMerge。
            let normalized = normalizeAndMerge(recognition)
            return Result(lines: normalized.lines, hasText: !normalized.lines.isEmpty,
                          qualityTags: tags, confidence: recognition.confidence,
                          layout: normalized.layout)
        } catch is CancellationError {
            // 审查修复（取消透明性）：用户取消 ≠ 引擎崩溃——旧实现吞掉
            // CancellationError 并落 failed=true（FR6.6 引擎失败 UI），
            // 取消的页被标「识别失败」而非「跳过」。抛还调用方走取消分支。
            throw CancellationError()
        } catch {
            return Result(lines: [], hasText: false, qualityTags: tags, failed: true)
        }
    }

    /// ① 行内嵌换行展平：Vision 合体观察（candidate.string 含 "\n"）会让
    /// rawText 按 "\n" 往返拆行时静默错位——恢复模式的行锚定（resume
    /// mode `components(separatedBy: "\n")`）对不上抽取时的行号；
    /// ② 换行拆词归并（`TextLineMerger`，fail-safe：宁可漏合不可错合）。
    /// 结构化版面（表格/段落，iOS 26 路径）不归并——表格行身份优先。
    private func normalizeAndMerge(_ recognition: ImageInputRules.Recognition)
        -> (lines: [String], layout: PageLayout?) {
        var lines: [String] = []
        var flattened = false
        for line in recognition.lines {
            let parts = line.components(separatedBy: "\n")
            if parts.count > 1 { flattened = true }
            lines.append(contentsOf: parts)
        }
        let layout = recognition.layout
        let hasStructure = (layout?.tables.isEmpty == false) || (layout?.paragraphs.isEmpty == false)
        let degraded = flattened ? PageLayout.linesOnly(lines) : layout
        guard !hasStructure else { return (lines, degraded) }
        let merged = TextLineMerger.merge(lines)
        guard merged.count != lines.count else { return (lines, degraded) }
        return (merged.map(\.text), rebuildBlocks(merged: merged, original: layout))
    }

    /// 合并行 → 布局块重建：成员块的 bbox 并集、置信均值；原布局缺失或
    /// 成员块对不上（几何证据链断裂）→ 退化 linesOnly（fail-closed，
    /// 框级锚定纪律：匹配不上不画）。
    private func rebuildBlocks(merged: [TextLineMerger.MergedLine], original: PageLayout?) -> PageLayout? {
        guard let original else { return PageLayout.linesOnly(merged.map(\.text)) }
        var blocks: [TextBlock] = []
        for (index, line) in merged.enumerated() {
            let members = line.sourceIndices.compactMap { idx in
                original.blocks.first { $0.lineIndex == idx }
            }
            guard members.count == line.sourceIndices.count else {
                return PageLayout.linesOnly(merged.map(\.text))
            }
            let bbox = members.dropFirst().reduce(members[0].bbox) { $0.union($1.bbox) }
            let confidence = members.map(\.confidence).reduce(0, +) / Double(members.count)
            blocks.append(TextBlock(text: line.text, bbox: bbox, lineIndex: index, confidence: confidence))
        }
        return PageLayout(blocks: blocks)
    }
}
// [linux-unguard] end
