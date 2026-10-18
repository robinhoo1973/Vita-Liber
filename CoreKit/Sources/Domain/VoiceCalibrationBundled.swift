import Foundation

/// B1 随包脚本金样定标（2026-10-18，tech ADR-035 / G17）。
///
/// 语料随 Domain 资源打包（`Resources/scripted-calibration.json`，60 条：
/// metric/reminder/profile 各 20）。App 启动时调用一次——用与生产相同的
/// 文法引擎跑 `evaluateDeterministic`，达标才把 `voiceDeterministicEnabled`
/// 置真；缺件/不达标保持关闭（fail-closed，release 入口随默认隐藏）。
///
/// 这与 B2 模型轨的 ≥500 条真人语料是两条独立放行线：
/// B1 只声明「确定性文法在脚本金样上达标」，不声明真人识别准确率。
public enum VoiceCalibrationBundled {

    public static func corpus() -> VoiceCalibration.Corpus? {
        guard let url = Bundle.module.url(forResource: "scripted-calibration",
                                          withExtension: "json"),
              let data = try? Data(contentsOf: url), // try?-ok: 资源缺失=未定标（fail-closed）
              let corpus = try? JSONDecoder().decode(VoiceCalibration.Corpus.self, from: data) // try?-ok: 语料损坏=未定标
        else { return nil }
        return corpus
    }

    /// 跑随包脚本定标并回写 B1 flag。返回报告（缺件时 nil）。
    @discardableResult
    public static func apply() -> VoiceCalibration.DeterministicReport? {
        guard let corpus = corpus() else { return nil }
        let report = VoiceCalibration.evaluateDeterministic(corpus: corpus) { sample in
            let drafts: [FieldDraft]
            switch sample.kind {
            case "metric":
                drafts = VoiceStructuringEngine.extractMetric(
                    sample.transcript, rules: VoiceGrammarDefaults.metricRules)
            case "reminder":
                drafts = VoiceStructuringEngine.extractReminder(
                    sample.transcript, rules: VoiceGrammarDefaults.reminderRules)
            case "profile":
                drafts = VoiceStructuringEngine.extractProfile(
                    sample.transcript, rules: VoiceGrammarDefaults.profileRules)
            default:
                drafts = []
            }
            var output: [String: String] = [:]
            for draft in drafts { output[draft.key] = draft.value }
            return output
        }
        FeatureFlags.applyDeterministicCalibration(report)
        return report
    }
}
