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
        SherpaOnnxSpeechSynthesizer() ?? RecordingSpeechSynthesizer()
    }
}

// MARK: - 语音输入引擎工厂（经 EAL 接入）

public enum TranscriptionEngineFactory: EngineFactory {
    public typealias Capability = any TranscriptionEngine
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TranscriptionEngine {
        SherpaOnnxTranscriber()
            ?? StubTranscriptionEngine(capability: .baseline(), scripted: [])
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
        registerIfAbsent(TextRefinerFactory.make(ctx), for: TextRefinerFactory.self)
    }
}
