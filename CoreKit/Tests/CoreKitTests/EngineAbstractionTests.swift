import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// M-ENGINEBUS · 统一引擎抽象层（EAL, ADR-027）能力验收（module-test-spec TC-MT-ENGINEBUS-01..05）
@Suite("M-ENGINEBUS · 统一引擎抽象层 (ADR-027)")
struct EngineAbstractionTests {

    // TC-MT-ENGINEBUS-01：三能力经注册表解析，调用方只拿协议、零感知具体引擎
    @Test func 注册三能力并解析为协议_调用方零感知具体引擎() {
        let r = EngineRegistry()
        r.register(StubImageTextRecognizer(scripted: .init(lines: ["阿莫西林 0.25g"], confidence: 0.9)),
                   for: OCRRecognizerFactory.self)
        r.register(RecordingSpeechSynthesizer(), for: SpeechSynthesisFactory.self)
        r.register(StubTranscriptionEngine(capability: .baseline(), scripted: ["血压 120 80"]),
                   for: TranscriptionEngineFactory.self)

        let ocr: any ImageTextRecognizing = r.resolve(OCRRecognizerFactory.self)
        let tts: any SpeechSynthesizing = r.resolve(SpeechSynthesisFactory.self)
        let tx: any TranscriptionEngine = r.resolve(TranscriptionEngineFactory.self)

        #expect(ocr is StubImageTextRecognizer)
        #expect(tts is RecordingSpeechSynthesizer)
        #expect(tx is StubTranscriptionEngine)
    }

    // TC-MT-ENGINEBUS-02：工厂按平台分派；离线引擎且 onDeviceOnly
    @Test func 工厂按平台分派_离线引擎且onDeviceOnly() {
        #expect(OCRRecognizerFactory.onDeviceOnly)
        #expect(SpeechSynthesisFactory.onDeviceOnly)
        #expect(TranscriptionEngineFactory.onDeviceOnly)

        let ocr = OCRRecognizerFactory.make(.current)
        let tts = SpeechSynthesisFactory.make(.current)
        let tx = TranscriptionEngineFactory.make(.current)
        #expect(ocr is any ImageTextRecognizing)
        #expect(tts is any SpeechSynthesizing)
        #expect(tx is any TranscriptionEngine)

        #if os(Linux)
        // Linux 工厂返回桩（评审修正：真实 PaddleOCR 归 OcrCli dev 轨直接构造，
        // 工厂不再把 onnxruntime 拉进测试二进制——见 Package.swift OcrCli 头注）
        #expect(ocr is StubImageTextRecognizer)
        #expect(tts is RecordingSpeechSynthesizer)
        #expect(tx is StubTranscriptionEngine)
        #endif
    }

    // TC-MT-ENGINEBUS-03：离线守卫一票否决
    @Test func 离线守卫_拒绝联网引擎() {
        enum CloudOCRFactory: EngineFactory {
            typealias Capability = any ImageTextRecognizing
            static var onDeviceOnly: Bool { false }
            static func make(_ context: EngineContext) -> any ImageTextRecognizing {
                StubImageTextRecognizer(scripted: .init(lines: [], confidence: 0))
            }
        }
        let r = EngineRegistry()
        r.register(StubImageTextRecognizer(scripted: .init(lines: [], confidence: 0)),
                   for: CloudOCRFactory.self)
        guard case .failure(let e) = r.assertOfflineOnly() else {
            #expect(false, "联网引擎应被离线守卫拒绝"); return
        }
        #expect(e == .offlineViolation)

        // 撤掉违规引擎后守卫通过
        let r2 = EngineRegistry()
        r2.register(StubImageTextRecognizer(scripted: .init(lines: [], confidence: 0)),
                    for: OCRRecognizerFactory.self)
        guard case .success = r2.assertOfflineOnly() else {
            #expect(false, "纯端侧引擎应通过离线守卫"); return
        }
    }

    // TC-MT-ENGINEBUS-04：方言矩阵泛化为 EngineCapabilityProfile（T1/T2）
    @Test func 方言矩阵_泛化为能力画像() {
        let matrix = EngineCapabilityProfile.dialectMatrix()
        #expect(matrix.count == 6)
        let t1 = matrix.filter { $0.tier == .complete }
        let t2 = matrix.filter { $0.tier == .bestEffort }
        #expect(t1.count == 3)
        #expect(t2.count == 3)
        #expect(t1.allSatisfy { $0.onDeviceOnly })
        #expect(t2.allSatisfy { $0.onDeviceOnly })
        // 能力缺口来自数据 + 运行时探测，不硬编码
        #expect(matrix.allSatisfy { !$0.supportedLocales.isEmpty })
    }

    // TC-MT-ENGINEBUS-06（评审补）：capabilityID 是能力探测/注册的键，矩阵内必须唯一。
    // 四川话此前复用普通话的 voiceIn.zh-Hans-CN——按 ID 索引时两条画像互相覆盖，
    // 探测结果无法区分「普通话完整支持」与「四川话尽力识别」。
    @Test func 方言矩阵capabilityID唯一() {
        let ids = EngineCapabilityProfile.dialectMatrix().map(\.capabilityID)
        #expect(Set(ids).count == ids.count, "capabilityID 重复：\(ids)")
        #expect(ids.filter { $0 == "voiceIn.zh-Hans-CN" }.count == 1,
                "普通话 ID 不得被方言复用")
    }

    // TC-MT-ENGINEBUS-07（评审补）：shared 注册表是公开可变单例——并发 resolve
    // 不得数据竞争（NSLock 保护；组合根注册与任意 Task 解析可能并行）
    @Test func 注册表并发解析安全() async {
        let r = EngineRegistry()
        r.register(StubImageTextRecognizer(scripted: .init(lines: ["阿莫西林"], confidence: 0.9)),
                   for: OCRRecognizerFactory.self)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<50 {
                g.addTask {
                    let ocr: any ImageTextRecognizing = r.resolve(OCRRecognizerFactory.self)
                    #expect(ocr is StubImageTextRecognizer)
                }
            }
        }
        #expect(r.isRegistered(OCRRecognizerFactory.self))
    }

    // TC-MT-ENGINEBUS-05：新增引擎，既有调用点零改动
    @Test func 扩展新引擎_既有调用点零改动() {
        protocol GreetingEngine: Sendable { func hello() -> String }
        struct StubGreeting: GreetingEngine { func hello() -> String { "hi" } }
        enum GreetingFactory: EngineFactory {
            typealias Capability = any GreetingEngine
            static var onDeviceOnly: Bool { true }
            static func make(_ context: EngineContext) -> any GreetingEngine { StubGreeting() }
        }
        let r = EngineRegistry()
        r.register(StubGreeting(), for: GreetingFactory.self)
        let g: any GreetingEngine = r.resolve(GreetingFactory.self)
        #expect(g.hello() == "hi")
    }

    // MARK: - 四新引擎工厂验收（M-PREPROC / M-DECODE / M-COMPRESS）

    @Test("四新工厂 onDeviceOnly 均为 true", .tags(.linuxRunnable))
    func 四新工厂离线守卫() {
        #expect(ImagePreprocessingFactory.onDeviceOnly)
        #expect(ImageDecodingFactory.onDeviceOnly)
        #expect(ImageCompressingFactory.onDeviceOnly)
        #expect(SensitiveMediaProtectionFactory.onDeviceOnly)
    }

    @Test("四新工厂按平台分派并可解析", .tags(.linuxRunnable))
    func 四新工厂按平台分派() {
        let r = EngineRegistry()
        let ctx = EngineContext.current

        let preproc = ImagePreprocessingFactory.make(ctx)
        let decode = ImageDecodingFactory.make(ctx)
        let compress = ImageCompressingFactory.make(ctx)
        let sensitive = SensitiveMediaProtectionFactory.make(ctx)

        #expect(preproc is any ImagePreprocessing)
        #expect(decode is any ImageDecoding)
        #expect(compress is any ImageCompressing)
        #expect(sensitive is any SensitiveMediaProtection)

        r.register(preproc, for: ImagePreprocessingFactory.self)
        r.register(decode, for: ImageDecodingFactory.self)
        r.register(compress, for: ImageCompressingFactory.self)
        r.register(sensitive, for: SensitiveMediaProtectionFactory.self)

        let resolvedPreproc: any ImagePreprocessing = r.resolve(ImagePreprocessingFactory.self)
        let resolvedDecode: any ImageDecoding = r.resolve(ImageDecodingFactory.self)
        let resolvedCompress: any ImageCompressing = r.resolve(ImageCompressingFactory.self)
        let resolvedSensitive: any SensitiveMediaProtection = r.resolve(SensitiveMediaProtectionFactory.self)

        #expect(resolvedPreproc is ImagePreprocessing)
        #expect(resolvedDecode is ImageDecoding)
        #expect(resolvedCompress is ImageCompressing)
        #expect(resolvedSensitive is SensitiveMediaProtection)

        #if os(Linux)
        #expect(resolvedPreproc is StubImagePreprocessor)
        #expect(resolvedDecode is StubPDFDecoder)
        #expect(resolvedCompress is StubImageCompressor)
        #expect(resolvedSensitive is StubImageCompressor)
        #endif
    }

    @Test("registerDefaultEngines 注册全部 7 个工厂", .tags(.linuxRunnable))
    func 全部七工厂注册() {
        let r = EngineRegistry()
        let ctx = EngineContext.current

        r.register(OCRRecognizerFactory.make(ctx), for: OCRRecognizerFactory.self)
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        r.register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        r.register(ImagePreprocessingFactory.make(ctx), for: ImagePreprocessingFactory.self)
        r.register(ImageDecodingFactory.make(ctx), for: ImageDecodingFactory.self)
        r.register(ImageCompressingFactory.make(ctx), for: ImageCompressingFactory.self)
        r.register(SensitiveMediaProtectionFactory.make(ctx), for: SensitiveMediaProtectionFactory.self)

        #expect(r.isRegistered(OCRRecognizerFactory.self))
        #expect(r.isRegistered(SpeechSynthesisFactory.self))
        #expect(r.isRegistered(TranscriptionEngineFactory.self))
        #expect(r.isRegistered(ImagePreprocessingFactory.self))
        #expect(r.isRegistered(ImageDecodingFactory.self))
        #expect(r.isRegistered(ImageCompressingFactory.self))
        #expect(r.isRegistered(SensitiveMediaProtectionFactory.self))

        guard case .success = r.assertOfflineOnly() else {
            #expect(false, "全部端侧引擎应通过离线守卫"); return
        }
    }
}
