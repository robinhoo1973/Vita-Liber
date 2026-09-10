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
        AVSpeechAdapter()
    }
}

// MARK: - 语音输入引擎工厂（经 EAL 接入）

public enum TranscriptionEngineFactory: EngineFactory {
    public typealias Capability = any TranscriptionEngine
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TranscriptionEngine {
        // ADR-023（V3.102 审查修正）：主轨 sherpa-onnx（资产就绪时）；资产缺失
        // → 基线轨 SFSpeechTranscriber（功能完备、零资产）。生产装配绝不回落
        // 契约桩（FR17.6：先试全部真实引擎，不可用才降级手输）；桩仅供
        // Preview/测试经 registerIfAbsent 显式注入。
        SherpaOnnxTranscriber() ?? SFSpeechTranscriber()
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
