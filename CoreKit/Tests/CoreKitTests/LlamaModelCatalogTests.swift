import Foundation
import Testing
@testable import Infrastructure

/// 本机 LLM 多模型目录解析合同（2026-09-21「共存」裁决基建）。
/// 纯解析/缺席语义单测；Bundle 取模与入包链路由 CI materialize 脚本负责。
@Suite("本机 LLM 多模型目录解析（catalog 合同）")
struct LlamaModelCatalogTests {

    @Test func parsesMultipleEntriesInOrder() {
        let data = Data("""
        {"formatVersion":1,"models":[
          {"id":"qwen2.5-0.5b-instruct-q4_k_m","fileName":"qwen2.5-0.5b-instruct-q4_k_m.gguf","bytes":491400032,"sha256":"aa","bundled":true},
          {"id":"medical-llm-64m-q4-k-m","fileName":"medical-llm-64m-q4-k-m.gguf","bytes":50123456,"sha256":"bb","bundled":true}
        ]}
        """.utf8)
        let entries = LlamaModelManager.parseCatalog(data)
        #expect(entries.count == 2)
        #expect(entries[0].id == "qwen2.5-0.5b-instruct-q4_k_m")
        #expect(entries[0].bytes == 491_400_032)
        #expect(entries[1].id == LlamaModelManager.medicalModelID)
        #expect(entries[1].fileName == "medical-llm-64m-q4-k-m.gguf")
        #expect(entries[1].bytes == 50_123_456)
        #expect(entries[1].bundled)
    }

    @Test func skipsMalformedEntriesAndToleratesBadJSON() {
        let partial = Data(#"{"models":[{"id":"x"},{"fileName":"y.gguf"},{"id":"z","fileName":"z.gguf"}]}"#.utf8)
        let entries = LlamaModelManager.parseCatalog(partial)
        #expect(entries.count == 1, "残缺条目必须跳过（不参与就绪判定）")
        #expect(entries[0].id == "z")
        #expect(entries[0].bytes == 0, "未给 bytes 时退化为未钉版")
        #expect(LlamaModelManager.parseCatalog(Data(#"{"models":[]}"#.utf8)).isEmpty)
        #expect(LlamaModelManager.parseCatalog(Data("not-json".utf8)).isEmpty)
    }

    @Test func absentModelStaysNotReadyAndPrefersNothing() {
        // 测试环境无 catalog 资源 / 无医疗模型文件 → 恒定缺席语义：
        // 未知 id 不就绪；医疗模型回落点必须为 nil（缺席不失能、不假装可用）
        #expect(!LlamaModelManager.isModelReady(id: "no-such-model"))
        #expect(LlamaModelManager.modelURL(id: "no-such-model") == nil)
        #expect(LlamaModelManager.modelSize(id: "no-such-model") == 0)
        #expect(LlamaModelManager.preferredMedicalModelURL() == nil)
    }
}
