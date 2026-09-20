import Foundation

/// 多段值（`\n` 分段的叙事折行）的续行校验单点（round4 P-7：此前 T3 `OCRGrounding.fields` 与 T2
/// `ModelSpanAssembler.grounded` 各写一份，已分叉出 D-1）。
///
/// 纪律（BR-002 不摘要不截断）：第 i ≥ 1 段 **trim 后必须等于** `lines[start + i]` trim 后——整行 verbatim、
/// 严格相邻；任一段不满足即整个 span 作废（返回 nil），绝不拼半截。首段语义由调用方决定
///（T3：整行或标签剥离值；T2：行内子串），本类型只管续行。
public enum MultilineSpan {
    /// 按 `\n` 切段并 trim；不足两段或含空段 → nil（单行值不走本路径）。
    public static func segments(of value: String) -> [String]? {
        let parts = value.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts
    }

    /// 续段（下标 1…）逐一对齐 `lines[start + i]`（整行 verbatim、相邻）；全部成立 → 续行行号数组，否则 nil。
    public static func continuationLineIndices(segments: [String], start: Int, lines: [String]) -> [Int]? {
        guard segments.count >= 2 else { return nil }
        var indices: [Int] = []
        for (offset, segment) in segments.dropFirst().enumerated() {
            let lineIndex = start + offset + 1
            guard lines.indices.contains(lineIndex),
                  lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines) == segment else { return nil }
            indices.append(lineIndex)
        }
        return indices
    }
}
