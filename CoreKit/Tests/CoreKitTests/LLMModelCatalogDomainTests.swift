import Foundation
import Testing
@testable import Domain

/// `LLMModelCatalog` v2 解析合同（2026-10-09 换型+下载化批）。
/// 全部为纯函数用例，Linux 可跑。
@Suite("LLM 模型目录 v2 合同（Domain）")
struct LLMModelCatalogDomainTests {

    private static let shaA = String(repeating: "a", count: 64)
    private static let shaB = String(repeating: "b", count: 64)

    private func doc(json: String) -> Data { Data(json.utf8) }

    private static let validEntry = """
    {"id":"llm-general-qwen3-0.6b-q4-k-m","role":"default",
     "fileName":"qwen3-0.6b-q4_k_m.gguf","bytes":396705472,
     "sha256":"\(shaA)",
     "url":"https://cnb.cool/robinhoo1973/Resources/-/releases/download/llama-models/qwen3-0.6b-q4_k_m-a1b2c3d4e5f60718.gguf",
     "version":"1","license":"Apache-2.0","frame":"qwen3-nothink"}
    """

    @Test func parsesValidDocumentWithPreferenceOrder() throws {
        let data = doc(json: """
        {"formatVersion":2,"models":[\(Self.validEntry)],"preference":["llm-general-qwen3-0.6b-q4-k-m"]}
        """)
        let document = try #require(LLMModelCatalog.parse(data))
        #expect(document.entries.count == 1)
        let entry = try #require(document.entries.first)
        #expect(entry.id == "llm-general-qwen3-0.6b-q4-k-m")
        #expect(entry.role == .general)
        #expect(entry.frame == .qwen3NonThinking)
        #expect(entry.bytes == 396_705_472)
        #expect(document.preferred.first?.id == entry.id)
    }

    @Test func rejectsWrongFormatVersionAndBadRoot() {
        // v1（历史 §bundled 形态）没有 formatVersion=2 → 整体拒（迁移由 build 期完成）
        #expect(LLMModelCatalog.parse(doc(json: #"{"formatVersion":1,"models":[]}"#)) == nil)
        #expect(LLMModelCatalog.parse(doc(json: #"{"models":[]}"#)) == nil)
        #expect(LLMModelCatalog.parse(Data("not-json".utf8)) == nil)
    }

    @Test func skipsMalformedEntriesButKeepsValidOnes() {
        let bad = [
            #"{"id":"Bad Slug!","role":"default","fileName":"x.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#,       // 非法 id
            #"{"id":"ok1","role":"default","fileName":"x.bin","bytes":1,"sha256":"\#(Self.shaA)","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#,               // 非 .gguf
            #"{"id":"ok2","role":"default","fileName":"x.gguf","bytes":0,"sha256":"\#(Self.shaA)","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#,               // bytes=0
            #"{"id":"ok3","role":"default","fileName":"x.gguf","bytes":1,"sha256":"short","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#,                      // sha 非 64hex
            #"{"id":"ok4","role":"default","fileName":"x.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"http://cnb.cool/a","version":"1","license":"MIT"}"#,               // 非 https
            #"{"id":"ok5","role":"default","fileName":"x.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"https://evil.example/a","version":"1","license":"MIT"}"#,          // 主机白名单外
            #"{"id":"ok6","role":"default","fileName":"x.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"https://cnb.cool:8443/a","version":"1","license":"MIT"}"#,         // 非 443 端口
            #"{"id":"ok7","role":"wizard","fileName":"x.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#,               // 未知 role
        ].joined(separator: ",")
        let data = doc(json: #"{"formatVersion":2,"models":[\#(bad)],"preference":[]}"#)
        #expect(LLMModelCatalog.parse(data)?.entries.isEmpty == true, "全部条目非法 → 空目录（未配置语义）")
    }

    @Test func duplicateIDKeepsFirstOccurrence() {
        let dup = #"{"id":"dup","role":"default","fileName":"a.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#
        let dup2 = #"{"id":"dup","role":"medical","fileName":"b.gguf","bytes":2,"sha256":"\#(Self.shaB)","url":"https://cnb.cool/b","version":"2","license":"MIT"}"#
        let data = doc(json: #"{"formatVersion":2,"models":[\#(dup),\#(dup2)],"preference":[]}"#)
        let document = LLMModelCatalog.parse(data)
        #expect(document?.entries.count == 1)
        #expect(document?.entries.first?.fileName == "a.gguf", "重复 id 保留首个（确定性优先）")
    }

    @Test func danglingPreferenceRejectsWholeDocument() {
        let data = doc(json: #"{"formatVersion":2,"models":[\#(Self.validEntry)],"preference":["no-such-id"]}"#)
        #expect(LLMModelCatalog.parse(data) == nil, "优先序指向不存在条目 = 静默错选种子，宁愿整体拒")
    }

    @Test func frameDefaultsToChatML() {
        let noFrame = #"{"id":"plain","role":"default","fileName":"p.gguf","bytes":1,"sha256":"\#(Self.shaA)","url":"https://cnb.cool/a","version":"1","license":"MIT"}"#
        let data = doc(json: #"{"formatVersion":2,"models":[\#(noFrame)],"preference":[]}"#)
        #expect(LLMModelCatalog.parse(data)?.entries.first?.frame == .chatML)
    }

    @Test func preferredAppendsUnreferencedEntriesInFileOrder() {
        let a = Self.validEntry
        let b = #"{"id":"medical-llm-64m-q4-k-m","role":"medical","fileName":"m.gguf","bytes":10,"sha256":"\#(Self.shaB)","url":"https://cnb.cool/m","version":"1","license":"MIT"}"#
        let data = doc(json: #"{"formatVersion":2,"models":[\#(a),\#(b)],"preference":["medical-llm-64m-q4-k-m"]}"#)
        let document = LLMModelCatalog.parse(data)
        #expect(document?.preferred.map(\.id) == ["medical-llm-64m-q4-k-m", "llm-general-qwen3-0.6b-q4-k-m"],
                "显式优先序在前，未引用条目按文件序补尾（显式 id 寻址仍可达）")
    }
}
