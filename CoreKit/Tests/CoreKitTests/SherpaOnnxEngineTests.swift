import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// SherpaOnnx 引擎工厂验收（对齐 tech-spec V3.102 / ADR-023 主轨 + 降级轨）
@Suite("SherpaOnnx 引擎工厂验收")
struct SherpaOnnxEngineTests {

    /// 编译期协议遵循断言：类型漂移在编译期失败，而非等调用方崩（TC-MT-ENGINEBUS-01）。
    /// 主轨类型的构造依赖模型资产（测试宿主不打包），故遵循性以元类型在编译期验证。
    private func assertConforms<T: TranscriptionEngine>(_: T.Type) {}
    private func assertConforms<T: SpeechSynthesizing>(_: T.Type) {}

    @Test("SherpaOnnxTranscriber 编译期遵循 TranscriptionEngine")
    func transcriptionProtocolConformance() {
        assertConforms(SherpaOnnxTranscriber.self)
    }

    @Test("缺失资产不能宣称模型语言可用")
    func missingAssetsStayUnavailable() async {
        let engine = SherpaOnnxTranscriber(choice: .dolphin, assets: ASRModelAssets(root: nil))
        #expect(engine.capability.availableLocales.isEmpty)
        #expect(await engine.localeAssetStatus("wuu-CN") == .unavailable)
    }

    // MARK: - Factory Dispatch

    @Test("TranscriptionEngineFactory 返回真实引擎（主轨 sherpa / 基线轨 SFSpeech），绝不回落契约桩")
    func transcriptionFactoryDispatch() {
        let ctx = EngineContext.current
        let engine = TranscriptionEngineFactory.make(ctx)
        // 测试宿主不打包模型资产 → 期望基线轨 SFSpeech；资产就绪 → 主轨 sherpa。
        // 两者都是真实引擎；契约桩仅限显式注入（FR17.6 降级语义）。
        #expect(engine is SwitchableTranscriptionEngine)
        #expect(!(engine is StubTranscriptionEngine))
    }

    @Test("档位构建出口绝不交付契约桩：缺件随包模型/老系统平台轨均回落真实引擎")
    func builderNeverReturnsContractStub() {
        // 审查修复（断言弱化回填）：此前只断言包装器类型，缺件随包模型
        // 或 iOS<26 的 advanced/dictation 是否回落真实引擎完全没有门禁
        // （UnavailableTranscriptionEngine 恒抛也能通过旧断言）。FR17.6：
        // 生产装配绝不回落契约桩——构建出口的每一个档位都必须交付真实引擎。
        for choice in VoiceEngineChoice.allCases {
            let built = TranscriptionEngineBuilder.make(choice: choice)
            #expect(!(built is UnavailableTranscriptionEngine),
                    "\(choice.rawValue) 不得交付恒抛契约桩")
            #expect(!(built is StubTranscriptionEngine), "\(choice.rawValue) 不得交付测试桩")
        }
    }

    @Test("SpeechSynthesisFactory 返回系统 TTS 引擎（AVSpeechAdapter），绝不回落录制替身")
    func synthesisFactoryDispatch() {
        let ctx = EngineContext.current
        let engine = SpeechSynthesisFactory.make(ctx)
        #expect(engine is AVSpeechAdapter)
        #expect(!(engine is RecordingSpeechSynthesizer))
    }

    // MARK: - Capability Attributes

    @Test("TranscriptionEngineFactory onDeviceOnly 恒为 true（离线红线）")
    func transcriptionOnDeviceOnly() {
        #expect(TranscriptionEngineFactory.onDeviceOnly)
    }

    @Test("SpeechSynthesisFactory onDeviceOnly 恒为 true（离线红线）")
    func synthesisOnDeviceOnly() {
        #expect(SpeechSynthesisFactory.onDeviceOnly)
    }

    // MARK: - Registry Integration

    @Test("TranscriptionEngineFactory 注册后可解析")
    func registryIntegration() {
        let r = EngineRegistry()
        let ctx = EngineContext.current
        r.register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        #expect(r.isRegistered(TranscriptionEngineFactory.self))

        let engine: any TranscriptionEngine = r.resolve(TranscriptionEngineFactory.self)
        #expect(!(engine is StubTranscriptionEngine))
    }

    @Test("SpeechSynthesisFactory 注册后可解析")
    func synthesisRegistryIntegration() {
        let r = EngineRegistry()
        let ctx = EngineContext.current
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)
        #expect(r.isRegistered(SpeechSynthesisFactory.self))

        let engine: any SpeechSynthesizing = r.resolve(SpeechSynthesisFactory.self)
        #expect(!(engine is RecordingSpeechSynthesizer))
    }

    // MARK: - Offline Guard

    @Test("语音输入/输出工厂均通过离线守卫")
    func offlineGuard() {
        let r = EngineRegistry()
        let ctx = EngineContext.current
        r.register(TranscriptionEngineFactory.make(ctx), for: TranscriptionEngineFactory.self)
        r.register(SpeechSynthesisFactory.make(ctx), for: SpeechSynthesisFactory.self)

        guard case .success = r.assertOfflineOnly() else {
            #expect(Bool(false), "语音端侧引擎应通过离线守卫")
            return
        }
    }

    // MARK: - 能力诚实（FR17.15 / V3.94）

    @Test("主轨能力：六语种选择面 = Domain 方言矩阵，T2 尽力识别")
    func capabilityLocaleMatrix() {
        // 模型资产缺失时构造失败——通过装配链断言主轨存在性，
        // 能力面断言落在共享 Domain 矩阵（单一事实源）上
        let matrix = EngineCapabilityProfile.dialectMatrix()
        let locales = Set(matrix.flatMap { $0.supportedLocales.map(\.identifier) })
        #expect(locales.count == 6)
        #expect(locales.contains("zh-Hans-CN"))
        #expect(locales.contains("yue-Hant-HK"))
        #expect(locales.contains("en-US"))
    }
}
