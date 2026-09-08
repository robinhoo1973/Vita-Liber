import Foundation
import Domain
import Protocols

// MARK: - OCR 引擎工厂（ADR-026，经 EAL 接入）

public enum OCRRecognizerFactory: EngineFactory {
    public typealias Capability = any ImageTextRecognizing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImageTextRecognizing {
        #if os(iOS) || os(macOS)
        return VisionImageRecognizer()
        #else
        return StubImageTextRecognizer(scripted: ImageInputRules.Recognition(lines: [], confidence: 0))
        #endif
    }
}

// MARK: - 语音输出引擎工厂（V3.31，经 EAL 接入）

public enum SpeechSynthesisFactory: EngineFactory {
    public typealias Capability = any SpeechSynthesizing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any SpeechSynthesizing {
        #if os(iOS) || os(macOS)
        return AVSpeechAdapter()
        #else
        return RecordingSpeechSynthesizer()  // 非 Apple 平台：录制替身（可测、不发声）
        #endif
    }
}

// MARK: - 语音输入引擎工厂（ADR-023，经 EAL 接入）

public enum TranscriptionEngineFactory: EngineFactory {
    public typealias Capability = any TranscriptionEngine
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TranscriptionEngine {
        #if os(iOS) || os(macOS)
        return SFSpeechTranscriber()   // ADR-023 基线轨：端侧 SFSpeechRecognizer 音频管线
        #else
        // 非 Apple 平台无系统语音识别框架，以基线能力桩占位（Linux 侧转写仅用于可测性）
        return StubTranscriptionEngine(capability: .baseline(), scripted: [])
        #endif
    }
}

// MARK: - 扫描预处理工厂（M-PREPROC，经 EAL 接入）

public enum ImagePreprocessingFactory: EngineFactory {
    public typealias Capability = any ImagePreprocessing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImagePreprocessing {
        #if os(iOS) || os(macOS)
        return VisionImagePreprocessor()
        #else
        return StubImagePreprocessor()
        #endif
    }
}

// MARK: - 图片/PDF 解码工厂（M-DECODE，经 EAL 接入）

public enum ImageDecodingFactory: EngineFactory {
    public typealias Capability = any ImageDecoding
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImageDecoding {
        #if os(iOS) || os(macOS)
        return PDFKitDecoder()
        #else
        return StubPDFDecoder()
        #endif
    }
}

// MARK: - 缩略图/敏感脱敏工厂（M-COMPRESS，经 EAL 接入）

public enum ImageCompressingFactory: EngineFactory {
    public typealias Capability = any ImageCompressing
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any ImageCompressing {
        #if os(iOS) || os(macOS)
        return CoreImageCompressor()
        #else
        return StubImageCompressor()
        #endif
    }
}

// MARK: - 敏感媒体保护工厂（M-COMPRESS 子能力，经 EAL 接入）

public enum SensitiveMediaProtectionFactory: EngineFactory {
    public typealias Capability = any SensitiveMediaProtection
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any SensitiveMediaProtection {
        #if os(iOS) || os(macOS)
        return CoreImageCompressor()
        #else
        return StubImageCompressor()
        #endif
    }
}

// MARK: - 共享文本理解工厂（ADR-029 期一，V3.86 第 8 工厂）

/// FR17.18 识别后文本理解（OCR/语音共用）——经 EAL 接入。
/// 期一：Apple 平台=兜底轨组合器（NL+正则+启发式，零资产）；其余平台=契约桩。
/// 期二/期三在同工厂内增备轨/主轨成员，调用方零感知。
public enum TextUnderstandingFactory: EngineFactory {
    public typealias Capability = any TextUnderstanding
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TextUnderstanding {
        #if os(iOS) || os(macOS)
        // 期一降级链成员=[兜底轨]；期二加备轨编码器、期三加主轨 Foundation Models
        return FallbackTextUnderstanding(tracks: [NLTextUnderstanding()])
        #else
        return StubTextUnderstanding()
        #endif
    }
}

// MARK: - 组合根：默认引擎注册

extension EngineRegistry {
    /// App 启动处调用：按当前上下文一次性注册全部引擎能力。
    /// if-absent 语义（第四轮全仓审查修复）：部分注册的测试桩不得被
    /// 默认引擎覆盖——注册表幂等，组合根可安全重复调用。
    public func registerDefaultEngines() {
        let ctx = EngineContext.current
        registerIfAbsent(OCRRecognizerFactory.make(ctx), for: OCRRecognizerFactory.self)
        registerIfAbsent(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        registerIfAbsent(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        registerIfAbsent(ImagePreprocessingFactory.make(ctx), for: ImagePreprocessingFactory.self)
        registerIfAbsent(ImageDecodingFactory.make(ctx), for: ImageDecodingFactory.self)
        registerIfAbsent(ImageCompressingFactory.make(ctx), for: ImageCompressingFactory.self)
        registerIfAbsent(SensitiveMediaProtectionFactory.make(ctx), for: SensitiveMediaProtectionFactory.self)
        registerIfAbsent(TextUnderstandingFactory.make(ctx), for: TextUnderstandingFactory.self)
    }
}
