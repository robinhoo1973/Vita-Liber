import Foundation
import Domain

/// 媒体载具端口（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// 附件/语音原件经 `.vlbm` 载具随包——内容寻址（sha256）幂等 + 增量；
/// Infrastructure 实现（ZIPFoundation 目录容器），blob 写载具前逐块加密由加密层承担。
public protocol MediaPackaging: Sendable {

    /// 暂存一个原件 blob：目标文件已存在（同设备重复备份/同步增量命中）→ nil（零复制）。
    func stage(sha256: String) async throws -> URL?

    /// 收尾载具：manifest 写入 `manifest.json`、整目录打成 `.vlbm` 压缩容器，返回清单内容。
    func commit(to carrierURL: URL) async throws -> MediaManifest

    /// 逐 sha256 校验落盘：`originals/{sha256 前 2}/{sha256}.bin`；
    /// is_sensitive 原件直写 `sensitive/{memberId}/` 目录（FileProtectionType.complete，不落临时明文路径）。
    /// 已在库 → alreadyPresent；清单有而载具缺字节 → missing（绝不伪造恢复）。
    func importMedia(_ carrier: URL) async throws -> MediaImportReport
}
