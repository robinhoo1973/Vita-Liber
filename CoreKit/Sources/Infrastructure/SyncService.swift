#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：依赖 BackupService/iCloud 通道仅 Apple 平台，Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import Domain
import Protocols

/// 多设备同步编排（discussions/2026-10-16-backup-sync-share-design.md §8.5 批次 2）：
/// push = 同步信封（createBackup syncIdentity 管线）+ 落 per-device 文件；
/// fetchAccepted = 通道全量候选 → SyncMergeRules 预选（异 realm 拒绝/同设备 max seq）→
/// 返回语义合并输入——**本服务绝不自行导入**：ADR-019 三选一由 App 层经既有恢复流程
/// 逐候选执行（与恢复同构，UI 复用冲突三列/影响清单）。
public actor SyncService {

    private let channel: any SyncChannel
    private let backup: BackupService
    /// 最近一次 push 未面世的恢复码（评审修复，恢复码链断点）：commit 失败=信封
    /// 未落云端，但 createBackup 已注册主密钥并生成码——重试恒返回 nil 码（master 已在位），
    /// 不取回即永久丢失。取走即清（展示即最后机会，与 BackupService 同纪律）。
    private var unseenRecoveryCode: String?

    public init(channel: any SyncChannel, backup: BackupService) {
        self.channel = channel
        self.backup = backup
    }

    /// 取走未面世的恢复码（nil = 无丢失面）
    public func takeUnseenRecoveryCode() -> String? {
        defer { unseenRecoveryCode = nil }
        return unseenRecoveryCode
    }

    /// 恢复码卡片确认穿透（评审修复，恢复码静默死亡窗）：包裹段在用户确认前
    /// 不落钥——确认动作必须到达 BackupService，否则下次运行重铸新码。
    public func confirmRecoveryCodeSaved() async {
        await backup.persistPendingRecoveryWrapped()
    }

    /// 推送本机快照：seq 由调用方维护（每次 push +1，同设备单调）；
    /// 同设备多版本保留最近 3 份再回收由 App 层调度（保守回收，绝不删最新）。
    /// 返回 BackupPackage（评审修复）：首次 push 若触发主密钥注册，recoveryCode 必须
    /// 一次性展示——原实现 void 丢弃，恢复码「展示即最后机会」从未面世（零知识链断头）。
    /// 同步通道只承载信封字节——includeMedia=false（原实现每轮 push 全量读+加密媒体载具，
    /// 随后 package 只取 data、载具即弃：每轮 O(媒体总量) 纯浪费）。
    @discardableResult
    public func push(realmId: UUID, deviceId: UUID, seq: UInt64) async throws -> BackupService.BackupPackage {
        let identity = SyncFileNaming.Identity(realmId: realmId, deviceId: deviceId, seq: seq)
        let package: BackupService.BackupPackage
        do {
            package = try await backup.createBackup(encrypted: true, syncIdentity: identity, includeMedia: false)
        } catch {
            // createBackup 半程失败（密封/钥匙串后半程）也可能已注册主密钥 + 生成码——
            // 取回暂存，绝不静默丢弃（评审修复）
            if let stillborn = await backup.takeUnseenRecoveryCode() {
                unseenRecoveryCode = stillborn
            }
            throw error
        }
        // 成功路径排空 BackupService 侧暂存：码随 package 已交付调用方；
        // 若 package 无码但存在残留（上轮半程失败），一并取回供失败/成功路径展示。
        // 优先级（评审修复）：本轮 package 的码恒为最新有效码——补发/重注册一旦发生，
        // 旧暂存码对应的包裹段已被覆盖（死码）；此前陈码先占（?? 次序）会把新鲜码挤出暂存。
        let drained = await backup.takeUnseenRecoveryCode()
        unseenRecoveryCode = package.recoveryCode ?? unseenRecoveryCode ?? drained
        do {
            try await channel.commit(package.data, identity: identity)
        } catch {
            // commit 失败 = 信封未落云端：码未随任何包面世，暂存供调用方失败路径取回
            // （同优先级：本轮 mint 的码优先于陈旧暂存）
            unseenRecoveryCode = package.recoveryCode ?? unseenRecoveryCode
            throw error
        }
        return package
    }

    /// 拉取并预选：返回本同步域内待合并候选（同 deviceId 已取 max seq；
    /// 异 realm 候选已在通道层排除）——排序确定性供审计与测试。
    public func fetchAccepted(realm: UUID) async throws -> [SyncEnvelopeCandidate] {
        let all = try await channel.fetchEnvelopes()
        let picked = SyncMergeRules.pick(all.map(\.identity), realm: realm)
        let acceptedSet = Set(picked.accepted)
        return all.filter { acceptedSet.contains($0.identity) }
            .sorted { ($0.deviceId.uuidString, $0.seq) < ($1.deviceId.uuidString, $1.seq) }
    }
}
#endif
