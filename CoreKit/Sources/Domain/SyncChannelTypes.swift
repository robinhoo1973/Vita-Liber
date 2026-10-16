import Foundation

/// 同步候选信封——文件名身份三元组 + 包字节（合并预选与导入的载体）。
/// 同 deviceId 取 max seq（单写者历史 LWW 安全）；跨 deviceId 全取逐个走 ADR-019；
/// 异 realm 拒绝入合并（FR21.6 权限边界，防跨库污染）。
public struct SyncEnvelopeCandidate: Sendable, Equatable {
    public var realmId: UUID
    public var deviceId: UUID
    public var seq: UInt64
    public var data: Data
    public init(realmId: UUID, deviceId: UUID, seq: UInt64, data: Data) {
        self.realmId = realmId
        self.deviceId = deviceId
        self.seq = seq
        self.data = data
    }

    /// 身份三元组视图（SyncMergeRules 输入）
    public var identity: SyncCandidate {
        SyncCandidate(deviceId: deviceId, seq: seq, realmId: realmId)
    }
}
