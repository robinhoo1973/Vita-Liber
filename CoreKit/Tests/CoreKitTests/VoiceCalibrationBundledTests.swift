import Foundation
import Testing
@testable import Domain

// binds: SU-M15-VOICE
/// B1 随包脚本金样（G17）：60 条必须可加载、可评估、达到放行线并点亮 flag。
@Suite("SU-M15-VOICE · B1 随包脚本定标")
struct VoiceCalibrationBundledTests {

    @Test("随包脚本金样 60 条达标并点亮 B1")
    func bundledScriptedCorpusPasses() {
        defer {
            FeatureFlags.applyDeterministicCalibration(
                VoiceCalibration.DeterministicReport(sampleCount: 0, numericAccuracy: 0, structureRate: 0))
        }
        guard let corpus = VoiceCalibrationBundled.corpus() else {
            Issue.record("随包脚本语料缺失")
            return
        }
        #expect(corpus.samples.count == VoiceCalibration.requiredScriptedSamples)
        let report = VoiceCalibrationBundled.apply()
        #expect(report?.sampleCount == 60)
        #expect(report?.structureRate == 1.0, "脚本金样必须逐条全对（当前 \(report?.structureRate ?? 0)）")
        #expect(report?.numericAccuracy == 1.0)
        #expect(FeatureFlags.voiceDeterministicEnabled)
    }
}
