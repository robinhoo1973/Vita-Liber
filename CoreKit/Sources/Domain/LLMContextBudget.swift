import Foundation

/// T2 本机 LLM 上下文窗口预算（纯函数，Linux 可测；2026-10-09 换型批）。
///
/// 背景：Qwen3-0.6B 的 KV 占用为 28 层×8 KV 头×head_dim 128 ⇒ 112 KiB/token
/// （现役 Qwen2.5-0.5B 的 9.3×）——n_ctx=4096 在 f16 下 KV 即 448 MB，叠加
/// 权重（mmap 峰值 ≈1.3×）可把 3GB 机型推过 jetsam。故：
/// 1. 发货默认 n_ctx=3072 + KV q8_0（占用 ≈178 MiB）；
/// 2. 仅当资源探针给出余量时自动升档 4096；
/// 3. 探针不可用（nil）fail-**保守**：返回默认档（不同于
///    `ModelMemoryBudget.verdict` 的 fail-open——那是"能否加载"，这里是
///    "能开多大"，未知时取更小者不损正确性、只损一点上下文余量）。
///
/// 与 `ModelMemoryBudget` 的分工：后者管「这份权重要不要加载」，本函数管
/// 「加载时开多大的 KV」。峰值公式复用同一系数（llamaPeakFactor）。
public enum LLMContextBudget {
    /// 候选档位（降序尝试）。
    public static let candidateNCtx: [Int] = [4096, 3072, 2048]
    /// 发货默认档（探针不可用/全部超预算时的确定值）。
    public static let defaultNCtx = 3072

    /// Qwen3-0.6B 的 KV 单 token 字节数（q8_0 ≈ 34/32 块开销后的近似整数值；
    /// 定标依据：2(K·V) × 28 层 × 8 KV 头 × 128 head_dim × 1.0625(块)＝112 KiB）。
    public static let qwen3KVBytesPerToken: Int64 = 112 * 1024

    /// 选定 n_ctx：从大到小取第一个满足「权重峰值 + KV×n + 计算缓冲 ≤ 可用」的档；
    /// 探针 nil → 默认档；全部不满足 → 最小档（调用侧再由 verdict 做加载许可判定，
    /// 本函数只缩小窗口、不拒绝加载）。
    public static func nCtx(availableBytes: Int64?, modelBytes: Int64,
                            kvBytesPerToken: Int64 = qwen3KVBytesPerToken,
                            computeBufferBytes: Int64 = 96 * 1_024 * 1_024) -> Int {
        guard let available = availableBytes else { return defaultNCtx }
        let weightsPeak = ModelMemoryBudget.peakBytes(modelBytes: modelBytes,
                                                      peakFactor: ModelMemoryBudget.llamaPeakFactor)
        for n in candidateNCtx
        where weightsPeak + Int64(n) * kvBytesPerToken + computeBufferBytes <= available {
            return n
        }
        return candidateNCtx.last ?? defaultNCtx
    }
}
