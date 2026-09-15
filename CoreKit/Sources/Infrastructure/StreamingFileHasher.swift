#if os(iOS) || os(macOS)
import Foundation
import CryptoKit

/// 流式 SHA-256（结构轮 2026-09-15 自 ASRModelDownloadService 拆出）：
/// 1 MiB 分块、不把整包读进内存。整包校验（模型包）与逐文件校验（ASRModelAssets）
/// 共用同一实现（此前两处各写一遍流式循环——A4-F6 去重）。
/// 失败抛 `ASRModelDownloadService.Failure`（错误域归门面，消费点零改）。
enum StreamingFileHasher {
    static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ASRModelDownloadService.Failure.unzipFailed }   // try?-ok: 打开失败即刻换上抛，非吞没
        defer { try? handle.close() }   // try?-ok: 读句柄关闭失败由系统回收
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
