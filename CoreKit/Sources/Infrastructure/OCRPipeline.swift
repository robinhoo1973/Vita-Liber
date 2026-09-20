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
    /// ② 归并：有块几何 → `TextLineMerger.merge(blocks:)` 以段落为边界
    /// （iOS 26 段落 ∥ `ParagraphBuilder` 几何派生）、表格块不合；无几何 → 纯文本归并。
    /// ③ 版面重映射：块 bbox 并集/置信均值、表格格与段落 `lineIndices` 按旧→新行号重写。
    private func normalizeAndMerge(_ recognition: ImageInputRules.Recognition)
        -> (lines: [String], layout: PageLayout?) {
        var lines: [String] = []
        var flattened = false
        for line in recognition.lines {
            let parts = line.components(separatedBy: "\n")
            if parts.count > 1 { flattened = true }
            lines.append(contentsOf: parts)
        }
        // 几何可用 = 未展平 ∧ 块数与行数一致（展平后块/行错位，几何不可信 → fail-closed 退纯文本）
        guard !flattened, let layout = recognition.layout, layout.blocks.count == lines.count else {
            let degraded = flattened ? PageLayout.linesOnly(lines) : recognition.layout
            let merged = TextLineMerger.merge(lines)
            guard merged.count != lines.count else { return (lines, degraded) }
            return (merged.map(\.text), rebuildBlocks(merged: merged, original: degraded))
        }
        let tableLines = Self.tableLineIndices(in: layout)
        let paragraphs = Self.effectiveParagraphs(for: layout, excluding: tableLines)
        let merged = TextLineMerger.merge(blocks: layout.blocks, paragraphs: paragraphs, tableLineIndices: tableLines)
        let withParagraphs = PageLayout(blocks: layout.blocks, tables: layout.tables, paragraphs: paragraphs)
        guard merged.count != lines.count else { return (lines, withParagraphs) }
        return (merged.map(\.text), rebuildLayout(merged: merged, original: withParagraphs))
    }

    /// 表格占用的行号集（拆子表达式，2026-09-20 告警清除：单式超类型检查预算）。
    private static func tableLineIndices(in layout: PageLayout) -> Set<Int> {
        let bodyLineIndices: [Int] = layout.tables.flatMap { $0.rows.flatMap { $0.cells.flatMap(\.lineIndices) } }
        let headerLineIndices: [Int] = layout.tables.flatMap { $0.header?.cells.flatMap(\.lineIndices) ?? [] }
        return Set(bodyLineIndices + headerLineIndices)
    }

    /// iOS 26 段落 ∥ ParagraphBuilder 几何派生（同上拆出）。
    private static func effectiveParagraphs(for layout: PageLayout, excluding tableLines: Set<Int>) -> [Paragraph] {
        layout.paragraphs.isEmpty
            ? ParagraphBuilder.paragraphs(from: layout.blocks, excluding: tableLines)
            : layout.paragraphs
    }

    /// 合并行 → 布局块重建（无几何路径沿用）：成员块 bbox 并集、置信均值；对不上 → linesOnly。
    private func rebuildBlocks(merged: [TextLineMerger.MergedLine], original: PageLayout?) -> PageLayout? {
        guard let original else { return PageLayout.linesOnly(merged.map(\.text)) }
        return rebuildLayout(merged: merged, original: original)
    }

    /// 合并行 → 整个版面重映射：块重建 + 表格格/段落行号按旧→新重写（fail-closed：成员对不上退 linesOnly）。
    private func rebuildLayout(merged: [TextLineMerger.MergedLine], original: PageLayout) -> PageLayout {
        var newIndex: [Int: Int] = [:]
        var blocks: [TextBlock] = []
        for (index, line) in merged.enumerated() {
            let members = line.sourceIndices.compactMap { idx in original.blocks.first { $0.lineIndex == idx } }
            guard members.count == line.sourceIndices.count else {
                return PageLayout.linesOnly(merged.map(\.text))
            }
            for src in line.sourceIndices { newIndex[src] = index }
            let bbox = members.dropFirst().reduce(members[0].bbox) { $0.union($1.bbox) }
            let confidence = members.map(\.confidence).reduce(0, +) / Double(members.count)
            blocks.append(TextBlock(text: line.text, bbox: bbox, lineIndex: index, confidence: confidence))
        }
        func remap(_ indices: [Int]) -> [Int] {
            var seen = Set<Int>(), out: [Int] = []
            for i in indices { if let n = newIndex[i], seen.insert(n).inserted { out.append(n) } }
            return out
        }
        let tables = original.tables.map { table in
            TableRegion(id: table.id, bbox: table.bbox,
                        rows: table.rows.map { row in TableRow(cells: row.cells.map { cell in
                            TableCell(text: cell.text, bbox: cell.bbox, columnIndex: cell.columnIndex, lineIndices: remap(cell.lineIndices)) }) },
                        header: table.header.map { row in TableRow(cells: row.cells.map { cell in
                            TableCell(text: cell.text, bbox: cell.bbox, columnIndex: cell.columnIndex, lineIndices: remap(cell.lineIndices)) }) })
        }
        let paragraphs = original.paragraphs.map { p in
            let idx = remap(p.lineIndices)
            return Paragraph(text: idx.map { merged[$0].text }.joined(separator: "\n"), bbox: p.bbox, lineIndices: idx)
        }
        return PageLayout(blocks: blocks, tables: tables, paragraphs: paragraphs)
    }
}
// [linux-unguard] end
