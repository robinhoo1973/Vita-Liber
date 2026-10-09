import Foundation

/// 本机 LLM 模型安装位布局（纯函数，Linux 可测；落盘由 Infrastructure 执行）。
///
/// 布局（Application Support/LLMModels/，非 Documents——不进 iCloud 备份、
/// 用户不可见、`isExcludedFromBackup` 由落盘侧统一设置）：
/// ```
/// <id>/active.json                     # 指针（唯一就绪权威：version+fileName+bytes+sha256）
/// <id>/<version>-<sha12>/<fileName>    # 内容寻址版本目录（同卷 move 原子激活）
/// <id>/.staging-<uuid>/<fileName>.part # 续传暂存（取消/失败清理，续传点保留）
/// ```
///
/// 纪律（2026-10-09 换型批；2026-09-20 回滚根因的结构性对策）：
/// - **单一来源**：就绪判定只认此布局；Bundle 查询分支不存在（见 L0 [20] 断言）。
/// - 版本目录名携带 sha 前缀 → 同版本重发（sha 变）自然并存，绝不原地覆写。
/// - 激活序：新版本校验通过并 move 到位**之后**才写指针；指针写失败 = 旧版本继续有效。
/// - 清扫：只保留 active 指向的版本目录（历史版本在指针切换成功后删除；
///   回滚 = 重新下载——目录条目驱动，无本机旧版本回滚语义）。
public enum LLMModelInstallLayout {
    /// 暂存目录前缀（启动清扫按此前缀识别孤儿）。
    public static let stagingPrefix = ".staging-"
    /// 指针文件名。
    public static let pointerFileName = "active.json"
    /// 续传部分文件名后缀。
    public static let partialSuffix = ".part"

    /// 版本目录名：`<version>-<sha256 前 12 位>`（version 与 sha 均为目录契约校验过
    /// 的 slug/hex，拼接结果恒为单层安全目录名）。
    public static func versionDirectoryName(version: String, sha256: String) -> String {
        "\(version)-\(sha256.prefix(12))"
    }

    /// 暂存目录名（uuid 由调用方生成；此处只做命名组装）。
    public static func stagingDirectoryName(uuid: String) -> String {
        stagingPrefix + uuid
    }

    /// 暂存目录名 → uuid（非暂存目录返回 nil；清扫侧用于日志/去重）。
    public static func stagingUUID(_ directoryName: String) -> String? {
        guard directoryName.hasPrefix(stagingPrefix) else { return nil }
        let uuid = String(directoryName.dropFirst(stagingPrefix.count))
        return uuid.isEmpty ? nil : uuid
    }

    /// 有效续传偏移：仅当 0 < partialBytes < expectedBytes 时从该偏移续传；
    /// 其余（无部分文件/截断到 0/超过或等于钉版体积）一律从头下载。
    public static func resumeOffset(partialBytes: Int64?, expectedBytes: Int64) -> Int64 {
        guard let partial = partialBytes, partial > 0, partial < expectedBytes else { return 0 }
        return partial
    }

    /// 激活后清扫计划：输入某 id 下现存版本目录名集合与刚激活的目录名 →
    /// 应删除的目录名列表（active 之外全部；确定性排序便于测试与日志）。
    public static func cleanupPlan(installed: [String], active: String) -> [String] {
        installed.filter { $0 != active }.sorted()
    }

    /// 就绪判定（纯函数）：文件名与字节双钉版即可就绪；全量 sha 校验在激活期完成
    /// （冷路径一次），此处不做流式哈希（IO 属 Infrastructure）。
    public static func isReady(pointerFileName: String, onDisk: [String: Int64],
                               expectedFileName: String, expectedBytes: Int64) -> Bool {
        guard pointerFileName == expectedFileName,
              let bytes = onDisk[expectedFileName], bytes == expectedBytes else { return false }
        return true
    }
}
