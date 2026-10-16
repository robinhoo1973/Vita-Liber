import Foundation
import Domain

/// 媒体载具端口（discussions/2026-10-16-local-storage-layout-council.md §8 切片 9）：
/// `.vlbm` 载具 = `manifest.json + media/{sha256 前 2}/{sha256}.bin`（zip 内路径），
/// 内容寻址（sha256）幂等 + 增量；blob 写载具前经 MediaBlobSealing 加密（载具内只存密文），
/// 清单仍为明文哈希（哈希=防损坏语义，防篡改由 AES-GCM 承担——BackupCrypto 帧复用）。
/// 落盘路径（importMedia）：`originals/{sha2}/{sha}.bin`（非敏感）/
/// `sensitive/{memberId}/{…}`（敏感，FileProtectionType.complete，不落临时明文文件）。
public protocol MediaPackaging: Sendable {

    /// 暂存一个原件 blob：读源文件 → 校验明文哈希与 entry.sha256 一致 → 加密 → 写入 staging。
    /// 载具已含同 sha → nil（同设备重复备份零复制）；源缺失 → sourceMissing；哈希不符 → shaMismatch。
    func stage(sourceURL: URL, entry: MediaManifestEntry) async throws -> URL?

    /// 收尾载具：manifest.json 写入 `manifest.json`（entries 由调用方显式传入——跨会话安全）、
    /// 整目录打成 `.vlbm` 压缩容器，返回清单内容。空清单拒绝（绝不产出无条目的载具）。
    func commit(to carrierURL: URL, entries: [MediaManifestEntry]) async throws -> MediaManifest

    /// 逐条目校验落盘：解压 → 解密 → 明文哈希与 entry.sha256 比对 → 按 entry.relativePath 落盘
    /// （敏感条目直写 sensitive/ 目录 + .complete）；已在库 → alreadyPresent（绝不复写）；
    /// 清单有而载具缺字节/哈希不符/路径非法 → missing（绝不伪造恢复）。
    func importMedia(_ carrier: URL) async throws -> MediaImportReport
}
