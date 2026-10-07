import Domain
import Foundation
import Infrastructure
import Testing

/// SP-64 通告面：载荷契约 / JSON 解码 / floor 决策与落盘（纯 Foundation，Linux 可跑）。
/// 委员会 R2.1-R2.9 的类型面：封闭集无 upToDate；同版异文=不可用；回退=陈旧。
@Suite("SP-64 通告面 · 契约与 floor")
struct UpdateAdviceContractTests {
    @Test func identityPrefixGrammar() {
        let hex = String(repeating: "a", count: 64)
        #expect(UpdateAdvicePayloadContract.isValidIdentity("update-payload-" + hex))
        #expect(!UpdateAdvicePayloadContract.isValidIdentity("update-payload-" + String(repeating: "A", count: 64)))
        #expect(!UpdateAdvicePayloadContract.isValidIdentity("update-payload-" + hex + "x"))
        #expect(!UpdateAdvicePayloadContract.isValidIdentity(hex))
        #expect(UpdateAdvicePayloadContract.identityPrefixLength == 79)
    }

    @Test func identityFromPrefixBytes() {
        let hex = String(repeating: "b", count: 64)
        let prefix = Data(("update-payload-" + hex).utf8)
        #expect(UpdateAdvicePayloadContract.identity(fromPrefix: prefix) == "update-payload-" + hex)
        #expect(UpdateAdvicePayloadContract.identity(fromPrefix: prefix.dropLast()) == nil)
        #expect(UpdateAdvicePayloadContract.identity(fromPrefix: Data([0xFF, 0xFE])) == nil)
    }

    @Test func payloadDecodesAndIgnoresUnknownFields() throws {
        let json = """
        {"schemaVersion":1,"payloadVersion":3,"generatedAt":"2026-10-07T00:00:00Z",
         "repository":"robinhoo1973/Resources","producer":{"pipeline":"x"},
         "unknownExtra":{"a":1},
         "releases":[{"tag":"asr-models","title":"t","releasePageURL":"u","state":"published",
                      "publishedAt":"p","latest":[{"name":"a.zip","url":"u","size":1,"sha256":"h",
                      "kind":"package","family":"whisper"}],
                      "unclassified":[],"history":[],"historyEvicted":0}]}
        """
        let payload = try JSONDecoder().decode(UpdateAdvicePayload.self, from: Data(json.utf8))
        #expect(payload.schemaVersion == 1)
        #expect(payload.payloadVersion == 3)
        #expect(payload.releases.first?.tag == "asr-models")
        #expect(payload.releases.first?.latest.first?.name == "a.zip")
    }

    @Test func floorRulesBaseline() {
        #expect(UpdateAdviceFloorRules.baselineState(observedVersion: 3, observedIdentity: "a",
                                                     floorVersion: nil, floorIdentity: nil) == nil)
        #expect(UpdateAdviceFloorRules.baselineState(observedVersion: 2, observedIdentity: "a",
                                                     floorVersion: 3, floorIdentity: "b") == .stale)
        #expect(UpdateAdviceFloorRules.baselineState(observedVersion: 3, observedIdentity: "a",
                                                     floorVersion: 3, floorIdentity: "b") == .unavailable)
        #expect(UpdateAdviceFloorRules.baselineState(observedVersion: 3, observedIdentity: "a",
                                                     floorVersion: 3, floorIdentity: "a") == nil)
        #expect(UpdateAdviceFloorRules.baselineState(observedVersion: 4, observedIdentity: "a",
                                                     floorVersion: 3, floorIdentity: "b") == nil)
    }
}

@Suite("SP-64 通告面 · floor 落盘")
struct UpdateAdviceFloorStoreTests {
    private func makeStore() -> (UpdateAdviceFloorStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // try?-ok: 临时目录
        return (UpdateAdviceFloorStore(fileURL: dir.appendingPathComponent("floor.json")), dir)
    }

    @Test func acceptAdvancesAndPersists() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 临时目录清理
        try store.accept(payloadVersion: 3, identityHex: String(repeating: "c", count: 64))
        #expect(store.observedFloor?.payloadVersion == 3)
        let reloaded = UpdateAdviceFloorStore(fileURL: dir.appendingPathComponent("floor.json"))
        #expect(reloaded.observedFloor?.payloadVersion == 3)
    }

    @Test func rollbackAndEquivocationRejected() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 临时目录清理
        let hex = String(repeating: "c", count: 64)
        try store.accept(payloadVersion: 5, identityHex: hex)
        #expect(throws: UpdateAdviceFloorStore.Failure.rollback) {
            try store.accept(payloadVersion: 4, identityHex: hex)
        }
        #expect(throws: UpdateAdviceFloorStore.Failure.equivocation) {
            try store.accept(payloadVersion: 5, identityHex: String(repeating: "d", count: 64))
        }
        try store.accept(payloadVersion: 5, identityHex: hex) // 同版同 identity = 幂等
    }

    @Test func corruptStateMeansNoFloor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 临时目录清理
        let url = dir.appendingPathComponent("floor.json")
        try Data("not json".utf8).write(to: url)
        #expect(UpdateAdviceFloorStore(fileURL: url).observedFloor == nil)
    }
}
