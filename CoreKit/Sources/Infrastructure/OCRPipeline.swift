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
        /// 影子识别诊断（2026-11-03 调参批）：只透传，不参与确认/事实链。
        public var debugTrace: OCRDebugTrace?
        public init(lines: [String], hasText: Bool, qualityTags: [String] = [],
                    failed: Bool = false, confidence: Double = 0, layout: PageLayout? = nil,
                    debugTrace: OCRDebugTrace? = nil) {
            self.lines = lines; self.hasText = hasText
            self.qualityTags = qualityTags; self.failed = failed
            self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
            self.layout = layout
            self.debugTrace = debugTrace
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
                          layout: normalized.layout, debugTrace: normalized.debugTrace)
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
    /// ② 归并：有块几何 → `TextLineMerger.merge(blocks:)` 以段落为边界
    /// （iOS 26 段落 ∥ `ParagraphBuilder` 几何派生）、表格块不合；无几何 → 纯文本归并。
    /// ③ 版面重映射：块 bbox 并集/置信均值、表格格与段落 `lineIndices` 按旧→新行号重写。
    private func normalizeAndMerge(_ recognition: ImageInputRules.Recognition)
        -> (lines: [String], layout: PageLayout?, debugTrace: OCRDebugTrace?) {
        var lines: [String] = []
        var flattened = false
        for line in recognition.lines {
            let parts = line.components(separatedBy: "\n")
            if parts.count > 1 { flattened = true }
            lines.append(contentsOf: parts)
        }
        // 几何可用 = 未展平 ∧ 块数与行数一致（展平后块/行错位，几何不可信 → fail-closed 退纯文本）
        guard !flattened, let layout = recognition.layout, layout.blocks.count == lines.count else {
            let degraded = flattened || recognition.layout != nil ? PageLayout.linesOnly(lines) : recognition.layout
            let merged = TextLineMerger.merge(lines)
            // 展平后 trace 的 lineIndex 对应原始 Vision 观察，已与交付行错位；不能原样透传。
            guard !flattened else {
                return (merged.map(\.text), rebuildBlocks(merged: merged, original: degraded), nil)
            }
            guard merged.count != lines.count else { return (lines, degraded, recognition.debugTrace) }
            return (merged.map(\.text), rebuildBlocks(merged: merged, original: degraded),
                    remapTrace(recognition.debugTrace, merged: merged))
        }
        let tableLines = layout.tableLineIndices   // 单源 PageLayout.tableLineIndices（round4 P-3）
        let paragraphs = Self.effectiveParagraphs(for: layout, excluding: tableLines)
        let merged = TextLineMerger.merge(blocks: layout.blocks, paragraphs: paragraphs, tableLineIndices: tableLines)
        let withParagraphs = PageLayout(blocks: layout.blocks, tables: layout.tables, paragraphs: paragraphs)
        guard merged.count != lines.count else { return (lines, withParagraphs, recognition.debugTrace) }
        return (merged.map(\.text), rebuildLayout(merged: merged, original: withParagraphs),
                remapTrace(recognition.debugTrace, merged: merged))
    }

    /// 调试轨迹跟随交付行重映射（2026-11-04）：归并后 `lineIndex` 必须指向交付行数组；
    /// `visionText` / `rawPaddleText` / `cnocrText` 分别保留**各自引擎原文**并按同一拼接
    /// 规则合并（`paddleText` 为共识后的交付文本，不能当原文）。页面级 schema v3 身份
    /// （`thirdModel`/`thirdModelSHA256`）必须原样透传：旧实现重建 trace 时丢字段，归并页
    /// 的调试 JSON 会退化成「只有 Paddle 一个假设」。交付文本由 App 采集层从实际页面行
    /// 传入，不能从 `visionText` 反推（Paddle 主轨后它不再是 Vision 文本）。
    private func remapTrace(_ trace: OCRDebugTrace?, merged: [TextLineMerger.MergedLine]) -> OCRDebugTrace? {
        guard let trace else { return nil }
        var byIndex: [Int: OCRDebugTrace.Line] = [:]
        for line in trace.lines where line.lineIndex >= 0 { byIndex[line.lineIndex] = line }
        let notes = trace.lines.filter { $0.lineIndex < 0 }
        var lines: [OCRDebugTrace.Line] = []
        for (newIndex, group) in merged.enumerated() {
            let sources = group.sourceIndices.compactMap { byIndex[$0] }
            guard !sources.isEmpty else {
                lines.append(.init(lineIndex: newIndex, bbox: [], visionText: "", paddleText: "",
                                   visionConfidence: 0, paddleConfidence: 0, cropWidth: 0, cropHeight: 0,
                                   recWidth: 0, timesteps: 0, latencyMs: 0, error: "no-source-trace"))
                continue
            }
            let bbox = Self.unionBBox(sources.map(\.bbox))
            let visionTexts = sources.map(\.visionText).filter { !$0.isEmpty }
            let rawPaddleTexts = sources.compactMap(\.rawPaddleText).filter { !$0.isEmpty }
            let cnocrTexts = sources.compactMap(\.cnocrText).filter { !$0.isEmpty }
            let paddleTexts = sources.map(\.paddleText).filter { !$0.isEmpty }
            let paddleSet = sources.filter { !$0.paddleText.isEmpty }
            let errors = sources.compactMap(\.error)
            lines.append(.init(
                lineIndex: newIndex, bbox: bbox, visionText: TranscriptJoiner.join(visionTexts),
                paddleText: TranscriptJoiner.join(paddleTexts),
                rawPaddleText: rawPaddleTexts.isEmpty ? nil : TranscriptJoiner.join(rawPaddleTexts),
                cnocrText: cnocrTexts.isEmpty ? nil : TranscriptJoiner.join(cnocrTexts),
                visionConfidence: sources.map(\.visionConfidence).reduce(0, +) / Double(sources.count),
                paddleConfidence: paddleSet.isEmpty ? 0
                    : paddleSet.map(\.paddleConfidence).reduce(0, +) / Double(paddleSet.count),
                cropWidth: sources.map(\.cropWidth).reduce(0, +),
                cropHeight: sources.map(\.cropHeight).reduce(0, +),
                recWidth: sources.map(\.recWidth).reduce(0, +),
                timesteps: sources.map(\.timesteps).reduce(0, +),
                latencyMs: sources.map(\.latencyMs).reduce(0, +),
                error: errors.isEmpty ? nil : errors.joined(separator: "; ")))
        }
        return OCRDebugTrace(pageIndex: trace.pageIndex, model: trace.model, modelSHA256: trace.modelSHA256,
                             detModel: trace.detModel, detModelSHA256: trace.detModelSHA256,
                             thirdModel: trace.thirdModel, thirdModelSHA256: trace.thirdModelSHA256,
                             engine: trace.engine, totalLatencyMs: trace.totalLatencyMs,
                             lines: notes + lines)
    }

    private static func unionBBox(_ boxes: [[Double]]) -> [Double] {
        let rects = boxes.compactMap { values -> (Double, Double, Double, Double)? in
            guard values.count == 4 else { return nil }
            return (values[0], values[1], values[0] + values[2], values[1] + values[3])
        }
        guard let first = rects.first else { return [] }
        var (minX, minY, maxX, maxY) = first
        for rect in rects.dropFirst() {
            minX = min(minX, rect.0); minY = min(minY, rect.1)
            maxX = max(maxX, rect.2); maxY = max(maxY, rect.3)
        }
        return [minX, minY, maxX - minX, maxY - minY]
    }

    /// iOS 26 段落 ∥ ParagraphBuilder 几何派生。
    private static func effectiveParagraphs(for layout: PageLayout, excluding tableLines: Set<Int>) -> [Paragraph] {
        layout.paragraphs.isEmpty
            ? ParagraphBuilder.paragraphs(from: layout.blocks, excluding: tableLines)
            : layout.paragraphs
    }

    /// 合并行 → 版面重映射（无几何路径沿用）：无原版面 → linesOnly；否则委托 Domain `LayoutRemapper`。
    private func rebuildBlocks(merged: [TextLineMerger.MergedLine], original: PageLayout?) -> PageLayout? {
        guard let original else { return PageLayout.linesOnly(merged.map(\.text)) }
        return LayoutRemapper.remap(merged: merged, original: original)
    }

    /// 合并行 → 整个版面重映射（round4 P-6：实现迁入 Domain `LayoutRemapper`，本处仅委托）。
    private func rebuildLayout(merged: [TextLineMerger.MergedLine], original: PageLayout) -> PageLayout {
        LayoutRemapper.remap(merged: merged, original: original)
    }
}
// [linux-unguard] end
