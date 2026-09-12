import Foundation
import Domain
import Protocols

// MARK: - OCR 引擎工厂（经 EAL 接入）

public enum OCRRecognizerFactory: EngineFactory {
    public typealias Capability = any ImageTextRecognizing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImageTextRecognizing {
        VisionImageRecognizer()
    }
}

// MARK: - 语音输出引擎工厂（经 EAL 接入）

public enum SpeechSynthesisFactory: EngineFactory {
    public typealias Capability = any SpeechSynthesizing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any SpeechSynthesizing {
        // ADR-023（V3.102 审查修正）：TTS 采用 AVSpeechAdapter——Supertonic-3
        // 经核实的 31 语种不含中文，无法承担 FR17.16 普通话回退链与 FR17.13
        // 中文回读；系统语音零资产、离线、含 zh-Hans/zh-Hant/en（ADR-025）。
        // SherpaOnnxSpeechSynthesizer 保留为 P1 非中文多语种扩展候选，不接生产链。
        // FR14.7 默认语速接线（审查轮 3/4 登记缺口，2026-09-11 落地）：
        // rateProvider 读取冻结键 speechRate（UserDefaults——沿 HomeView
        // @AppStorage("actionFeedWindow") 冻结键先例；AppSettingsStore 为
        // 单一写入方）。组装根（AppContainer.assemble）先于 AppSettingsStore
        // 构造，无法注入实例，故走冻结键只读消费；缺键/非法值回落 .normal，
        // 与 AppSettingKey.speechRate.defaultValue 同源（SpeechRateTier）。
        AVSpeechAdapter(rateProvider: { Self.currentSpeechRate() })
    }

    /// FR14.7 只读消费：读取冻结键并按 SpeechRateTier（Domain 单一事实源）
    /// 映射 utteranceRate——不得在此内联数值。
    private static func currentSpeechRate() -> Float? {
        let raw = UserDefaults.standard.string(forKey: AppSettingKey.speechRate.rawValue)
        return (raw.flatMap(SpeechRateTier.init(rawValue:)) ?? .normal).utteranceRate
    }
}

// MARK: - 语音输入引擎工厂（经 EAL 接入）

/// FR17.15 V3.66：识别引擎档位 → 具体引擎的**唯一构建出口**（生产工厂与模型实验室共用）。
///
/// 档位语义（`VoiceEngineChoice`）：
/// - `auto`：iOS 26+ 且平台升级轨可用 → `SpeechAnalyzerTranscriber`（SpeechTranscriber）；
///   否则回落基线轨 `SFSpeechTranscriber`（零资产、全 iOS 17+）。
/// - `advanced` / `dictation`：强制平台升级轨（系统版本不足回落基线轨，绝不崩）。
/// - `classic`：强制基线轨。
/// 组装期**不**触发语言资源下载（离线优先红线）——资源安装只经「识别引擎实验室」显式触发；
/// 资产未安装的 locale 在平台轨内整会话回落基线轨（FR17.17 资产供应契约）。
public enum TranscriptionEngineBuilder {
    /// FR17.15/FR17.17 审计修正（2026-09-11 round3）：**auto 解析必须过资产闸门**。
    /// 目录的 `automaticChoice` 只做语言匹配（Domain 零框架，不能读 Bundle），会把中文
    /// locale 解析到 `.qwen3`——若随包资产缺失，`SherpaOnnxTranscriber` 在
    /// `startRecognition` 抛 `engineUnavailable`，等于**默认档语音输入痞痪**（违反
    /// FR17.17「资产缺失即回落降级轨、绝不痞痪」）。此处补两级闸门：
    /// ① 随包模型文件齐备才选用；② 缺件时回落平台升级轨（iOS 26 且标准轨可用）——
    /// 平台轨自身在语言资产未装时按会话回落基线轨；③ 均不可用则经典基线轨（零资产恒可用）。
    public static func automaticChoice(locale: String) -> VoiceEngineChoice {
        let preferred = ASRModelCatalog.automaticChoice(locale: locale)
        guard preferred.isBundledModel else { return preferred }
        guard !ASRModelAssets.resolve(for: preferred).isPresent(preferred) else { return preferred }
        return fallbackForMissingBundledModel()
    }

    /// 缺件随包模型的回落目标：平台轨可用则用平台轨（其内部再按语言资产回落基线轨），
    /// 否则基线轨（零资产恒可用）。
    public static func fallbackForMissingBundledModel() -> VoiceEngineChoice {
        #if os(iOS) || os(macOS)
        if #available(iOS 26.0, macOS 26.0, *),
           SpeechAnalyzerSupport.availability(of: .standard) == .available {
            return .advanced
        }
        #endif
        return .classic
    }

    public static func make(choice: VoiceEngineChoice) -> any TranscriptionEngine {
        // 显式选定的随包模型缺件时**不得悄悄更换引擎**（function-spec FR17.15
        // V3.68 合同「显式选定失败不得换引擎冒充」+ asr.selectionHint 文案）：
        // 直接交付 sherpa 引擎，由资产校验在会话准备期如实报 engineUnavailable
        // 失败——auto 档的缺件回落仍在 automaticChoice 内完成（FR17.17
        // 「资产缺失即回落降级轨」只约束默认档）。owner round10 实测「模型页
        // 勾选了 QWEN-ASR 却由别的引擎服务且无提示」即此处静默替换所致。
        if choice.isBundledModel {
            // 双路径资产：运行时下载版本优先（Application Support），否则随包 Bundle。
            // 缺件时仍交付 sherpa 引擎并由资产校验如实报错（显式选定不得换引擎冒充）。
            return SherpaOnnxTranscriber(choice: choice, assets: ASRModelAssets.resolve(for: choice))
        }
        if choice == .auto { return SwitchableTranscriptionEngine(choiceProvider: { .auto }) }
        SherpaOnnxTranscriber.unloadWhenIdle()
        #if os(iOS) || os(macOS)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch choice {
            case .advanced: return SpeechAnalyzerTranscriber(flavor: .standard)
            case .dictation: return SpeechAnalyzerTranscriber(flavor: .dictation)
            case .classic: return SFSpeechTranscriber()
            case .auto, .qwen3, .zipformer, .dolphin, .whisper: break // 在上方按模型目录分派
            }
        }
        #endif
        if choice == .classic { return SFSpeechTranscriber() }
        // 审查修复：系统版本不足（或设备不支持平台轨）时 advanced/dictation
        // 必须回落基线轨——生产装配绝不回落契约桩（FR17.6 降级语义：
        // 先试全部真实引擎，不可用才降级手输，而非交付恒抛 stub）。
        // 实验室可用性标注（requiresNewerOS/unsupportedDevice）已如实提示，
        // 会话侧仍以真实引擎服务而非每次按压必失败。
        return SFSpeechTranscriber()
    }

    /// 基线轨能力探测快照（SFSpeechTranscriber 初始化即全 supportedLocales 构造
    /// recognizer 探测）：auto 轨 currentCapability 每按压都会走到此处——旧实现
    /// 每次新建 SFSpeechTranscriber 重跑全量探测，按压首秒被探测吃掉
    /// （round10 实测「说短句几乎识别不到」的延迟根因之一）。进程级快照复用。
    private static let baselineCapabilitySnapshot: TranscriptionCapability = SFSpeechTranscriber().capability

    public static func automaticCapability() async -> TranscriptionCapability {
        var locales = Set<String>()
        for model in ASRModelCatalog.models where ASRModelAssets.resolve(for: model.choice).isPresent(model.choice) {
            locales.formUnion(model.availableLocales)
        }
        // 回落目标的能力必须并在表内（缺资产时 auto 由平台轨/基线轨服务）：否则
        // 上层会把全部语言判为「不支持」并错误降级到手输（FR17.6 降级语义被误触发）。
        locales.formUnion(Self.baselineCapabilitySnapshot.availableLocales)
        #if os(iOS) || os(macOS)
        if #available(iOS 26.0, macOS 26.0, *) {
            locales.formUnion(await SpeechAnalyzerSupport.installedLocales(of: .standard))
        }
        #endif
        return .init(supportsLongForm: true, maxSegmentSeconds: 30, availableLocales: locales,
                     allowsDialectFallback: false, matchesLanguageCode: true)
    }

    /// 冻结键读取版本（组装根与其它调用方共用；非法值回落 auto）。
    public static func make(rawChoice: String?) -> any TranscriptionEngine {
        make(choice: VoiceEngineChoice.resolve(rawChoice))
    }

    /// 档位可用性（模型实验室呈现：可用 / 需要 iOS 26 / 设备不支持）。
    public static func availability(of choice: VoiceEngineChoice) -> VoiceEngineAvailability {
        switch choice {
        case .classic, .auto: return .available
        case .advanced: return SpeechAnalyzerSupport.availability(of: .standard)
        case .dictation: return SpeechAnalyzerSupport.availability(of: .dictation)
        case .qwen3, .zipformer, .dolphin, .whisper:
            return ASRModelAssets.resolve(for: choice).isPresent(choice) ? .available : .missingModelAssets
        }
    }

    /// 平台升级轨的「可下载语言」清单（实验室安装引导用；基线轨为空）。
    /// CI 34655298030 修复：supportedLocales 为 async 属性——本函数随之升 async。
    public static func installableLocales(of choice: VoiceEngineChoice) async -> [String] {
        let flavor: SpeechAnalyzerFlavor
        switch choice {
        case .dictation: flavor = .dictation
        case .advanced, .auto: flavor = .standard
        case .classic, .qwen3, .zipformer, .dolphin, .whisper: return []
        }
        return await SpeechAnalyzerSupport.supportedLocales(of: flavor)
    }
}

public enum TranscriptionEngineFactory: EngineFactory {
    public typealias Capability = any TranscriptionEngine
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TranscriptionEngine {
        // ADR-023 双轨设计：sherpa 主轨**临时退出构建**（2026-09-10，ITMS-90208，
        // 复归条件与步骤见 CoreKit/Package.swift 注记）；本版升级轨改由平台
        // SpeechAnalyzer 家族承担（FR17.15 V3.66，零打包风险、系统框架），
        // 基线轨 SFSpeechTranscriber 不变。生产装配绝不回落契约桩（FR17.6）。
        // 档位经冻结键读取（AppSettingsStore 为唯一写入方；与 TTS rateProvider 同纪律）。
        // 复审修正 FIX-A（2026-09-11）：返回**热切换代理**而非一次性引擎实例——
        // 装配期解析一次会让实验室里的档位改动直到重启才生效（5WHY：消费者持有
        // `let` 实例 → 冻结键变更无重解析入口 → UI 文案「切换立即生效」名不副实）。
        // 代理每会话重读冻结键，档位改动自下一次会话起生效。
        SwitchableTranscriptionEngine(choiceProvider: {
            VoiceEngineChoice.resolve(UserDefaults.standard.string(
                forKey: AppSettingKey.voiceEngine.rawValue))
        })
    }
}

// MARK: - 扫描预处理工厂（经 EAL 接入）

public enum ImagePreprocessingFactory: EngineFactory {
    public typealias Capability = any ImagePreprocessing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImagePreprocessing {
        VisionImagePreprocessor()
    }
}

// MARK: - 图片/PDF 解码工厂（经 EAL 接入）

public enum ImageDecodingFactory: EngineFactory {
    public typealias Capability = any ImageDecoding
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImageDecoding {
        PDFKitDecoder()
    }
}

// MARK: - 缩略图/敏感脱敏工厂（经 EAL 接入）

public enum ImageCompressingFactory: EngineFactory {
    public typealias Capability = any ImageCompressing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImageCompressing {
        CoreImageCompressor()
    }
}

// MARK: - 敏感媒体保护工厂（经 EAL 接入）

public enum SensitiveMediaProtectionFactory: EngineFactory {
    public typealias Capability = any SensitiveMediaProtection
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any SensitiveMediaProtection {
        CoreImageCompressor()
    }
}

// MARK: - 共享文本理解工厂（经 EAL 接入）

public enum TextUnderstandingFactory: EngineFactory {
    public typealias Capability = any TextUnderstanding
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TextUnderstanding {
        FallbackTextUnderstanding(tracks: [FoundationModelsUnderstanding(), NLTextUnderstanding()])
    }
}

// MARK: - 组合根：默认引擎注册

extension EngineRegistry {
    /// App 启动处调用：按当前上下文一次性注册全部引擎能力。
    /// if-absent 语义（第四轮全仓审查修复）：部分注册的测试桩不得被
    /// 默认引擎覆盖——注册表幂等，组合根可安全重复调用。
    /// 审查修正（V3.102）：`make()` 在 if-absent 判定**之前**求值会让第二次
    /// 调用白白构造一整组引擎（sherpa 模型加载是数百 MB 的启动成本）——
    /// 先查后造，重复调用零构造。
    public func registerDefaultEngines() {
        let ctx = EngineContext.current
        func install<F: EngineFactory>(_ factory: F.Type) {
            guard !isRegistered(factory) else { return }
            registerIfAbsent(factory.make(ctx), for: factory)
        }
        install(OCRRecognizerFactory.self)
        install(SpeechSynthesisFactory.self)
        install(TranscriptionEngineFactory.self)
        install(ImagePreprocessingFactory.self)
        install(ImageDecodingFactory.self)
        install(ImageCompressingFactory.self)
        install(SensitiveMediaProtectionFactory.self)
        install(TextUnderstandingFactory.self)
        install(TextRefinerFactory.self)
    }
}
