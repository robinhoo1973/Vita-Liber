import Foundation
import Testing
@testable import Domain

/// 业主 2026-11-05：启动时按硬件预载 ASR 主轨；未知/紧张状态一律不抢占。
@Suite("SU-M15-ASRPRELOAD · ASR 启动预载策略")
struct ASRStartupPreloadPolicyTests {
    private static let locale = "zh-Hans-CN"

    private static func advice(primary: ASRModelCandidate?,
                              mode: TranscriptionLanguageMode = .single) -> ASRModelAdvice {
        ASRModelAdvice(
            locale: locale,
            languageMode: mode,
            hardwareTier: .standard,
            primary: primary,
            ranked: primary.map { [$0] } ?? [],
            rejected: [],
            appleSources: ASRAppleSourceCatalog.sources,
            execution: primary == nil
                ? .primaryOnly(reason: .noInstalledExpressibleModel)
                : .sequentialAppleSecondaries(reason: .belowParallelHardwareTier),
            warnings: [],
            hasExpressibleCatalogCandidate: primary != nil)
    }

    private static func hardware(thermal: ASRHardwareFacts.Thermal = .nominal,
                                 lowPower: Bool? = false) -> ASRHardwareFacts {
        ASRHardwareFacts(availableMemoryBytes: 2_000_000_000,
                         physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
                         storageFreeBytes: 4_000_000_000,
                         thermal: thermal,
                         lowPowerMode: lowPower)
    }

    private static let candidate = ASRModelCandidate(
        choice: .zipformer, catalogPosition: 0, installedBytes: 500_000_000,
        budgetIsTight: false)

    @Test("可加载主轨 + 热/电量正常 → 预载该档位与 locale")
    func preloadsWhenSafe() {
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: Self.candidate),
            hardware: Self.hardware()) == .preload(choice: .zipformer, locale: Self.locale))
    }

    @Test("无主轨 → 不预载")
    func skipsWithoutPrimary() {
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: nil),
            hardware: Self.hardware()) == .skip(.noPrimaryModel))
    }

    @Test("混说模式 → 不预载（warmUp 端口只接受单一 locale）")
    func skipsMixedMode() {
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: Self.candidate, mode: .mixed),
            hardware: Self.hardware()) == .skip(.mixedLanguageMode))
    }

    @Test("内存余量紧 → 不预载")
    func skipsTightBudget() {
        let tight = ASRModelCandidate(choice: .zipformer, catalogPosition: 0,
                                      installedBytes: 500_000_000, budgetIsTight: true)
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: tight),
            hardware: Self.hardware()) == .skip(.memoryBudgetTight))
    }

    @Test("热 serious/critical/未知 → 不预载")
    func skipsConstrainedThermal() {
        for thermal in [ASRHardwareFacts.Thermal.serious, .critical, .unknown] {
            #expect(ASRStartupPreloadPolicy.decide(
                advice: Self.advice(primary: Self.candidate),
                hardware: Self.hardware(thermal: thermal)) == .skip(
                    thermal == .unknown ? .thermalUnknown : .thermalConstrained))
        }
    }

    @Test("低电量开启/未知 → 不预载；关闭 → 预载")
    func lowPowerGate() {
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: Self.candidate),
            hardware: Self.hardware(lowPower: true)) == .skip(.lowPowerMode))
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: Self.candidate),
            hardware: Self.hardware(lowPower: nil)) == .skip(.lowPowerModeUnknown))
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: Self.candidate),
            hardware: Self.hardware(lowPower: false)) == .preload(
                choice: .zipformer, locale: Self.locale))
    }

    @Test("热 fair + 电量关闭 → 允许预载")
    func fairThermalAllowsPreload() {
        #expect(ASRStartupPreloadPolicy.decide(
            advice: Self.advice(primary: Self.candidate),
            hardware: Self.hardware(thermal: .fair, lowPower: false)) == .preload(
                choice: .zipformer, locale: Self.locale))
    }
}
