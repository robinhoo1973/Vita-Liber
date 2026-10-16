import Foundation

/// 同步候选——每设备信封头的最小身份三元组。
/// 信封本体在 Infrastructure，规则层零依赖（Domain 纯函数，Linux 可跑）。
public struct SyncCandidate: Sendable, Equatable {
    public let deviceId: UUID
    public let seq: UInt64
    public let realmId: UUID
    public init(deviceId: UUID, seq: UInt64, realmId: UUID) {
        self.deviceId = deviceId
        self.seq = seq
        self.realmId = realmId
    }
}

/// 多设备同步合并规则（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// - 同 deviceId 取 max seq——单写者自身历史，LWW 安全（iCloud 文档容器 modificationDate 不可靠，seq 单调不可省）；
/// - 跨 deviceId 全取——多信封逐个走 ADR-019 三选一，绝不文件层挑赢家；
/// - realmId 不匹配 = 跨账户信封，拒绝入合并（防跨库污染，FR21.6 权限边界）。
public enum SyncMergeRules {

    public struct Picked: Sendable, Equatable {
        public let accepted: [SyncCandidate]
        public let foreign: [SyncCandidate]
    }

    /// 合并前预选：按 realm 分流 + 同设备取最新 seq；输出确定性排序（deviceId, seq）供测试与审计。
    public static func pick(_ candidates: [SyncCandidate], realm: UUID) -> Picked {
        var same: [SyncCandidate] = []
        var foreign: [SyncCandidate] = []
        for candidate in candidates {
            if candidate.realmId == realm { same.append(candidate) } else { foreign.append(candidate) }
        }
        var newestByDevice: [UUID: SyncCandidate] = [:]
        for candidate in same {
            if let existing = newestByDevice[candidate.deviceId] {
                if candidate.seq > existing.seq { newestByDevice[candidate.deviceId] = candidate }
            } else {
                newestByDevice[candidate.deviceId] = candidate
            }
        }
        let accepted = newestByDevice.values.sorted {
            ($0.deviceId.uuidString, $0.seq) < ($1.deviceId.uuidString, $1.seq)
        }
        return Picked(accepted: accepted, foreign: foreign)
    }
}
