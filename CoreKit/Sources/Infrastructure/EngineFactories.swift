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
        #elseif os(Linux)
        // ADR-026 Linux/dev 轨道：真实 OCR（PaddleOCR-on-ONNX）由 OcrCli 直接构造，
        // 不再经本工厂——推理运行时只挂 OcrCli target，CoreKitTests 与 App 均不链接
        // onnxruntime（评审修正：此前 Infrastructure 条件依赖 COnnxRuntime，使测试二进制
        // 在干净 Linux 上加载失败、Domain 门禁名存实亡）。Linux 工厂返回桩以满足
        // EAL 契约（EngineAbstractionTests 在此平台断言该桩）。
        return StubImageTextRecognizer(scripted: ImageInputRules.Recognition(lines: [], confidence: 0))
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

// MARK: - 组合根：默认引擎注册

extension EngineRegistry {
    /// App 启动处调用：按当前上下文一次性注册全部引擎能力。
    public func registerDefaultEngines() {
        let ctx = EngineContext.current
        register(OCRRecognizerFactory.make(ctx), for: OCRRecognizerFactory.self)
        register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        register(ImagePreprocessingFactory.make(ctx), for: ImagePreprocessingFactory.self)
        register(ImageDecodingFactory.make(ctx), for: ImageDecodingFactory.self)
        register(ImageCompressingFactory.make(ctx), for: ImageCompressingFactory.self)
        register(SensitiveMediaProtectionFactory.make(ctx), for: SensitiveMediaProtectionFactory.self)
    }
}
