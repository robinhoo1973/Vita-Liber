import Foundation
import Testing
@testable import Infrastructure

/// CNB tag 页 SSR 清单解析(设计文档 §3.1/§7.1):sanitized fixture 回归——
/// 纯 Foundation 解码层,Linux 可跑,规避平台守卫空编译单元盲区。
@Suite("CNB tag 页清单解析")
struct CNBReleasePageInventoryParserTests {
    private func page(_ release: [String: Any], tag: String = "asr-models") throws -> Data {
        let data: [String: Any] = ["props": ["pageProps": [
            "releaseDetailStatus": "success",
            "releasesDetailData": ["release": release]]]]
        let literal = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)
        guard let literal, let html = ("<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">"
            + literal + "</script></body></html>").data(using: .utf8) else {
            throw ParserTestError.fixtureEncodingFailed
        }
        return html
    }

    private enum ParserTestError: Error { case fixtureEncodingFailed }

    private func asset(_ name: String, digest: String? = nil, size: Int = 5,
                       repository: String = "robinhoo1973/Resources", tag: String = "asr-models") -> [String: Any] {
        ["name": name,
         "path": "/" + repository + "/-/releases/download/" + tag + "/" + name,
         "hashAlgo": "sha256",
         "hashValue": digest ?? String(repeating: "a", count: 64),
         "sizeInByte": size]
    }

    @Test func validPageYieldsAssetsInOrder() throws {
        let release: [String: Any] = ["tagRef": "refs/tags/asr-models",
                                      "assets": [asset("1.root.json"), asset("3.catalog.json", size: 12)]]
        let parsed = try CNBReleasePageInventoryParser.assets(fromPage: try page(release),
                                                              repository: "robinhoo1973/Resources", tag: "asr-models")
        #expect(parsed.map(\.name) == ["1.root.json", "3.catalog.json"])
        #expect(parsed[1].sizeInByte == 12)
    }

    @Test func pendingStateWithNullReleaseIsRejected() throws {
        // 实测形态(2026-10-05 探针,robinhoo1973/Resources):Release 未创建时
        // releaseDetailStatus="pending" 且 releasesDetailData=null。
        let data: [String: Any] = ["props": ["pageProps": [
            "releaseDetailStatus": "pending", "releasesDetailData": NSNull()]]]
        let literal = String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)
        guard let literal, let html = ("<script id=\"__NEXT_DATA__\">" + literal + "</script>").data(using: .utf8) else {
            throw ParserTestError.fixtureEncodingFailed
        }
        #expect(throws: (any Error).self) {
            try CNBReleasePageInventoryParser.assets(fromPage: html,
                                                     repository: "robinhoo1973/Resources", tag: "asr-models")
        }
    }

    @Test func missingScriptOrWrongTagIsRejected() throws {
        #expect(throws: (any Error).self) {
            try CNBReleasePageInventoryParser.assets(fromPage: Data("<html>none</html>".utf8),
                                                     repository: "robinhoo1973/Resources", tag: "asr-models")
        }
        let release: [String: Any] = ["tagRef": "refs/tags/other", "assets": []]
        #expect(throws: (any Error).self) {
            try CNBReleasePageInventoryParser.assets(fromPage: try page(release),
                                                     repository: "robinhoo1973/Resources", tag: "asr-models")
        }
    }

    @Test func outOfScopePathOrIncompleteMetadataIsRejected() throws {
        var bad = asset("a.zip")
        bad["path"] = "/someone/else/-/releases/download/asr-models/a.zip"
        let release: [String: Any] = ["tagRef": "refs/tags/asr-models", "assets": [bad]]
        #expect(throws: (any Error).self) {
            try CNBReleasePageInventoryParser.assets(fromPage: try page(release),
                                                     repository: "robinhoo1973/Resources", tag: "asr-models")
        }
        var noDigest = asset("a.zip")
        noDigest["hashValue"] = "not-a-digest"
        let release2: [String: Any] = ["tagRef": "refs/tags/asr-models", "assets": [noDigest]]
        #expect(throws: (any Error).self) {
            try CNBReleasePageInventoryParser.assets(fromPage: try page(release2),
                                                     repository: "robinhoo1973/Resources", tag: "asr-models")
        }
    }

    @Test func duplicateAssetNamesAreRejected() throws {
        let release: [String: Any] = ["tagRef": "refs/tags/asr-models",
                                      "assets": [asset("a.zip"), asset("a.zip")]]
        #expect(throws: (any Error).self) {
            try CNBReleasePageInventoryParser.assets(fromPage: try page(release),
                                                     repository: "robinhoo1973/Resources", tag: "asr-models")
        }
    }

    @Test func versionedAssetNameGrammarParsesAndRejects() {
        #expect(ASRModelReleaseProtocol.catalogVersion(fromAssetName: "3.catalog.json") == 3)
        #expect(ASRModelReleaseProtocol.catalogVersion(fromAssetName: "03.catalog.json") == nil)
        #expect(ASRModelReleaseProtocol.catalogVersion(fromAssetName: "catalog.json") == nil)
        #expect(ASRModelReleaseProtocol.catalogVersion(fromAssetName: "3.root.json") == nil)
        #expect(ASRModelReleaseProtocol.rootVersion(fromAssetName: "1.root.json") == 1)
        #expect(ASRModelReleaseProtocol.catalogAssetName(version: 4) == "4.catalog.json")
        #expect(ASRModelReleaseProtocol.releaseBaseURL.hasSuffix("/asr-models"))
    }
}
