import Foundation

/// 字符错误率（Levenshtein / 参考长度）。用途：① Stage 0 识别评测；② `OCRConsensus` 一致率。
/// 按 `Character`（扩展字形簇）计，CJK 与拉丁同权；纯函数、确定性。
/// ADR-025 经审查无可用实现：Foundation / GRDB / swift-algorithms 均无编辑距离 API，
/// 故自研本类型（O(n·m) 双行滚动数组，行 ≤60 字场景成本可忽略）。
public enum CharacterErrorRate {
    public static func distance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    /// 参考为空：假设也为空 → 0，否则 1（避免除零且如实记全错）。
    public static func rate(reference: String, hypothesis: String) -> Double {
        let n = reference.count
        guard n > 0 else { return hypothesis.isEmpty ? 0 : 1 }
        return Double(distance(reference, hypothesis)) / Double(n)
    }
}
