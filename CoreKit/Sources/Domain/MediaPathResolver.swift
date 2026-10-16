import Foundation

/// 媒体读取路径解析（discussions/2026-10-16-local-storage-layout-council.md §7.1/Q5）——
/// 双形态读的**唯一**入口：新写形态（相对路径+original_sha256）与旧布局
/// （meta 绝对路径）经同一候选列表收敛，调用方取首个存在的候选。
/// 候选序：① meta 相对路径（新写形态，含 sensitive/{memberId}/…——敏感件绝不以
/// sha 推导 originals/ 候选）→ ② original_sha256 推导的 CAS 路径（懒回填后可用）
/// → ③ meta 绝对路径（legacy，仅同设备可解，末位兜底）。
public enum MediaPathResolver {

    /// 返回相对媒体根的候选路径（不含根前缀）；legacy 绝对路径原样返回（以 `/` 开头，
    /// 调用方须以 URL(fileURLWithPath:) 处理而非拼根）。
    public static func candidates(storedPath: String?, originalSha256: String?) -> [String] {
        var result: [String] = []
        let storedIsSensitive = storedPath.map { MediaDestinationRules.isSafeRelativePath($0) && $0.hasPrefix("sensitive/") } ?? false
        if let stored = storedPath, MediaDestinationRules.isSafeRelativePath(stored) {
            result.append(stored)
        }
        // 敏感件绝不推导 originals/ CAS 候选（路径承载敏感隔离，sha 推导只会给出错误位置）
        if !storedIsSensitive,
           let sha = originalSha256, MediaDestinationRules.isLowercaseHex64(sha) {
            let derived = MediaDestinationRules.originalRelativePath(sha256: sha)
            if !result.contains(derived) { result.append(derived) }
        }
        if let stored = storedPath, !stored.isEmpty, !MediaDestinationRules.isSafeRelativePath(stored) {
            result.append(stored)
        }
        return result
    }
}
