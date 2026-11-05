import Foundation
import Testing
@testable import Domain

/// Apple 第二/第三源策略 + 三源文本合同（无媒体持久化）。
@Suite("ASR Apple 副源与三源文本合同")
struct ASRSourceContractTests {
    private static let factsAuthorized = ASRAppleSourceAvailabilityFacts(
        authorization: .authorized,
        recognizerAvailableLocales: ["zh-CN", "en-US"],
        onDeviceCapableLocales: ["zh-CN", "en-US"])

    @Test func catalogIsFixedChineseSecondEnglishThird() {
        #expect(ASRAppleSourceCatalog.sources.map(\.role) == [.secondAppleChinese, .thirdAppleEnglish])
        #expect(ASRAppleSourceCatalog.secondSource.localeIdentifier == "zh-CN")
        #expect(ASRAppleSourceCatalog.thirdSource.localeIdentifier == "en-US")
        #expect(ASRAppleSourceCatalog.secondSource.engineID == "apple-zh-CN")
        #expect(ASRAppleSourceCatalog.thirdSource.engineID == "apple-en-US")
        #expect(ASRAppleSourceCatalog.sources.allSatisfy {
            $0.requiresOnDeviceRecognition && !$0.allowsNetworkFallback
        })
    }

    @Test func readinessRequiresAuthorizationAndOnDeviceSupport() {
        let zh = ASRAppleSourceCatalog.secondSource
        #expect(ASRAppleSourcePolicy.readiness(of: zh, facts: Self.factsAuthorized) == .ready)

        var notDetermined = Self.factsAuthorized
        notDetermined.authorization = .notDetermined
        #expect(ASRAppleSourcePolicy.readiness(of: zh, facts: notDetermined)
                == .requiresAuthorizationPrompt)

        var denied = Self.factsAuthorized
        denied.authorization = .denied
        #expect(ASRAppleSourcePolicy.readiness(of: zh, facts: denied)
                == .unavailable(.authorizationDenied))

        var restricted = Self.factsAuthorized
        restricted.authorization = .restricted
        #expect(ASRAppleSourcePolicy.readiness(of: zh, facts: restricted)
                == .unavailable(.authorizationRestricted))
    }

    @Test func onDeviceUnsupportedIsSkippedNeverNetworkFallback() {
        let en = ASRAppleSourceCatalog.thirdSource
        var facts = Self.factsAuthorized
        facts.onDeviceCapableLocales = ["zh-CN"]
        #expect(ASRAppleSourcePolicy.readiness(of: en, facts: facts)
                == .unavailable(.onDeviceUnsupported))

        var unsupported = Self.factsAuthorized
        unsupported.recognizerAvailableLocales = ["en-US"]
        #expect(ASRAppleSourcePolicy.readiness(of: ASRAppleSourceCatalog.secondSource, facts: unsupported)
                == .unavailable(.localeUnsupported))
    }

    @Test func planRunsBothWhenAuthorizedAndCapable() {
        let plan = ASRAppleSourcePolicy.plan(
            primaryEngineID: "qwen3", primaryLocale: "zh-Hans-CN", facts: Self.factsAuthorized)
        #expect(plan.runs.map(\.role) == [.secondAppleChinese, .thirdAppleEnglish])
        #expect(plan.skipped.isEmpty)
        #expect(!plan.requiresAuthorizationPrompt)
    }

    @Test func planRequestsAuthorizationOnceInsteadOfSilentlySkippingForever() {
        var facts = Self.factsAuthorized
        facts.authorization = .notDetermined
        let plan = ASRAppleSourcePolicy.plan(primaryEngineID: "qwen3",
                                             primaryLocale: "zh-Hans-CN", facts: facts)
        #expect(plan.runs.isEmpty)
        #expect(plan.requiresAuthorizationPrompt)
        #expect(plan.skipped.count == 2)
        #expect(plan.skipped.allSatisfy { $0.reason == .authorizationNotDetermined })
    }

    @Test func planSkipsAppleSourceDuplicatingClassicPrimary() {
        let plan = ASRAppleSourcePolicy.plan(
            primaryEngineID: "classic:zh-Hans-CN", primaryLocale: "zh-Hans-CN",
            facts: Self.factsAuthorized)
        #expect(plan.runs.map(\.role) == [.thirdAppleEnglish])
        #expect(plan.skipped.map(\.reason) == [.duplicateOfPrimaryClassic])
    }

    @Test func threeSourceAssemblyKeepsAllRolesAndFeedsFusionInFixedOrder() {
        let primary = TranscriptionHypothesis(
            engineID: "qwen3", localeIdentifier: "zh-Hans-CN", text: "我头痛三天了")
        let result = TranscriptionResult(
            text: "我头痛三天了", confidence: 0.9, resolvedLocale: "zh-Hans-CN",
            segmented: false, engineID: "qwen3", hypotheses: [primary])
        let chinese = ASRAppleSourceResult(
            source: ASRAppleSourceCatalog.secondSource, status: .recognized, elapsedMs: 12,
            hypothesis: TranscriptionHypothesis(
                engineID: "apple-zh-CN", localeIdentifier: "zh-CN", text: "我头痛三天了"))
        let english = ASRAppleSourceResult(
            source: ASRAppleSourceCatalog.thirdSource, status: .recognized, elapsedMs: 18,
            hypothesis: TranscriptionHypothesis(
                engineID: "apple-en-US", localeIdentifier: "en-US", text: "headache for three days"))

        let set = ASRThreeSourceHypotheses.assemble(
            primary: result, primarySourceGroup: "sherpa", apples: [english, chinese])
        #expect(set.isComplete)
        #expect(set.sources.count == 3)
        #expect(set.sources.map(\.role) == [.primary, .secondAppleChinese, .thirdAppleEnglish])

        let input = set.fusionInput()
        #expect(input?.primary.text == "我头痛三天了")
        #expect(input?.secondaries.map(\.engineID) == ["apple-zh-CN", "apple-en-US"])

        let segment = set.debugSegment()
        #expect(segment.hypotheses.count == 3)
        #expect(segment.hypotheses.first?.role == .primary)
        #expect(segment.hypotheses.dropFirst().allSatisfy { $0.role == .secondary })
    }

    @Test func missingAppleResultsBecomeSkippedPlaceholdersNotFabricatedVotes() {
        let result = TranscriptionResult(
            text: "hello", confidence: 0.5, resolvedLocale: "en-US", segmented: false,
            engineID: "whisper",
            hypotheses: [TranscriptionHypothesis(engineID: "whisper",
                                                 localeIdentifier: "en-US", text: "hello")])
        let set = ASRThreeSourceHypotheses.assemble(primary: result, primarySourceGroup: "sherpa",
                                                    apples: [])
        #expect(set.isComplete)
        #expect(set.source(for: .secondAppleChinese)?.status == .skipped)
        #expect(set.source(for: .secondAppleChinese)?.reason == "not-run")
        #expect(set.fusionInput()?.secondaries.isEmpty == true)
    }

    @Test func fusionDelegatesToTextOnlyReviewOnlyByDefault() {
        let set = Self.sampleSet()
        let fused = set.fuse(calibration: .empty)
        #expect(fused?.text == "我头痛三天了")
        #expect(fused?.fallback == .calibrationNotReleased)
        #expect(fused?.edits.isEmpty == true)
    }

    @Test func textEvidenceJSONHasNoMediaOrPathFields() throws {
        let evidence = Self.sampleSet().textEvidence()
        #expect(evidence.count == 3)
        let data = try JSONEncoder().encode(evidence)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                keys.formUnion(dictionary.keys.map { $0.lowercased() })
                dictionary.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        object.forEach(collect)
        for forbidden in ["audio", "media", "url", "path", "image", "base64", "waveform"] {
            #expect(!keys.contains(where: { $0.contains(forbidden) }))
        }
        #expect(keys.contains("text"))
        #expect(keys.contains("engineid"))
    }

    private static func sampleSet() -> ASRThreeSourceHypotheses {
        let primary = TranscriptionHypothesis(
            engineID: "qwen3", localeIdentifier: "zh-Hans-CN", text: "我头痛三天了")
        let result = TranscriptionResult(
            text: "我头痛三天了", confidence: 0.9, resolvedLocale: "zh-Hans-CN",
            segmented: false, engineID: "qwen3", hypotheses: [primary])
        return ASRThreeSourceHypotheses.assemble(
            primary: result, primarySourceGroup: "sherpa",
            apples: [
                ASRAppleSourceResult(
                    source: ASRAppleSourceCatalog.secondSource, status: .recognized,
                    hypothesis: TranscriptionHypothesis(engineID: "apple-zh-CN",
                                                        localeIdentifier: "zh-CN", text: "我头痛三天了")),
                ASRAppleSourceResult(
                    source: ASRAppleSourceCatalog.thirdSource, status: .recognized,
                    hypothesis: TranscriptionHypothesis(engineID: "apple-en-US",
                                                        localeIdentifier: "en-US",
                                                        text: "headache for three days")),
            ])
    }
}

#if os(iOS) || os(macOS)
import Speech
@testable import Infrastructure

/// macOS CI 可编译的 Apple 适配器映射（Linux 无 Speech 框架）。
@Suite("ASR Apple 适配器系统映射")
struct ASRAppleAdapterMappingTests {
    @Test func authorizationStatusMapping() {
        #expect(AppleSpeechSourceAdapter.map(.authorized) == .authorized)
        #expect(AppleSpeechSourceAdapter.map(.denied) == .denied)
        #expect(AppleSpeechSourceAdapter.map(.restricted) == .restricted)
        #expect(AppleSpeechSourceAdapter.map(.notDetermined) == .notDetermined)
    }
}
#endif
