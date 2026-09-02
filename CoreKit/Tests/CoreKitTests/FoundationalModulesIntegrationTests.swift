import Foundation
import Testing
import Domain
import Protocols
import Infrastructure

/// 全模块集成测试：验证 EAL + 四新模块 + SHA256 + Quality 可在同一进程中共存并正确协作。
@Suite("集成测试 · 全模块协作验收")
struct FoundationalModulesIntegrationTests {

    // MARK: - EAL + 四工厂端到端

    @Test("EAL 注册全部 7 工厂后可解析并调用协议方法", .tags(.linuxRunnable))
    func ealSevenFactoriesEndToEnd() async throws {
        let r = EngineRegistry()
        let ctx = EngineContext.current

        r.register(OCRRecognizerFactory.make(ctx), for: OCRRecognizerFactory.self)
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        // Linux 工厂返回空 scripted 的桩（会抛 noSpeechDetected），替换为有数据的桩
        r.register(StubTranscriptionEngine(capability: .baseline(), scripted: ["测试转写"]),
                   for: TranscriptionEngineFactory.self)
        r.register(ImagePreprocessingFactory.make(ctx), for: ImagePreprocessingFactory.self)
        r.register(ImageDecodingFactory.make(ctx), for: ImageDecodingFactory.self)
        r.register(ImageCompressingFactory.make(ctx), for: ImageCompressingFactory.self)
        r.register(SensitiveMediaProtectionFactory.make(ctx), for: SensitiveMediaProtectionFactory.self)

        // 解析 7 个协议
        let ocr: any ImageTextRecognizing = r.resolve(OCRRecognizerFactory.self)
        let tts: any SpeechSynthesizing = r.resolve(SpeechSynthesisFactory.self)
        let tx: any TranscriptionEngine = r.resolve(TranscriptionEngineFactory.self)
        let preproc: any ImagePreprocessing = r.resolve(ImagePreprocessingFactory.self)
        let decode: any ImageDecoding = r.resolve(ImageDecodingFactory.self)
        let compress: any ImageCompressing = r.resolve(ImageCompressingFactory.self)
        let sensitive: any SensitiveMediaProtection = r.resolve(SensitiveMediaProtectionFactory.self)

        // 各协议可调用（不崩即通过）
        let recognition = try await ocr.recognize(Data())
        #expect(recognition.lines.isEmpty)

        let request = TranscriptionRequest(localeIdentifier: "zh-Hans-CN")
        let transcript = try await tx.transcribe(request, onPartial: nil)
        #expect(transcript.text.isEmpty)

        // 四新模块调用
        let params = PreprocessParams()
        let preprocessed = try await preproc.preprocess(Data(), params: params, baseVersion: 0)
        #expect(preprocessed.version == 1)

        let decoded = try await decode.decodeImage(Data(), maxDimension: 100)
        #expect(decoded.maxDimension == 100)

        let spec = ThumbnailSpec(maxDimension: 64, blurRadius: 5, quality: 0.5)
        let thumb = try await compress.generateThumbnail(Data(), spec: spec)
        #expect(thumb.count > 0)

        #expect(!sensitive.isProtected("test-media-id"))
    }

    // MARK: - SHA256 + DuplicateDetection 全流程

    @Test("SHA256 → 注册 → 检测 全流程", .tags(.linuxRunnable))
    func sha256DuplicateDetectionFlow() throws {
        // SHA-256 已知向量验证
        let emptyHash = SHA256.hash(data: Data())
        #expect(emptyHash.hexString == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let abcHash = SHA256.hash(data: Data("abc".utf8))
        #expect(abcHash.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // DuplicateDetection 注册 + 精确命中
        var svc = DuplicateDetectionService()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
        try svc.register(recordID: "r1", imageData: png)
        let hit = try svc.detect(png)
        #expect(hit.isDuplicate)
        #expect(hit.exactHashMatch)
        #expect(hit.perceptualSimilarity == 1.0)

        // 不同数据不命中
        let other = png + Data("x".utf8)
        let miss = try svc.detect(other)
        #expect(!miss.exactHashMatch)
    }

    // MARK: - CaptureQuality 评分流程

    @Test("CaptureQualityAssessor 评分确定性", .tags(.linuxRunnable))
    func captureQualityFlow() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
        let q1 = try CaptureQualityAssessor.assess(png)
        let q2 = try CaptureQualityAssessor.assess(png)
        #expect(q1 == q2) // 确定性
        #expect(q1.meetsThreshold(0.0))
    }

    // MARK: - Preprocess 版本递增

    @Test("预处理版本递增", .tags(.linuxRunnable))
    func preprocessVersioning() async throws {
        let preprocessor = StubImagePreprocessor()
        let r1 = try await preprocessor.preprocess(Data(), params: PreprocessParams(), baseVersion: 0)
        let r2 = try await preprocessor.preprocess(Data(), params: PreprocessParams(), baseVersion: r1.version)
        #expect(r2.version > r1.version)
    }

    // MARK: - Decode + Compress 组合

    @Test("解码后缩略图全流程", .tags(.linuxRunnable))
    func decodeThenCompress() async throws {
        let decoder = StubPDFDecoder()
        let compressor = StubImageCompressor()

        let decoded = try await decoder.decodeImage(Data(), maxDimension: 2400)
        let spec = ThumbnailSpec(maxDimension: 320, blurRadius: 10, quality: 0.7)
        let thumb = try await compressor.generateThumbnail(decoded.bitmapData, spec: spec)
        #expect(thumb.count > 0)
    }

    // MARK: - Offline guard 全 7 工厂

    @Test("全部 7 工厂均端侧、离线守卫通过", .tags(.linuxRunnable))
    func offlineGuardAllSeven() {
        let r = EngineRegistry()
        let ctx = EngineContext.current

        r.register(OCRRecognizerFactory.make(ctx), for: OCRRecognizerFactory.self)
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        r.register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        r.register(ImagePreprocessingFactory.make(ctx), for: ImagePreprocessingFactory.self)
        r.register(ImageDecodingFactory.make(ctx), for: ImageDecodingFactory.self)
        r.register(ImageCompressingFactory.make(ctx), for: ImageCompressingFactory.self)
        r.register(SensitiveMediaProtectionFactory.make(ctx), for: SensitiveMediaProtectionFactory.self)

        guard case .success = r.assertOfflineOnly() else {
            Issue.record("全部端侧引擎应通过离线守卫"); return
        }
    }
}
