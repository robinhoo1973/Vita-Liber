#if os(iOS) || os(macOS)
// linux-blind: CryptoKit 哈希（Apple 专属模块，Linux 不可用） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import CryptoKit

/// 流式 SHA-256（结构轮 2026-09-15 自 ASRModelDownloadService 拆出）：
/// 1 MiB 分块、不把整包读进内存。整包校验（模型包）与逐文件校验（ASRModelAssets）
/// 共用同一实现（此前两处各写一遍流式循环——A4-F6 去重）。
/// 失败抛 `ASRModelDownloadService.Failure`（错误域归门面，消费点零改）。
enum StreamingFileHasher {
    /// `onProgress`: (已处理字节, 总字节)。**按百分比变化发**（最多 101 次）——
    /// 1 MB 分块对 800 MB 包会产生 800 次回调，逐次 hop 主线程是纯浪费。
    ///
    /// 2026-09-16 业主实测「下载进度条无反应、然后突然完成」：`unzip`/`sha256` 只被
    /// 当成「无进度的黑盒阶段」，界面只能转不确定 spinner，而这两段在 GB 级包上
    /// 各要数秒到数十秒——用户看到的就是「不动，然后突然结束」。
    static func sha256(of url: URL, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ASRModelDownloadService.Failure.unzipFailed }   // try?-ok: 打开失败即刻换上抛，非吞没
        defer { try? handle.close() }   // try?-ok: 读句柄关闭失败由系统回收
        let totalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0   // try?-ok: 取不到总长则只影响进度分母，不影响校验
        var hasher = SHA256()
        var processed: Int64 = 0
        var lastPercent: Int64 = -1
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            processed += Int64(chunk.count)
            let percent = totalBytes > 0 ? processed * 100 / totalBytes : 0
            if percent != lastPercent {
                lastPercent = percent
                onProgress?(processed, totalBytes)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
