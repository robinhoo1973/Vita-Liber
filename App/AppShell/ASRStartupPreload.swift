import Foundation
import os
import Domain
import Infrastructure
import Protocols

/// 启动时按硬件预载 ASR 主轨（2026-11-05 业主目标）。
///
/// 只做后台 `warmUp`：不联网、不下载、不采音、不阻塞启动/门禁。
/// 是否预热由 `ASRStartupPreloadPolicy` 决定；安装/字节/内存过滤已在
/// `ASRModelAdvisor` 完成，`warmUp` 只对已安装资产生效。
@MainActor
enum ASRStartupPreload {
    private static let logger = Logger(subsystem: "com.vitaliber", category: "asr-preload")

    static func run(engine: any TranscriptionEngine, settings: AppSettingsStore) async {
        // 只有 auto 档按硬件选主轨；显式档位由用户在语音面板/按压路径决定，
        // 启动期不替用户换模型（warmUp 对显式档也无预热语义）。
        guard VoiceEngineChoice.resolve(settings.values[.voiceEngine]) == .auto else {
            logger.debug("ASR 启动预载跳过: explicit-engine")
            return
        }
        let allLocales = SettingsRules.voiceLocales(settings.values[.voiceInputLanguages])
        let mixed = SettingsRules.resolved(settings.values[.voiceMixedInput],
                                           key: .voiceMixedInput) == "true"
        // 单语只按首语言选主轨；把全部已选语言一起喂给单语 advisor 会
        // 误判「无候选」（实际按压只用首语言）。
        let locales = mixed ? allLocales : Array(allLocales.prefix(1))
        let hardware = ASRAdvisorInputsProbe.hardwareFacts()
        let advice = TranscriptionEngineBuilder.advice(
            locales: locales, mode: mixed ? .mixed : .single)

        switch ASRStartupPreloadPolicy.decide(advice: advice, hardware: hardware) {
        case .skip(let reason):
            logger.debug("ASR 启动预载跳过: \(reason.rawValue, privacy: .public)")
        case .preload(let choice, let locale):
            let warmed = await engine.warmUp(locale)
            logger.debug("ASR 启动预载 \(choice.rawValue, privacy: .public) \(locale, privacy: .public) → \(warmed)")
        }
    }
}
