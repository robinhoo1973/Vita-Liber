import Foundation

/// FR6.1 换行拆分词的归并（业主 2026-09-19 第 3 项：「无法对由于换行而分隔开
/// 的词语…自动整合成一行」）。
///
/// Vision 行识别按视觉行输出：长句折行时一个词被拆到两行（「阿莫西林克拉维
/// 酸钾分」+「散片」）。文本下游——字段抽取、`sourceLineIndex` 原文锚定、
/// 确认页原文呈现——全部按行索引工作：拆词行既降低抽取召回，也让确认页
/// 原文读起来断句错乱。归并必须在管线出口一次性完成（OCRPipeline），
/// 之后所有消费方看到同一份合并后的行数组，锚定坐标系不变。
///
/// **fail-safe 纪律（宁可漏合、不可错合）**：归并只是拼接，绝不删除任何字符
/// （BR-002 不丢内容）；但错合会把「药名行 + 用法行」粘成一行、污染行身份
/// 与抽取行语义。合并条件全部成立才合：
/// 1. 两行均非空；
/// 2. 上行末字符与下行首字符都是字母/CJK（非数字、非标点、非空白）——
///    「血压」+「120/80」这类标签-值对绝不合并（值以数字开头）；
/// 3. 上行不含任何 ASCII 数字——「0.25g×24粒」类剂量/规格行绝不与下行
///    粘连（处方行身份第一；含数字的长叙事折行宁可漏合）；
/// 4. 下行不以剂量/用法引导词开头（`DocumentTypeClassifierFallback.
///    directionsPrefixes` 单一词表——「口服 每日三次」是行本体而非续行）；
/// 5. 下行不含冒号（「用法：…」标签行不并入上行）；
/// 6. 上行长度 ≥ 8 字符——折行是**长行**被视觉行宽截断的结果；短行
///    （标签、短项目）与下行粘连几乎必是错合（短碎片宁可漏合）。
///
/// 拼接沿用 `TranscriptJoiner` 的 CJK 感知策略（CJK 相接不加空格、拉丁两侧
/// 加空格——全仓唯一 CJK 边界定义，此处不另立第二套）。
public enum TextLineMerger {

    /// 归并产物：合并后的行文本 + 该行吸收的原始行下标（供布局块重建）。
    public struct MergedLine: Equatable, Sendable {
        public var text: String
        public var sourceIndices: [Int]
        public init(text: String, sourceIndices: [Int]) {
            self.text = text
            self.sourceIndices = sourceIndices
        }
    }

    /// 换行拆分词归并（纯函数，确定性）。
    public static func merge(_ lines: [String]) -> [MergedLine] {
        var result: [MergedLine] = []
        for (index, line) in lines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result.append(MergedLine(text: line, sourceIndices: [index]))
                continue
            }
            if let last = result.last, last.sourceIndices.last == index - 1,
               shouldJoin(previous: last.text, next: line) {
                result[result.count - 1] = MergedLine(
                    text: TranscriptJoiner.join([last.text, line]),
                    sourceIndices: last.sourceIndices + [index])
            } else {
                result.append(MergedLine(text: line, sourceIndices: [index]))
            }
        }
        return result
    }

    /// 合并后的行文本（便捷投影）。
    public static func mergedText(_ lines: [String]) -> [String] {
        merge(lines).map(\.text)
    }

    // MARK: - 合并判定

    static func shouldJoin(previous: String, next: String) -> Bool {
        guard !previous.isEmpty, !next.isEmpty else { return false }
        let previousBody = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextBody = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previousBody.isEmpty, !nextBody.isEmpty,
              let lastChar = previousBody.last, let firstChar = nextBody.first else { return false }
        // 2. 边界字符须为字母/CJK（数字/标点/空白即断）。
        guard isWordCharacter(lastChar), isWordCharacter(firstChar) else { return false }
        // 3. 上行不含 ASCII 数字。
        guard !previousBody.unicodeScalars.contains(where: { (0x30...0x39).contains($0.value) }) else { return false }
        // 4. 下行不以剂量/用法引导词开头（前缀判定，见 `startsWithDirectionsPrefix`）。
        if startsWithDirectionsPrefix(nextBody) { return false }
        // 5. 下行不含冒号（标签行）。
        if containsColon(nextBody) { return false }
        // 6. 上行长度 ≥ 8 字符（折行是长行被视觉行宽截断的结果；短行粘连
        // 几乎必是错合——fail-safe 宁可漏合）。
        guard previousBody.count >= 8 else { return false }
        return true
    }

    /// 字母或 CJK（全仓唯一 CJK 边界定义在 `TranscriptJoiner`，同源复用）。
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || TranscriptJoiner.isCJK(character)
    }

    // MARK: - 几何证据归并（2026-09-20 业主 Q1：分段/换行）

    /// 带版面的归并：文本规则不成立时，以几何折行证据放宽（同列 ∧ 相邻 ∧ 上行写满 ∧ 下行不更长）。
    /// 表格块 / 多列视觉行 / 跨段落绝不归并；无块几何时调用方应退回 `merge(_ lines:)`。
    public static func merge(blocks: [TextBlock], paragraphs: [Paragraph] = [],
                             tableLineIndices: Set<Int> = []) -> [MergedLine] {
        let ordered = blocks.sorted { $0.lineIndex < $1.lineIndex }
        guard !ordered.isEmpty else { return [] }
        // 版面度量单点（round4 P-1/P-4）：中位行高 / 90 分位右缘 / 多列行集由 `LayoutMetrics` 一次计算。
        let metrics = LayoutMetrics(blocks: ordered)
        let multiColumn = metrics.multiColumnLineIndices
        var paragraphOf: [Int: Int] = [:]
        for (p, paragraph) in paragraphs.enumerated() { for li in paragraph.lineIndices { paragraphOf[li] = p } }

        var result: [MergedLine] = []
        var lastBlock: TextBlock?
        for block in ordered {
            defer { lastBlock = block }
            guard let previous = lastBlock, let last = result.last,
                  block.lineIndex == previous.lineIndex + 1,
                  !tableLineIndices.contains(previous.lineIndex), !tableLineIndices.contains(block.lineIndex),
                  !multiColumn.contains(previous.lineIndex), !multiColumn.contains(block.lineIndex),
                  paragraphs.isEmpty || (paragraphOf[previous.lineIndex] != nil && paragraphOf[previous.lineIndex] == paragraphOf[block.lineIndex])
            else {
                result.append(MergedLine(text: block.text, sourceIndices: [block.lineIndex]))
                continue
            }
            let textual = shouldJoin(previous: last.text, next: block.text)
            let geometric = geometricWrapEvidence(previous: previous.bbox, next: block.bbox, metrics: metrics)
                && relaxedTextualGuard(previous: last.text, next: block.text)
            if textual || geometric {
                result[result.count - 1] = MergedLine(text: TranscriptJoiner.join([last.text, block.text]),
                                                      sourceIndices: last.sourceIndices + [block.lineIndex])
            } else {
                result.append(MergedLine(text: block.text, sourceIndices: [block.lineIndex]))
            }
        }
        return result
    }

    /// 折行的四条几何证据（全部成立才算）：同列 ∧ 纵向相邻 ∧ 上行写满 ∧ 下行不更长。
    /// 阈值全部由 `LayoutMetrics` 以中位行高为单位给出（含 round3 开发委员的半页宽绝对下限——
    /// 全窄列收据 rightEdge 退化时「上行写满」恒真，须再覆盖半页宽）。
    static func geometricWrapEvidence(previous: LayoutRect, next: LayoutRect, metrics: LayoutMetrics) -> Bool {
        metrics.isSameColumn(previous, next)
            && metrics.isVerticallyAdjacent(previous, next)
            && metrics.fillsLineWidth(previous)
            && metrics.isNotLonger(next, than: previous)
    }

    /// 几何路径的文本护栏（比 `shouldJoin` 宽：允许上行含数字、短于 8 字、以逗号/顿号结尾）。
    /// 与 `shouldJoin` 共用「冒号行 / 引导词行」两谓词（round4 P-5：此前重写一份，规则分叉温床）。
    static func relaxedTextualGuard(previous: String, next: String) -> Bool {
        let p = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = p.last, let firstChar = n.first else { return false }
        if endsWithSentenceTerminal(p) { return false }
        if containsColon(n) { return false }
        if startsWithDirectionsPrefix(n) { return false }
        if isColon(lastChar) && firstChar.isNumber { return false }
        return true
    }

    // MARK: - 行文本谓词（细粒度，供两条归并路径共用）

    /// 句末标点（中英）：上行以此结尾即完整句，不续。
    static let sentenceTerminals: Set<Character> = ["。", "！", "？", "!", "?"]

    static func endsWithSentenceTerminal(_ body: String) -> Bool {
        body.last.map { sentenceTerminals.contains($0) } ?? false
    }

    static func isColon(_ character: Character) -> Bool { character == ":" || character == "：" }

    /// 下行含冒号 ⇒ 标签行（「用法：…」），不并入上行。
    static func containsColon(_ body: String) -> Bool { body.contains(where: isColon) }

    /// 下行以剂量/用法引导词开头（**前缀**判定：「每日三次」须被「每日」拦下；整词相等会让复合用法行漏网）。
    /// 词表单源 `DocumentTypeClassifierFallback.directionsPrefixes`。
    static func startsWithDirectionsPrefix(_ body: String) -> Bool {
        let leadingToken = String(body.prefix { !$0.isWhitespace && !$0.isPunctuation })
        return DocumentTypeClassifierFallback.directionsPrefixes.contains { leadingToken.hasPrefix($0) }
    }
}
