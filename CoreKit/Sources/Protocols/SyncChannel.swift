import Foundation
import Domain

/// 同步通道端口（discussions/2026-10-16-backup-sync-share-design.md §8.5 批次 2）：
/// 承载端到端加密同步信封（复用 .vlbu 谱系，密钥用户持有，开发者零服务器）；
/// 文件层绝不挑赢家——全部版本作为候选信封上抛，语义合并由 SyncMergeRules+ADR-019 承担。
/// Infrastructure 实现 = iCloud 文档容器（NSFileCoordinator 协调 + 占位文件落地）。
public protocol SyncChannel: Sendable {

    /// 枚举容器内全部同步信封（含 .icloud 占位——内部触发下载后再读）；
    /// 目录不存在 → 空数组；单个文件损坏/解析失败 → 跳过并计入诊断（绝不整体失败）。
    func fetchEnvelopes() async throws -> [SyncEnvelopeCandidate]

    /// 落一个同步信封（文件名 = SyncFileNaming 编码；已存在同文件名 → 替换，
    /// 同设备多版本保留最近 3 份再回收由调用方调度）。
    func commit(_ data: Data, identity: SyncFileNaming.Identity) async throws
}
