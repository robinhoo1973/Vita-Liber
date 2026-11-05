import Foundation

/// 识别主轨的硬件事实（纯值对象，Domain 零框架依赖）。
///
/// nil / `.unknown` = 探针不可用。**可用内存未知时外部模型选择 fail-closed**（不猜、
/// 不按物理内存反推可用内存）——业主裁决 2026-11-04：主轨按硬件能力过滤后再按
/// 签名目录顺序取候选，候选不是「最佳准确率」排序，只是「本机可安全加载且目录先发布」。
public struct ASRHardwareFacts: Sendable, Equatable {
    public enum Thermal: String, Sendable, Equatable, Codable {
        case nominal
        case fair
        case serious
        case critical
        /// 探针不可用（非 Apple 平台 / 调用方未提供）。
        case unknown
    }

    /// 本进程在被 jetsam 终止前还能分配的字节数（`ProcessMemory.availableBytes()`）。
    public var availableMemoryBytes: Int64?
    /// 物理内存（`ProcessInfo.physicalMemory`）。
    public var physicalMemoryBytes: UInt64?
    /// 应用支持目录所在卷的可用空间（`volumeAvailableCapacityForImportantUsage`）。
    public var storageFreeBytes: Int64?
    public var thermal: Thermal
    /// 低电量模式；nil = 未知。
    public var lowPowerMode: Bool?

    public init(availableMemoryBytes: Int64? = nil,
                physicalMemoryBytes: UInt64? = nil,
                storageFreeBytes: Int64? = nil,
                thermal: Thermal = .unknown,
                lowPowerMode: Bool? = nil) {
        self.availableMemoryBytes = availableMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.storageFreeBytes = storageFreeBytes
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }
}

/// 一个已安装（随包或已下载）的外部模型。**未安装的目录条目不会被选中**——
/// 本 App 绝不静默下载（ADR-030：下载只由用户显式发起）。
public struct ASRInstalledModel: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable, Codable {
        /// 运行时下载并校验过的版本（`Application Support/ASRModels`）。
        case downloaded
        /// 随包资产（当前 IPA 默认不含 ASR 权重；保留以兼容历史构建）。
        case bundled
    }

    public var choice: VoiceEngineChoice
    /// 已安装权重总字节（清单逐文件字节求和）；nil = 清单不完整/不可读 → fail-closed。
    public var bytes: Int64?
    public var version: String?
    public var origin: Origin

    public init(choice: VoiceEngineChoice, bytes: Int64?, version: String? = nil,
                origin: Origin = .downloaded) {
        self.choice = choice
        self.bytes = bytes
        self.version = version
        self.origin = origin
    }
}

/// 已安装外部模型集合（按引擎档位索引）。
public struct ASRInstalledAssets: Sendable, Equatable {
    public var models: [ASRInstalledModel]

    public init(models: [ASRInstalledModel] = []) {
        self.models = models
    }

    public static let empty = ASRInstalledAssets()

    public func model(for choice: VoiceEngineChoice) -> ASRInstalledModel? {
        models.first { $0.choice == choice }
    }

    public var isEmpty: Bool { models.isEmpty }
}

/// 保守硬件门槛（常量集中命名，可在真机 L2 标定；不是医疗数值）。
public enum ASRHardwarePolicy {
    /// 外部模型主轨的物理内存下限。低于此值不选外部模型（fail-closed），
    /// 由路由层回落到零资产 Apple 轨；避免 GB 级模型加载被 jetsam 终止。
    public static let externalModelMinimumPhysicalMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    /// 6GB 档分界（仅用于档位报告）。
    public static let largeTierMinimumPhysicalMemoryBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024
    /// 低存储水位（仅告警，不切换服务引擎的原因见 `ASRModelAdvice` 注释）。
    public static let minimumFreeStorageBytes: Int64 = 256 * 1_024 * 1_024
}

/// 物理内存档位（4GB/6GB 两档；未知按最保守的 compact 处理）。
///
/// 档位只描述**主轨外部模型**能否安全加载；Apple 第二/第三源在采集结束后才运行，
/// 不参与「三源实时并行」编排（业主 2026-11-05 修正）。
public enum ASRHardwareTier: String, Sendable, Equatable, Codable {
    /// < 4GB：不选外部模型（fail-closed）。
    case compact
    /// 4GB–<6GB：外部模型可作主轨。
    case standard
    /// >= 6GB：外部模型可作主轨（更大的内存余量，利于主轨预热）。
    case large

    public static func resolve(physicalMemoryBytes: UInt64?) -> ASRHardwareTier {
        guard let bytes = physicalMemoryBytes else { return .compact }
        if bytes >= ASRHardwarePolicy.externalModelMinimumPhysicalMemoryBytes {
            return bytes >= ASRHardwarePolicy.largeTierMinimumPhysicalMemoryBytes ? .large : .standard
        }
        return .compact
    }
}

/// 通过硬件过滤的候选（保持签名目录 families 发布序）。
public struct ASRModelCandidate: Sendable, Equatable {
    public var choice: VoiceEngineChoice
    /// 在签名目录 families 中的发布位置（0 = 目录首选）。
    public var catalogPosition: Int
    public var installedBytes: Int64
    /// 可加载但预热余量不足（`ModelMemoryBudget.Verdict.tight`）：按压时再载，不预热。
    public var budgetIsTight: Bool

    public init(choice: VoiceEngineChoice, catalogPosition: Int, installedBytes: Int64,
                budgetIsTight: Bool) {
        self.choice = choice
        self.catalogPosition = catalogPosition
        self.installedBytes = installedBytes
        self.budgetIsTight = budgetIsTight
    }
}

/// 候选被硬件/安装/目录过滤的原因（仅诊断与 UI 提示，不改写用户语言选择）。
public enum ASRModelRejectionReason: String, Sendable, Equatable, Codable {
    /// 目录声明不覆盖请求的 locale/混说语种集（与「硬件不可用」区分，路由回落不同）。
    case localeUnsupported
    /// 目录有该档，但本机没有已安装权重——**绝不自动下载**。
    case notInstalled
    /// 已安装但清单字节不可读：无法做内存预算 → fail-closed。
    case installedBytesUnknown
    /// 物理内存探针不可用。
    case physicalMemoryUnknown
    /// 物理内存低于外部模型下限（< 4GB）。
    case belowMinimumPhysicalMemory
    /// 可用内存探针不可用——业主裁决要求 fail-closed。
    case availableMemoryUnknown
    /// 内存预算判定不可加载（`ModelMemoryBudget.Verdict.insufficient`）。
    case insufficientMemory
}

public struct ASRModelRejection: Sendable, Equatable {
    public var choice: VoiceEngineChoice
    public var reason: ASRModelRejectionReason
    /// 该条目若要成为候选，必须由用户显式发起下载（ADR-030）。
    public var requiresUserInitiatedDownload: Bool

    public init(choice: VoiceEngineChoice, reason: ASRModelRejectionReason,
                requiresUserInitiatedDownload: Bool = false) {
        self.choice = choice
        self.reason = reason
        self.requiresUserInitiatedDownload = requiresUserInitiatedDownload
    }
}

/// 无外部主轨时，Apple 零资产轨接管的分类原因。
public enum ASRPrimaryOnlyReason: String, Sendable, Equatable, Codable {
    /// 目录没有任何模型声明覆盖该 locale（语言不支持；旧路由等价回落 `.classic`）。
    case noExpressibleCatalogCandidate
    /// 有可表达候选，但本机一个都没安装（缺件回落平台轨/基线轨）。
    case noInstalledExpressibleModel
    /// 有已安装的可表达候选，但物理内存/可用内存/字节清单不满足硬件过滤。
    case hardwareIneligible
}

/// 主轨与 Apple 第二/第三源的执行编排。
///
/// 业主 2026-11-05 修正：**没有三源实时并行要求**。主轨在按压期间实时识别；
/// 松手后若存在录音缓冲，再把同一段音频交给 Apple 中文（zh-CN）、Apple 英文（en-US）
/// 做文件识别，结果作为第二/第三假设参与文本后处理。
public enum ASRExecutionMode: Sendable, Equatable {
    /// 主轨实时识别；采集结束后运行 Apple 第二/第三源（是否需要音频由运行时决定）。
    case appleSecondariesAfterCapture
    /// 没有可用的外部主轨：由路由层回落到平台/基线 Apple 轨。采集后仍可运行另一语种
    /// 的 Apple 文件识别；同源同语种副源由运行时 plan 自动跳过。
    case primaryOnly(reason: ASRPrimaryOnlyReason)
}

public enum ASRAdviceWarning: String, Sendable, Hashable, Codable {
    case physicalMemoryUnknown
    case availableMemoryUnknown
    /// 可用存储低于水位：提示用户清理；**不切换服务引擎**（已安装模型不因剩余空间少而失效，
    /// 静默换引擎会违反「不静默换语言/引擎」合同）。
    case lowFreeStorage
    /// 热状态 serious/critical：只提示，不切换主轨，也不改写采集后的 Apple 副源编排。
    case thermalConstrained
    case lowPowerMode
    /// 主轨可加载但预热余量不足（tight）：按压时再载。
    case tightMemory
}

/// 一次选择建议。`ranked` 的顺序 = 硬件过滤后的签名目录发布序，
/// **不是准确率排名**；本类型不承诺「最佳模型」。
public struct ASRModelAdvice: Sendable, Equatable {
    public var locale: String
    public var languageMode: TranscriptionLanguageMode
    public var hardwareTier: ASRHardwareTier
    /// 通过全部硬件过滤的首个目录候选（= `ranked.first`）。
    public var primary: ASRModelCandidate?
    public var ranked: [ASRModelCandidate]
    public var rejected: [ASRModelRejection]
    /// Apple 第二/第三源（固定 zh-CN / en-US，按 locale 各一个识别器）。
    public var appleSources: [ASRAppleSource]
    public var execution: ASRExecutionMode
    public var warnings: [ASRAdviceWarning]
    /// 目录是否有模型**声明**覆盖请求 locale（与安装/硬件无关）。
    /// 路由层据此区分「语言不支持 → classic」与「缺件/硬件不足 → 平台轨回落」。
    public var hasExpressibleCatalogCandidate: Bool

    public init(locale: String, languageMode: TranscriptionLanguageMode, hardwareTier: ASRHardwareTier,
                primary: ASRModelCandidate?, ranked: [ASRModelCandidate], rejected: [ASRModelRejection],
                appleSources: [ASRAppleSource], execution: ASRExecutionMode, warnings: [ASRAdviceWarning],
                hasExpressibleCatalogCandidate: Bool) {
        self.locale = locale
        self.languageMode = languageMode
        self.hardwareTier = hardwareTier
        self.primary = primary
        self.ranked = ranked
        self.rejected = rejected
        self.appleSources = appleSources
        self.execution = execution
        self.warnings = warnings
        self.hasExpressibleCatalogCandidate = hasExpressibleCatalogCandidate
    }
}

/// 硬件优先、目录序次之的 ASR 主轨选择器（纯 Domain，确定性，无 IO）。
///
/// 规则顺序（业主裁决 2026-11-04）：
///   ① 目录声明必须覆盖请求 locale（单语）或全部已选语种（混说）；
///   ② 外部模型必须**已安装**（绝不静默下载）；
///   ③ 物理内存 >= 4GB 且可用内存探针可用（未知 → fail-closed）；
///   ④ `ModelMemoryBudget` 判定可加载（insufficient → 跳过；tight → 可加载但记告警）；
///   ⑤ 通过者保持签名目录 families 发布序，取首个为主轨。
/// 选择器只回答「本机现在能安全跑哪个已安装模型」，不回答「哪个模型准确率最高」。
public enum ASRModelAdvisor {
    public static func advise(locale: String,
                              mode: TranscriptionLanguageMode = .single,
                              hardware: ASRHardwareFacts,
                              installed: ASRInstalledAssets,
                              index: ASRModelReleaseIndex?) -> ASRModelAdvice {
        advise(locales: [locale], mode: mode, hardware: hardware, installed: installed, index: index)
    }

    public static func advise(locales: [String],
                              mode: TranscriptionLanguageMode = .single,
                              hardware: ASRHardwareFacts,
                              installed: ASRInstalledAssets,
                              index: ASRModelReleaseIndex?) -> ASRModelAdvice {
        let requested = locales
        let primaryLocale = requested.first ?? TranscriptionSegmentation.fallbackLocale
        let descriptors = ASRModelCatalog.descriptors(from: index)
        let tier = ASRHardwareTier.resolve(physicalMemoryBytes: hardware.physicalMemoryBytes)

        var warningSet: Set<ASRAdviceWarning> = []
        if hardware.physicalMemoryBytes == nil { warningSet.insert(.physicalMemoryUnknown) }
        if hardware.availableMemoryBytes == nil { warningSet.insert(.availableMemoryUnknown) }
        if let storage = hardware.storageFreeBytes,
           storage < ASRHardwarePolicy.minimumFreeStorageBytes { warningSet.insert(.lowFreeStorage) }
        if hardware.thermal == .serious || hardware.thermal == .critical {
            warningSet.insert(.thermalConstrained)
        }
        if hardware.lowPowerMode == true { warningSet.insert(.lowPowerMode) }

        var ranked: [ASRModelCandidate] = []
        var rejected: [ASRModelRejection] = []
        var hasExpressible = false
        var hasInstalledExpressible = false

        for (position, descriptor) in descriptors.enumerated() {
            let expressible = !requested.isEmpty
                && requested.allSatisfy { descriptor.canExpress(locale: $0, mode: mode) }
            guard expressible else {
                rejected.append(.init(choice: descriptor.choice, reason: .localeUnsupported))
                continue
            }
            hasExpressible = true
            guard let model = installed.model(for: descriptor.choice) else {
                rejected.append(.init(choice: descriptor.choice, reason: .notInstalled,
                                      requiresUserInitiatedDownload: true))
                continue
            }
            hasInstalledExpressible = true
            guard let bytes = model.bytes, bytes > 0 else {
                rejected.append(.init(choice: descriptor.choice, reason: .installedBytesUnknown))
                continue
            }
            guard let physical = hardware.physicalMemoryBytes else {
                rejected.append(.init(choice: descriptor.choice, reason: .physicalMemoryUnknown))
                continue
            }
            guard physical >= ASRHardwarePolicy.externalModelMinimumPhysicalMemoryBytes else {
                rejected.append(.init(choice: descriptor.choice, reason: .belowMinimumPhysicalMemory))
                continue
            }
            guard let available = hardware.availableMemoryBytes else {
                rejected.append(.init(choice: descriptor.choice, reason: .availableMemoryUnknown))
                continue
            }
            let verdict = ModelMemoryBudget.verdict(modelBytes: bytes, availableBytes: available)
            guard verdict.allowsLoad else {
                rejected.append(.init(choice: descriptor.choice, reason: .insufficientMemory))
                continue
            }
            if verdict == .tight { warningSet.insert(.tightMemory) }
            ranked.append(.init(choice: descriptor.choice, catalogPosition: position,
                                installedBytes: bytes, budgetIsTight: verdict == .tight))
        }

        let primary = ranked.first
        let execution: ASRExecutionMode
        if primary != nil {
            execution = .appleSecondariesAfterCapture
        } else {
            let reason: ASRPrimaryOnlyReason
            if !hasExpressible { reason = .noExpressibleCatalogCandidate }
            else if !hasInstalledExpressible { reason = .noInstalledExpressibleModel }
            else { reason = .hardwareIneligible }
            execution = .primaryOnly(reason: reason)
        }

        let warningOrder: [ASRAdviceWarning] = [
            .physicalMemoryUnknown, .availableMemoryUnknown, .lowFreeStorage,
            .thermalConstrained, .lowPowerMode, .tightMemory,
        ]
        return ASRModelAdvice(
            locale: primaryLocale, languageMode: mode, hardwareTier: tier, primary: primary,
            ranked: ranked, rejected: rejected, appleSources: ASRAppleSourceCatalog.sources,
            execution: execution, warnings: warningOrder.filter { warningSet.contains($0) },
            hasExpressibleCatalogCandidate: hasExpressible)
    }

}
