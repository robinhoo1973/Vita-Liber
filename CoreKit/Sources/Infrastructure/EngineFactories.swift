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

public enum TranscriptionEngineFactory: EngineFactory {
    public typealias Capability = any TranscriptionEngine
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TranscriptionEngine {
        // ADR-023 双轨设计保留，但 sherpa 主轨**临时退出构建**（2026-09-10）：
        // 其 onnxruntime 依赖在 Xcode 26 下被转成内嵌 dylib、与框架 Info.plist
        // 矛盾，三个 build 被 App Store 以 ITMS-90208 拒绝（详见
        // CoreKit/Package.swift 顶部注释与 findings 发现 22）。当前装配 =
        // 基线轨 SFSpeechTranscriber（功能完备、零资产、可发布）。复归条件
        // 满足后恢复 `SherpaOnnxTranscriber() ?? SFSpeechTranscriber()`。
        // 生产装配绝不回落契约桩（FR17.6 降级语义）。
        SFSpeechTranscriber()
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
        FallbackTextUnderstanding(tracks: [NLTextUnderstanding()])
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
