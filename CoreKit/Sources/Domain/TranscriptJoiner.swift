import Foundation

/// 转写显示文本的统一拼接（结构轮 2026-09-15，A4 审查 F4）：
/// 此前两轨各写一套——基线轨（SFSpeechTranscriber / `TranscriptSessionAccumulator`）
/// 用 `joined(separator: " ")`（中文段之间也被插空格），平台轨
/// （`AnalyzerSession`）用 CJK 感知拼接——**同一句话在不同引擎上显示不同**。
/// 现收敛为单点：CJK 直接相接（中文排版规范，句内不加空格）；
/// 相邻两侧都是拉丁字母/数字时补一个空格（英文短语边界可读性）。
public enum TranscriptJoiner {

    /// 全仓唯一 CJK 边界定义（`TextLineMerger` 同源复用）。审查修复：
    /// 旧区间只覆盖基本区（0x4E00...0x9FFF）——扩展 A（U+3400–4DBF）
    /// 与扩展 B+（U+20000+）的罕见姓氏/生僻字在段边界被判「非 CJK」，
    /// 中文句中被插空格。
    public static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }

    public static func join(_ segments: [String]) -> String {
        var output = ""
        for segment in segments where !segment.isEmpty {
            if let last = output.last, let first = segment.first,
               last.isLetter || last.isNumber, first.isLetter || first.isNumber {
                if !isCJK(last) && !isCJK(first) { output.append(" ") }
            }
            output.append(segment)
        }
        return output
    }
}
