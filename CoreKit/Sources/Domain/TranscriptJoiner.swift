import Foundation

/// 转写显示文本的统一拼接（结构轮 2026-09-15，A4 审查 F4）：
/// 此前两轨各写一套——基线轨（SFSpeechTranscriber / `TranscriptSessionAccumulator`）
/// 用 `joined(separator: " ")`（中文段之间也被插空格），平台轨
/// （`AnalyzerSession`）用 CJK 感知拼接——**同一句话在不同引擎上显示不同**。
/// 现收敛为单点：CJK 直接相接（中文排版规范，句内不加空格）；
/// 相邻两侧都是拉丁字母/数字时补一个空格（英文短语边界可读性）。
public enum TranscriptJoiner {

    public static func join(_ segments: [String]) -> String {
        var output = ""
        for segment in segments where !segment.isEmpty {
            if let last = output.last, let first = segment.first,
               last.isLetter || last.isNumber, first.isLetter || first.isNumber {
                let lastIsCJK = last.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let firstIsCJK = first.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                if !lastIsCJK && !firstIsCJK { output.append(" ") }
            }
            output.append(segment)
        }
        return output
    }
}
