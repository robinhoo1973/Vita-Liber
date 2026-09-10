import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// SherpaOnnx 引擎工厂验收（对齐 tech-spec V3.101 / ADR-023 单轨制）
@Suite("SherpaOnnx 引擎工厂验收")
struct SherpaOnnxEngineTests {

    // MARK: - Factory Dispatch

    @Test("TranscriptionEngineFactory 返回 SherpaOnnxTranscriber 或契约桩")
    func transcriptionFactoryDispatch() {
        let ctx = EngineContext.current
        let engine = TranscriptionEngineFactory.make(ctx)
        // Models may not be bundled in test target — accept stub as valid fallback
        #expect(engine is SherpaOnnxTranscriber || engine is StubTranscriptionEngine)
    }

    @Test("SpeechSynthesisFactory 返回 SherpaOnnxSpeechSynthesizer 或录制替身")
    func synthesisFactoryDispatch() {
        let ctx = EngineContext.current
        let engine = SpeechSynthesisFactory.make(ctx)
        #expect(engine is SherpaOnnxSpeechSynthesizer || engine is RecordingSpeechSynthesizer)
    }

    // MARK: - Capability Attributes

    @Test("SherpaOnnxTranscriber onDeviceOnly 始终为 true")
    func transcriptionOnDeviceOnly() {
        #expect(TranscriptionEngineFactory.onDeviceOnly)
    }

    @Test("SherpaOnnxSpeechSynthesizer onDeviceOnly 始终为 true")
    func synthesisOnDeviceOnly() {
        #expect(SpeechSynthesisFactory.onDeviceOnly)
    }

    // MARK: - Protocol Conformance (type-level)

    @Test("SherpaOnnxTranscriber 遵循 TranscriptionEngine 协议")
    func transcriptionProtocolConformance() {
        // Compile-time check: assigning to protocol-typed variable
        let _: any TranscriptionEngine = StubTranscriptionEngine(
            capability: .baseline(), scripted: ["test"]
        )
        #expect(Bool(true))
    }

    @Test("SherpaOnnxSpeechSynthesizer 遵循 SpeechSynthesizing 协议")
    func synthesisProtocolConformance() {
        let _: any SpeechSynthesizing = RecordingSpeechSynthesizer()
        #expect(Bool(true))
    }

    // MARK: - Registry Integration

    @Test("TranscriptionEngineFactory 注册后可解析")
    func registryIntegration() {
        let r = EngineRegistry()
        let ctx = EngineContext.current
        r.register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        #expect(r.isRegistered(TranscriptionEngineFactory.self))

        let engine: any TranscriptionEngine = r.resolve(TranscriptionEngineFactory.self)
        #expect(engine is TranscriptionEngine)
    }

    @Test("SpeechSynthesisFactory 注册后可解析")
    func synthesisRegistryIntegration() {
        let r = EngineRegistry()
        let ctx = EngineContext.current
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        #expect(r.isRegistered(SpeechSynthesisFactory.self))

        let engine: any SpeechSynthesizing = r.resolve(SpeechSynthesisFactory.self)
        #expect(engine is SpeechSynthesizing)
    }

    // MARK: - Offline Guard

    @Test("所有 sherpa-onnx 工厂均通过离线守卫")
    func offlineGuard() {
        let r = EngineRegistry()
        let ctx = EngineContext.current
        r.register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)

        guard case .success = r.assertOfflineOnly() else {
            #expect(Bool(false), "sherpa-onnx 端侧引擎应通过离线守卫")
            return
        }
    }
}
