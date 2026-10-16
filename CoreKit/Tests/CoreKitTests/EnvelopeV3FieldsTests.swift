import Foundation
import Testing
#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：ExportService/Envelope 整文件在 Linux 编译为空单元，本套件仅 macOS CI 执行）
@testable import Infrastructure
@testable import Domain

/// 信封 v3 可选键兼容（discussions/2026-10-16-backup-sync-share-design.md V1.7 切片 1）：
/// 旧包（无新键）解码 → nil 零恢复不猜；带值往返 → 逐字段相等；nil 时编码不落键（encodeIfPresent 语义）。
struct EnvelopeV3FieldsTests {

    /// 仅含 v2 必需键的最小合法 JSON（空数组）——合成 Codable 对 Optional 新键走 decodeIfPresent。
    private let legacyJSON = """
    {"schemaVersion":2,"exportedAt":0,"consentRecords":[],"timeline":[],"plans":[],"appointments":[],\
    "observations":[],"allergies":[],"encounters":[],"metrics":[],"immunizations":[],"voiceNotes":[],\
    "healthProblems":[],"sensitiveDocIds":[]}
    """

    private func decode(_ json: String) throws -> ExportService.Envelope {
        try JSONDecoder().decode(ExportService.Envelope.self, from: Data(json.utf8))
    }

    @Test func legacyPackageDecodesWithNilV3Keys() throws {
        let envelope = try decode(legacyJSON)
        #expect(envelope.media == nil)
        #expect(envelope.tombstones == nil)
        #expect(envelope.syncRealmId == nil)
        #expect(envelope.deviceId == nil)
        #expect(envelope.seq == nil)
    }

    @Test func v3KeysRoundTrip() throws {
        var envelope = try decode(legacyJSON)
        let media = MediaManifestEntry(sha256: String(repeating: "f", count: 64), size: 12345,
                                       mime: "image/jpeg",
                                       relativePath: MediaDestinationRules.originalRelativePath(
                                           sha256: String(repeating: "f", count: 64)),
                                       isSensitive: false, kind: .original)
        let tombstone = ExportService.Tombstone(kind: "observation", id: UUID(), deletedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let realm = UUID(); let device = UUID()
        envelope.media = [media]
        envelope.tombstones = [tombstone]
        envelope.syncRealmId = realm
        envelope.deviceId = device
        envelope.seq = 42
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ExportService.Envelope.self, from: encoded)
        #expect(decoded.media == [media])
        #expect(decoded.tombstones == [tombstone])
        #expect(decoded.syncRealmId == realm)
        #expect(decoded.deviceId == device)
        #expect(decoded.seq == 42)
    }

    @Test func nilV3KeysOmittedFromJSON() throws {
        // nil 时编码不落键（合成 Codable 对 Optional 走 encodeIfPresent）——
        // 字节级兼容旧读侧与既有金样夹具。
        let envelope = try decode(legacyJSON)
        let encoded = try JSONEncoder().encode(envelope)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("media"))
        #expect(!json.contains("tombstones"))
        #expect(!json.contains("syncRealmId"))
        #expect(!json.contains("deviceId"))
        #expect(!json.contains("seq"))
    }
}
#endif
