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
        // 4. 下行不以剂量/用法引导词开头（**前缀**判定：「每日三次」须被
        // 「每日」拦下——整词相等判定会让复合用法行漏网）。
        let leadingToken = String(nextBody.prefix { !$0.isWhitespace && !$0.isPunctuation })
        if DocumentTypeClassifierFallback.directionsPrefixes.contains(where: { leadingToken.hasPrefix($0) }) { return false }
        // 5. 下行不含冒号（标签行）。
        if nextBody.contains(":") || nextBody.contains("：") { return false }
        // 6. 上行长度 ≥ 8 字符（折行是长行被视觉行宽截断的结果；短行粘连
        // 几乎必是错合——fail-safe 宁可漏合）。
        guard previousBody.count >= 8 else { return false }
        return true
    }

    /// 字母或 CJK（全仓唯一 CJK 边界定义在 `TranscriptJoiner`，同源复用）。
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || TranscriptJoiner.isCJK(character)
    }
}
