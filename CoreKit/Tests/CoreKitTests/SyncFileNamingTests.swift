import Foundation
import Testing
@testable import Domain

/// 同步信封文件名契约（discussions/2026-10-16-backup-sync-share-design.md §5.3，Linux 可跑）。
struct SyncFileNamingTests {

    @Test func encodeDecodeRoundTrip() {
        let identity = SyncFileNaming.Identity(realmId: UUID(), deviceId: UUID(), seq: 42)
        let name = SyncFileNaming.encode(identity)
        #expect(name.hasPrefix("sync-"))
        #expect(name.hasSuffix(".vlbu"))
        #expect(SyncFileNaming.decode(name) == identity)
    }

    @Test func rejectsForeignNames() {
        // 杂散文件/旧命名/坏 seq 一律 nil——目录里任何非契约文件不得入合并
        #expect(SyncFileNaming.decode("backup-123.vlbu") == nil)
        #expect(SyncFileNaming.decode("sync-\(UUID())-\(UUID())-abc.vlbu") == nil)
        #expect(SyncFileNaming.decode("sync-\(UUID())-\(UUID())-.vlbu") == nil)
        #expect(SyncFileNaming.decode("\(UUID())-\(UUID())-7.vlbu") == nil)
        #expect(SyncFileNaming.decode("sync-\(UUID())-\(UUID())-7.json") == nil)
        #expect(SyncFileNaming.decode(".DS_Store") == nil)
    }

    @Test func seqOverflowRejected() {
        let name = "sync-\(UUID().uuidString)-\(UUID().uuidString)-18446744073709551616.vlbu"   // 2^64——UInt64 溢出
        #expect(SyncFileNaming.decode(name) == nil)
    }

    @Test func candidateIdentityView() {
        let realm = UUID(); let device = UUID()
        let candidate = SyncEnvelopeCandidate(realmId: realm, deviceId: device, seq: 5, data: Data([1]))
        #expect(candidate.identity == SyncCandidate(deviceId: device, seq: 5, realmId: realm))
    }
}
