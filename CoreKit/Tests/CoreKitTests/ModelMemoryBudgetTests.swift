import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// round5 Q3（业主 2026-09-20 第 3 项：下载 ASR 进入录音即闪退、随后整机变慢）：GB 级模型加载此前**无内存预算门**，
/// sherpa-onnx 整模读入内存再建 ORT 会话（峰值≈2× 体积），超 jetsam 限即被系统终止（无崩溃日志的「闪退」）。
/// `ModelMemoryBudget` 是加载前的纯策略；`LoadAttemptMarker` 是崩溃环断路（上次加载未完成 → 本次不自动预热）。
@Suite("SU-M15-VOICE · 模型内存预算与崩溃环断路")
struct ModelMemoryBudgetTests {
    let gb: Int64 = 1_024 * 1_024 * 1_024
    let mb: Int64 = 1_024 * 1_024

    @Test func insufficientWhenPeakExceedsAvailable() {
        // qwen3 medium ≈ 989MB → 峰值 ≈ 2× + 200MB 余量 ≈ 2.13GB；可用 1.5GB → 不足
        let verdict = ModelMemoryBudget.verdict(modelBytes: 989_361_644, availableBytes: 1_500 * mb)
        #expect(verdict == .insufficient(requiredBytes: ModelMemoryBudget.peakBytes(modelBytes: 989_361_644), availableBytes: 1_500 * mb))
    }

    @Test func okWhenComfortablyWithinBudget() {
        #expect(ModelMemoryBudget.verdict(modelBytes: 200 * mb, availableBytes: 2 * gb) == .ok)
    }

    @Test func tightWhenWithinBudgetButBelowPreloadHeadroom() {
        // 够加载、但预热后余量 < 预热门槛 → tight：按压时再载，不在面板打开时抢占
        let model = 989_361_644 as Int64
        let peak = ModelMemoryBudget.peakBytes(modelBytes: model)
        let available = peak + ModelMemoryBudget.preloadHeadroomBytes / 2
        #expect(ModelMemoryBudget.verdict(modelBytes: model, availableBytes: available) == .tight)
    }

    @Test func peakFormulaIsFactorPlusHeadroom() {
        #expect(ModelMemoryBudget.peakBytes(modelBytes: 1_000) == Int64(Double(1_000) * ModelMemoryBudget.loadPeakFactor) + ModelMemoryBudget.baseHeadroomBytes)
    }

    @Test func extraBytesAddsKVToPeakAndVerdict() {
        // 2026-10-09 换型批：KV cache 显式加项（llama 系数只覆盖权重 mmap，不含 KV）。
        let base = ModelMemoryBudget.peakBytes(modelBytes: 1_000)
        #expect(ModelMemoryBudget.peakBytes(modelBytes: 1_000, extraBytes: 448 * mb) == base + 448 * mb)
        // 恰好卡在边界：无 KV 时 ok，加 KV 后不足 —— verdict 必须把 KV 计入
        let available = base + ModelMemoryBudget.preloadHeadroomBytes + 10 * mb
        #expect(ModelMemoryBudget.verdict(modelBytes: 1_000, availableBytes: available, extraBytes: 0).allowsLoad)
        #expect(!ModelMemoryBudget.verdict(modelBytes: 1_000, availableBytes: available, extraBytes: 448 * mb).allowsLoad)
        // 负值按 0 处理（防御性）
        #expect(ModelMemoryBudget.peakBytes(modelBytes: 1_000, extraBytes: -5) == base)
    }

    @Test func unknownAvailabilityNeverBlocks() {
        // 探针不可用（nil）→ 不拒绝（fail-open 只对「未知」，不对「已知不足」）
        #expect(ModelMemoryBudget.verdict(modelBytes: 5 * gb, availableBytes: nil) == .ok)
    }

    @Test func allowsPreloadOnlyWhenOk() {
        #expect(ModelMemoryBudget.Verdict.ok.allowsPreload)
        #expect(!ModelMemoryBudget.Verdict.tight.allowsPreload)
        #expect(!ModelMemoryBudget.Verdict.insufficient(requiredBytes: 1, availableBytes: 0).allowsPreload)
        #expect(ModelMemoryBudget.Verdict.tight.allowsLoad)
        #expect(!ModelMemoryBudget.Verdict.insufficient(requiredBytes: 1, availableBytes: 0).allowsLoad)
    }

    // MARK: 崩溃环断路（纯策略：标记是否指向「上次同一模型加载未完成」）

    @Test func markerDetectsInterruptedLoadOfSameModel() {
        let marker = LoadAttemptMarker(identity: "qwen3:medium:abc", startedAt: Date(timeIntervalSince1970: 100))
        #expect(marker.indicatesInterruptedLoad(of: "qwen3:medium:abc"))
        #expect(!marker.indicatesInterruptedLoad(of: "whisper:small:xyz"))
    }

    @Test func markerRoundTripsThroughData() throws {
        let marker = LoadAttemptMarker(identity: "zipformer:large:1", startedAt: Date(timeIntervalSince1970: 42))
        let data = try marker.encoded()
        #expect(LoadAttemptMarker.decode(data) == marker)
        #expect(LoadAttemptMarker.decode(Data("garbage".utf8)) == nil)
    }

    @Test func markerStoreBeginPersistsAndFinishClears() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vl-marker-\(UUID().uuidString)")
        let store = LoadAttemptMarkerStore(directory: dir)
        #expect(store.current() == nil)
        store.begin(identity: "qwen3:medium:abc")
        #expect(store.current()?.identity == "qwen3:medium:abc", "加载前落盘——被系统终止后下次启动仍可读到")
        store.finish()
        #expect(store.current() == nil, "加载成功即清除")
        store.finish()   // 幂等
        #expect(store.current() == nil)
    }

    @Test func availabilityProbeIsNilOffiOS() {
        // 2026-09-27 委员会 D3：原 #if os(iOS) 分支在全部真实执行面（macOS runner
        // swift test + 本机 Linux）都死——CoreKitTests 不进 scheme（project.yml:103），
        // 死分支是假证据（读者以为 iOS 行为已被断言）。ProcessMemory.swift:14-19
        // os_proc_available_memory 仅 iOS；非 iOS 恒 nil → 策略 fail-open（未知不拒）。
        #expect(ProcessMemory.availableBytes() == nil)
    }

    /// 2026-10-05 业主反馈修复批（第 8 项）：首个可载候选按传入优先序。
    @Test func firstLoadableIndexFollowsPriorityOrder() {
        // 大档不足 → 跳过；中档可载 → 中档
        #expect(ModelMemoryBudget.firstLoadableIndex(
            modelBytes: [3 * gb, 500 * mb, 200 * mb], availableBytes: 2 * gb) == 1)
        // 探针不可用 fail-open：首个候选
        #expect(ModelMemoryBudget.firstLoadableIndex(
            modelBytes: [3 * gb, 500 * mb], availableBytes: nil) == 0)
        // 全不足 → nil（调用方决定回落基线轨或如实报错）
        #expect(ModelMemoryBudget.firstLoadableIndex(
            modelBytes: [3 * gb, 4 * gb], availableBytes: 2 * gb) == nil)
        #expect(ModelMemoryBudget.firstLoadableIndex(modelBytes: [], availableBytes: 2 * gb) == nil)
    }

    /// 2026-10-05 业主反馈修复批（第 9 项）：推荐 = 可装最大档。
    @Test func largestLoadableIndexPrefersBiggestLoadable() {
        // 大档可载 → 大档
        #expect(ModelMemoryBudget.largestLoadableIndex(
            modelBytes: [200 * mb, 500 * mb, 900 * mb], availableBytes: 4 * gb) == 2)
        // 大档不足（900mb 峰值 ≈2.10GB > 1.93GB）、中档可载（500mb 峰值 ≈1.26GB）→ 中档
        #expect(ModelMemoryBudget.largestLoadableIndex(
            modelBytes: [200 * mb, 500 * mb, 900 * mb], availableBytes: 18 * gb / 10) == 1)
        // 全不足 → nil
        #expect(ModelMemoryBudget.largestLoadableIndex(
            modelBytes: [3 * gb, 4 * gb], availableBytes: 2 * gb) == nil)
        // 探针不可用 fail-open：最大下标（与 verdict 同语义；推荐层会改走 RAM 建议）
        #expect(ModelMemoryBudget.largestLoadableIndex(
            modelBytes: [200 * mb, 500 * mb, 900 * mb], availableBytes: nil) == 2)
    }
}
