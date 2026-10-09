import Foundation
import Testing
@testable import Domain

/// T2 上下文窗口预算（纯函数；2026-10-09 换型批）。
/// 档位阈值（精确字节，常量推导）：2048 档需 ≥ 1_060_976_633；3072 档需 ≥ 1_178_417_145；
/// 4096 档需 ≥ 1_295_857_657（权重峰值 725_432_313 + KV×n + 缓冲 100_663_296）。
@Suite("LLM 上下文预算（Domain）")
struct LLMContextBudgetTests {

    private let qwen3Bytes: Int64 = 396_705_472

    @Test func probeUnavailableFallsBackToDefault() {
        #expect(LLMContextBudget.nCtx(availableBytes: nil, modelBytes: qwen3Bytes) == 3072,
                "探针不可用 → 保守默认档（未知时取更小者不损正确性）")
    }

    @Test func tightDeviceGetsSmallestTier() {
        // 连 3072 档都装不下 → 最小档 2048（加载许可由 ModelMemoryBudget.verdict 另判）
        #expect(LLMContextBudget.nCtx(availableBytes: 1_150_000_000, modelBytes: qwen3Bytes) == 2048)
    }

    @Test func midDeviceStaysAt3072() {
        #expect(LLMContextBudget.nCtx(availableBytes: 1_200_000_000, modelBytes: qwen3Bytes) == 3072)
    }

    @Test func roomyDeviceUpgradesTo4096() {
        #expect(LLMContextBudget.nCtx(availableBytes: 1_400_000_000, modelBytes: qwen3Bytes) == 4096)
    }

    @Test func evenSmallestTierFailsStillReturnsFloor() {
        // 全部超预算：本函数只缩小窗口、不拒绝加载 → 返回最小档
        #expect(LLMContextBudget.nCtx(availableBytes: 900_000_000, modelBytes: qwen3Bytes) == 2048)
    }
}
