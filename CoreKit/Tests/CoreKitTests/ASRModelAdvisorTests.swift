import Foundation
import Testing
@testable import Domain

/// FR17.15 / 业主裁决 2026-11-04：主轨 = 硬件能力过滤 → 签名目录发布序；
/// 不是「最佳准确率」排序，且缺件绝不静默下载。
@Suite("ASR 主轨硬件优先选择")
struct ASRModelAdvisorTests {
    private static let index = ASRLanguageProtocolTests.fixtureIndex
    private static let gib: UInt64 = 1_024 * 1_024 * 1_024
    private static let mib: Int64 = 1_024 * 1_024

    private static func installed(_ choices: [VoiceEngineChoice],
                                  bytes: Int64? = Int64(gib)) -> ASRInstalledAssets {
        ASRInstalledAssets(models: choices.map {
            ASRInstalledModel(choice: $0, bytes: bytes, version: "test", origin: .downloaded)
        })
    }

    private static func facts(physicalGiB: UInt64? = 8,
                              availableGiB: Double? = 8,
                              thermal: ASRHardwareFacts.Thermal = .nominal,
                              lowPower: Bool? = false,
                              storage: Int64? = nil) -> ASRHardwareFacts {
        ASRHardwareFacts(
            availableMemoryBytes: availableGiB.map { Int64($0 * Double(gib)) },
            physicalMemoryBytes: physicalGiB.map { $0 * gib },
            storageFreeBytes: storage,
            thermal: thermal,
            lowPowerMode: lowPower)
    }

    @Test func hardwareFilterThenCatalogOrderNotAccuracy() {
        // 三个候选都装、都可载：取目录 families 发布序首个（qwen3），不按体积/准确率重排。
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(),
            installed: Self.installed([.zipformer, .dolphin, .qwen3]), index: Self.index)
        #expect(advice.primary?.choice == .qwen3)
        #expect(advice.primary?.catalogPosition == 0)
        #expect(advice.ranked.map(\.choice) == [.qwen3, .zipformer, .dolphin])
        #expect(advice.execution == .appleSecondariesAfterCapture)
        #expect(advice.hasExpressibleCatalogCandidate)
    }

    @Test func missingCatalogPreferredFallsToNextInstalledCatalogEntry() {
        // qwen3 未装 → 不下载，按目录序落到已安装的 zipformer。
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(),
            installed: Self.installed([.dolphin, .zipformer]), index: Self.index)
        #expect(advice.primary?.choice == .zipformer)
        #expect(advice.ranked.map(\.choice) == [.zipformer, .dolphin])
        let qwen = advice.rejected.first { $0.choice == .qwen3 }
        #expect(qwen?.reason == .notInstalled)
        #expect(qwen?.requiresUserInitiatedDownload == true)
    }

    @Test func noInstalledModelNeverTriggersDownload() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(),
            installed: .empty, index: Self.index)
        #expect(advice.primary == nil)
        #expect(advice.hasExpressibleCatalogCandidate)
        #expect(advice.execution == .primaryOnly(reason: .noInstalledExpressibleModel))
        #expect(advice.rejected.allSatisfy {
            $0.reason == .notInstalled ? $0.requiresUserInitiatedDownload : true
        })
        #expect(advice.rejected.contains { $0.reason == .notInstalled && $0.requiresUserInitiatedDownload })
    }

    @Test func fourGiBAllowsExternalModelAndPostCaptureAppleSources() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(physicalGiB: 4, availableGiB: 3),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.hardwareTier == .standard)
        #expect(advice.primary?.choice == .zipformer)
        #expect(advice.execution == .appleSecondariesAfterCapture)
    }

    @Test func sixGiBIsLargeTierAndStillPostCapture() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(physicalGiB: 6, availableGiB: 5),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.hardwareTier == .large)
        #expect(advice.primary?.choice == .zipformer)
        #expect(advice.execution == .appleSecondariesAfterCapture)
    }

    @Test func eightGiBIsLargeTierAndStillPostCapture() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(physicalGiB: 8, availableGiB: 8),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.hardwareTier == .large)
        #expect(advice.execution == .appleSecondariesAfterCapture)
    }

    @Test func belowFourGiBIsCompactAndFailClosed() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN",
            hardware: Self.facts(physicalGiB: 4, availableGiB: 3, storage: nil),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.hardwareTier == .standard)   // 4GiB 恰为下限，仍是可载档
        #expect(advice.primary != nil)

        let three = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(physicalGiB: 3, availableGiB: 3),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(three.hardwareTier == .compact)
        #expect(three.primary == nil)
        #expect(three.rejected.contains { $0.reason == .belowMinimumPhysicalMemory })
        #expect(three.execution == .primaryOnly(reason: .hardwareIneligible))
    }

    @Test func unknownPhysicalMemoryFailsClosed() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN",
            hardware: Self.facts(physicalGiB: nil, availableGiB: 8),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.hardwareTier == .compact)
        #expect(advice.primary == nil)
        #expect(advice.warnings.contains(.physicalMemoryUnknown))
        #expect(advice.rejected.contains { $0.reason == .physicalMemoryUnknown })
        #expect(advice.execution == .primaryOnly(reason: .hardwareIneligible))
    }

    @Test func unknownAvailableMemoryFailsClosedEvenAtEightGiB() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN",
            hardware: Self.facts(physicalGiB: 8, availableGiB: nil),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.primary == nil)
        #expect(advice.warnings.contains(.availableMemoryUnknown))
        #expect(advice.rejected.contains { $0.reason == .availableMemoryUnknown })
        #expect(advice.execution == .primaryOnly(reason: .hardwareIneligible))
    }

    @Test func insufficientMemorySkipsCandidate() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN",
            hardware: Self.facts(physicalGiB: 8, availableGiB: 1),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.primary == nil)
        #expect(advice.rejected.contains { $0.reason == .insufficientMemory })
    }

    @Test func unknownInstalledBytesFailsClosed() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(),
            installed: Self.installed([.zipformer], bytes: nil), index: Self.index)
        #expect(advice.primary == nil)
        #expect(advice.rejected.contains { $0.reason == .installedBytesUnknown })
        #expect(advice.execution == .primaryOnly(reason: .hardwareIneligible))
    }

    @Test func tightBudgetLoadsButWarns() throws {
        let modelBytes = Int64(Self.gib)
        let required = ModelMemoryBudget.peakBytes(modelBytes: modelBytes)
        let available = required + 100 * Self.mib   // < preloadHeadroom 400 MiB → tight
        let hardware = ASRHardwareFacts(
            availableMemoryBytes: available,
            physicalMemoryBytes: 8 * Self.gib,
            storageFreeBytes: nil, thermal: .nominal, lowPowerMode: false)
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: hardware,
            installed: Self.installed([.zipformer]), index: Self.index)
        let primary = try #require(advice.primary)
        #expect(primary.budgetIsTight)
        #expect(advice.warnings.contains(.tightMemory))
    }

    @Test func unsupportedLocaleIsDistinguishedFromMissingOrHardware() {
        let advice = ASRModelAdvisor.advise(
            locale: "xx-XX", hardware: Self.facts(),
            installed: Self.installed([.qwen3, .whisper]), index: Self.index)
        #expect(advice.primary == nil)
        #expect(!advice.hasExpressibleCatalogCandidate)
        #expect(advice.execution == .primaryOnly(reason: .noExpressibleCatalogCandidate))
        #expect(advice.rejected.allSatisfy { $0.reason == .localeUnsupported })
    }

    @Test func mixedModeRequiresCoverageOfEverySelectedLocale() {
        // 只装 zipformer（仅 zh）+ dolphin（不含 en）→ 都不覆盖 zh+en；whisper 装则当选。
        let onlyPartial = ASRModelAdvisor.advise(
            locales: ["zh-Hans-CN", "en-US"], mode: .mixed, hardware: Self.facts(),
            installed: Self.installed([.zipformer, .dolphin]), index: Self.index)
        #expect(onlyPartial.primary == nil)
        #expect(onlyPartial.hasExpressibleCatalogCandidate)

        let withWhisper = ASRModelAdvisor.advise(
            locales: ["zh-Hans-CN", "en-US"], mode: .mixed, hardware: Self.facts(),
            installed: Self.installed([.zipformer, .dolphin, .whisper]), index: Self.index)
        #expect(withWhisper.primary?.choice == .whisper)
    }

    @Test func lowStorageWarnsWithoutSwitchingEngine() {
        let hardware = Self.facts(storage: 100 * Self.mib)
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: hardware,
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.primary?.choice == .zipformer)
        #expect(advice.warnings.contains(.lowFreeStorage))
    }

    @Test func thermalPressureWarnsWithoutChangingPostCapturePlan() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(thermal: .serious),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.primary?.choice == .zipformer)
        #expect(advice.execution == .appleSecondariesAfterCapture)
        #expect(advice.warnings.contains(.thermalConstrained))
    }

    @Test func unknownLowPowerModeDoesNotChangePostCapturePlan() {
        let advice = ASRModelAdvisor.advise(
            locale: "zh-Hans-CN", hardware: Self.facts(lowPower: nil),
            installed: Self.installed([.zipformer]), index: Self.index)
        #expect(advice.execution == .appleSecondariesAfterCapture)
    }

    @Test func appleSourcesAreFixedSecondAndThird() {
        let advice = ASRModelAdvisor.advise(
            locale: "en-US", hardware: Self.facts(),
            installed: Self.installed([.whisper]), index: Self.index)
        #expect(advice.appleSources.map(\.role) == [.secondAppleChinese, .thirdAppleEnglish])
        #expect(advice.appleSources.map(\.localeIdentifier) == ["zh-CN", "en-US"])
        #expect(advice.appleSources.allSatisfy { $0.requiresOnDeviceRecognition && !$0.allowsNetworkFallback })
    }
}
