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
        let locales = SettingsRules.voiceLocales(settings.values[.voiceInputLanguages])
        let mixed = SettingsRules.resolved(settings.values[.voiceMixedInput],
                                           key: .voiceMixedInput) == "true"
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
