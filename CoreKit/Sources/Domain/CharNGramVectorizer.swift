import Foundation

/// 行级字段分类器的**端侧特征向量**（2026-11-07）。
///
/// Core ML 9 的 sklearn 转换器不再支持 `TfidfVectorizer`，训练侧改为
/// 「字符 n-gram 哈希 → 固定维稠密向量 → 线性分类器（GLMClassifier）」。
/// 本文件是训练（Python）与推理（Swift）共用的**唯一**向量化定义：
///
/// - NFKC 折叠 + 小写；
/// - 单字/双字/三字 n-gram（Unicode 标量序列，CJK 与 ASCII 同一规则）；
/// - FNV-1a 64 位哈希取模 `dimension`，计数累加；
/// - 卡类令牌 `<k:kind>` 作为一条独立特征；
/// - 全向量 L2 归一化（长行不因长度占优）。
///
/// 训练脚本 `scanned_coreml_train.py` 用同一算法生成特征；任何改动必须
/// 同时升级 catalog 的 `featureVersion` 并重训。
public enum CharNGramVectorizer {
    public static let version = "char-ngram-fnv1a-v1"

    /// FNV-1a 64 位（UTF-8 字节）。
    public static func hash(_ text: String, dimension: Int) -> Int {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return Int(value % UInt64(dimension))
    }

    /// 特征向量；维度由 catalog 固定，输出已 L2 归一化。
    public static func vector(text: String, kind: String?, dimension: Int) -> [Double] {
        guard dimension > 0 else { return [] }
        var out = [Double](repeating: 0, count: dimension)
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let scalars = Array(normalized.unicodeScalars)
        if !scalars.isEmpty {
            let maxN = min(3, scalars.count)
            for n in 1...maxN {
                var index = 0
                while index + n <= scalars.count {
                    let gram = String(String.UnicodeScalarView(scalars[index..<(index + n)]))
                    out[hash(gram, dimension: dimension)] += 1
                    index += 1
                }
            }
        }
        if let kind, !kind.isEmpty {
            out[hash("<k:\(kind)>", dimension: dimension)] += 1
        }
        var norm = 0.0
        for value in out { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0 else { return out }
        for index in out.indices { out[index] /= norm }
        return out
    }
}
