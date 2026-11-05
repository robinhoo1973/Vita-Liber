import Foundation
import Domain
import Infrastructure

/// 一次启动推荐（业主 2026-11-05：按硬件推荐，显式同意后才联网下载）。
///
/// 只做**推荐**：不自动联网、不预下载。用户点「下载模型」后走既有
/// `ASRInstallCenter`（签名目录 + 哈希校验 + 用户可见进度）。
struct ASRStartupOffer: Sendable {
    let release: ASRModelRelease
    let baseURL: URL?
    let displayName: String
    let sizeText: String
}

enum ASRStartupOfferProbe {
    /// 启动推荐：auto 档、本机没有可加载的外部主轨时，
    /// 选中首个「目录声明可表达 ∧ 硬件可载 ∧ 已发布 ∧ 已授权」的未安装模型。
    /// 请求范围与按压同口径（混说开 = 全部已选语种 + `.mixed`；关 = 主语言 + `.single`），
    /// 否则会推荐一个运行时无法覆盖混说请求的模型。
    /// 绝不下载、绝不联网；目录/信任库/硬件探针不可用时返回 nil（静默，fail-closed）。
    static func recommend(engineRaw: String?, languagesRaw: String?,
                          mixedRaw: String?) -> ASRStartupOffer? {
        guard VoiceEngineChoice.resolve(engineRaw ?? "") == .auto else { return nil }
        let locales = SettingsRules.voiceLocales(languagesRaw)
        let primaryLocale = SettingsRules.preferredVoiceLocale(languagesRaw)
            ?? TranscriptionSegmentation.fallbackLocale
        let mixed = SettingsRules.resolved(mixedRaw, key: .voiceMixedInput) != "false"
        let requestedLocales = mixed ? locales : [primaryLocale]
        let mode: TranscriptionLanguageMode = mixed ? .mixed : .single
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        // 与自动选档/资产校验同一目录出口（含测试覆写），不再本地重建 current ?? baseline。
        guard let index = ASRFamilyIndexStore.routingIndex(), index.isSupported else { return nil }

        let hardware = ASRAdvisorInputsProbe.hardwareFacts()
        let installed = ASRAdvisorInputsProbe.installedAssets(index: index)
        let advice = ASRModelAdvisor.advise(locales: requestedLocales, mode: mode,
                                            hardware: hardware, installed: installed, index: index)
        guard advice.primary == nil else { return nil }
        // 与设置页下载路径同一口径：物理内存/可用内存/剩余空间未知 = 不推荐
        // （推荐一个装不上或载不动的包只会浪费用户流量）。
        guard let physical = hardware.physicalMemoryBytes,
              physical >= ASRHardwarePolicy.externalModelMinimumPhysicalMemoryBytes,
              let available = hardware.availableMemoryBytes,
              let storage = hardware.storageFreeBytes else { return nil }

        for descriptor in ASRModelCatalog.descriptors(from: index) {
            let choice = descriptor.choice
            guard choice.isBundledModel,
                  requestedLocales.allSatisfy({ descriptor.canExpress(locale: $0, mode: mode) }),
                  installed.model(for: choice) == nil else { continue }

            // 多档家族与设置页同源选档：listed variants 按 variantWeight 升序，
            // 由内存预算/RAM 档位推荐；单档/无档族沿用 latest（与设置页下载目标一致）。
            let variants = ASRModelDownloadService.publishedVariants(for: choice, in: index,
                                                                     appVersion: appVersion)
            let release: ASRModelRelease?
            if variants.count > 1 {
                let recommended = ASRVariantRecommendation.recommendedIndex(
                    expandedBytes: variants.map { $0.expandedBytes ?? Int64.max },
                    availableBytes: available,
                    ramBytes: physical)
                release = variants[recommended]
            } else {
                release = ASRModelDownloadService.latest(for: choice, in: index,
                                                         appVersion: appVersion)
            }
            // 内存预算按解压后的实际载入体积判定（下载字节是压缩包，会低估）。
            guard let release,
                  let bytes = release.bytes, bytes > 0,
                  let expanded = release.expandedBytes, expanded > 0,
                  ModelMemoryBudget.verdict(modelBytes: expanded, availableBytes: available).allowsLoad,
                  ASRModelDownloadService.hasSpaceForDownload(release, freeBytes: storage),
                  let baseURL = ModelCatalogTrustStore.shared.baseURL(for: release) else { continue }
            let name = index.family(for: release.id)?.name?.resolved() ?? choice.rawValue
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return ASRStartupOffer(release: release, baseURL: baseURL,
                                   displayName: name, sizeText: size)
        }
        return nil
    }
}
