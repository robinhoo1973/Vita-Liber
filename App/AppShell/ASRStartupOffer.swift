import Foundation
import Domain
import Infrastructure

/// 一次启动推荐（业主 2026-11-05：按硬件推荐，显式同意后才联网下载）。
///
/// 只做**推荐**：不自动联网、不预下载。用户点「下载模型」后走既有
/// `ASRInstallCenter`（签名目录 + 哈希校验 + 用户可见进度）。
struct ASRStartupOffer: Identifiable, Sendable {
    let choice: VoiceEngineChoice
    let release: ASRModelRelease
    let baseURL: URL?
    let displayName: String
    let sizeText: String

    var id: String { "\(release.id)@\(release.version)" }
}

enum ASRStartupOfferProbe {
    /// 启动推荐：auto 档、当前主语言、本机没有可加载的外部主轨时，
    /// 选中首个「目录声明可表达 ∧ 硬件可载 ∧ 已发布 ∧ 已授权」的未安装模型。
    /// 绝不下载、绝不联网；目录/信任库不可用时返回 nil（静默）。
    static func recommendation(engineRaw: String?, languagesRaw: String?) -> ASRStartupOffer? {
        guard VoiceEngineChoice.resolve(engineRaw ?? "") == .auto else { return nil }
        let locales = SettingsRules.voiceLocales(languagesRaw)
        let primaryLocale = locales.first ?? TranscriptionSegmentation.fallbackLocale
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        let index = ModelCatalogTrustStore.shared.currentIndex
            ?? ModelCatalogTrustStore.shared.baselineIndex
        guard let index, index.isSupported else { return nil }

        let hardware = ASRAdvisorInputsProbe.hardwareFacts()
        let installed = ASRAdvisorInputsProbe.installedAssets(index: index)
        let advice = ASRModelAdvisor.advise(locale: primaryLocale, hardware: hardware,
                                            installed: installed, index: index)
        guard advice.primary == nil else { return nil }

        for descriptor in ASRModelCatalog.descriptors(from: index) {
            let choice = descriptor.choice
            guard choice.isBundledModel,
                  descriptor.canExpress(locale: primaryLocale, mode: .single),
                  installed.model(for: choice) == nil,
                  let release = ASRModelDownloadService.latest(for: choice, in: index,
                                                               appVersion: appVersion),
                  let bytes = release.bytes, bytes > 0 else { continue }
            guard let physical = hardware.physicalMemoryBytes,
                  physical >= ASRHardwarePolicy.externalModelMinimumPhysicalMemoryBytes,
                  let available = hardware.availableMemoryBytes,
                  ModelMemoryBudget.verdict(modelBytes: bytes, availableBytes: available).allowsLoad else {
                continue
            }
            guard let baseURL = ModelCatalogTrustStore.shared.baseURL(for: release) else { continue }
            let name = index.family(for: release.id)?.name?.resolved()
                ?? choice.rawValue
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return ASRStartupOffer(choice: choice, release: release, baseURL: baseURL,
                                   displayName: name, sizeText: size)
        }
        return nil
    }
}
