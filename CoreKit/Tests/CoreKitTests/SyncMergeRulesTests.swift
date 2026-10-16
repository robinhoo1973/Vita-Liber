import Foundation
import Testing
@testable import Domain

/// 多设备同步合并规则（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// 同设备取 max seq、跨设备全取、异 realm 拒绝、输出确定性排序。
struct SyncMergeRulesTests {

    private let realm = UUID()
    private let deviceA = UUID()
    private let deviceB = UUID()
    private let foreignRealm = UUID()

    private func candidate(_ device: UUID, _ seq: UInt64, _ realm: UUID? = nil) -> SyncCandidate {
        SyncCandidate(deviceId: device, seq: seq, realmId: realm ?? self.realm)
    }

    @Test func newestPerDeviceWins() {
        let picked = SyncMergeRules.pick([
            candidate(deviceA, 1), candidate(deviceA, 3), candidate(deviceA, 2),
            candidate(deviceB, 7), candidate(deviceB, 5),
        ], realm: realm)
        #expect(picked.foreign.isEmpty)
        #expect(picked.accepted.count == 2)
        #expect(picked.accepted.first { $0.deviceId == deviceA }?.seq == 3)
        #expect(picked.accepted.first { $0.deviceId == deviceB }?.seq == 7)
    }

    @Test func crossDeviceAllKept() {
        let picked = SyncMergeRules.pick([
            candidate(deviceA, 1), candidate(deviceB, 1),
        ], realm: realm)
        #expect(picked.accepted.count == 2)   // 跨设备全取，逐个走 ADR-019，绝不文件层挑赢家
    }

    @Test func foreignRealmRejected() {
        let picked = SyncMergeRules.pick([
            candidate(deviceA, 1),
            candidate(deviceB, 2, foreignRealm),
        ], realm: realm)
        #expect(picked.accepted.count == 1)
        #expect(picked.foreign.count == 1)
        #expect(picked.foreign.first?.realmId == foreignRealm)
    }

    @Test func deterministicOrder() {
        let first = SyncMergeRules.pick([candidate(deviceB, 2), candidate(deviceA, 1)], realm: realm)
        let second = SyncMergeRules.pick([candidate(deviceA, 1), candidate(deviceB, 2)], realm: realm)
        #expect(first.accepted == second.accepted)   // 排序键 (deviceId, seq) 与输入顺序无关
    }

    @Test func emptyInput() {
        let picked = SyncMergeRules.pick([], realm: realm)
        #expect(picked.accepted.isEmpty)
        #expect(picked.foreign.isEmpty)
    }
}
