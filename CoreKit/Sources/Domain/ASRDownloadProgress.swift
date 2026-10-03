import Foundation

/// ASR 模型下载的值类型（2026-09-27 委员会 P3c：自 Infrastructure 升层——
/// App 视图渲染进度/阶段/失败时不再 import Infrastructure；P3b 同款
/// typealias 兼容既有调用面）。纯值类型、零 Apple 框架，Linux 可测。

/// 传输形态（P3b 先例：`ASRDownloadMode` 已迁 Domain，此处同族）。
public struct ASRDownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    /// 传输形态；`nil` = 尚未确定。
    public var mode: ASRDownloadMode? = nil
    /// 进度系列代次（审查修复 2026-09-18）：同一 totalBytes 的**重启系列**
    /// （分段被服务端吞 Range 后单流从 0 重计 / 校验/解压阶段从 0 重计）
    /// 必须换代——消费侧单调守卫按系列比较：跨系列一律放行，同系列内
    /// 才判「不增丢弃」。
    public var series: Int = 0
    /// 2026-09-20 修复：钳制 0…1——分段尝试回滚/计数修正可使 received 短时超过 total。
    public var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }

    public init(receivedBytes: Int64, totalBytes: Int64, mode: ASRDownloadMode? = nil, series: Int = 0) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.mode = mode
        self.series = series
    }

    /// 单调守卫谓词（2026-09-27 委员会测试席②：三次进度 bug 病灶提纯为纯函数）。
    /// 跨 series 一律放行（重建/换代），同 series 才判「received 不增即丢弃」。
    public static func shouldAccept(previous: ASRDownloadProgress?, incoming: ASRDownloadProgress) -> Bool {
        guard let previous else { return true }
        return incoming.series != previous.series || incoming.receivedBytes >= previous.receivedBytes
    }

    /// 确定性进度呈现谓词（2026-10-03 评审 R1-10a：视图内分支下沉为纯函数）。
    /// 有进度值且阶段属「有字节粒度」段（下载/校验/解压；nil 阶段 = 传输基线）
    /// 才画确定条——激活/清理无粒度，如实呈现不确定态；阶段切换重置基线后
    /// progress 为 nil，同样回落不确定态（见 App 侧 Install.submit 注释）。
    public static func showsDeterminateProgress(progress: ASRDownloadProgress?, phase: ASRInstallPhase?) -> Bool {
        guard progress != nil else { return false }
        guard let phase else { return true }
        switch phase {
        case .downloading, .verifying, .unpacking: return true
        case .activating, .pruning: return false
        }
    }
}

/// 安装阶段（迁移自 ASRModelDownloadService.InstallPhase）。
public enum ASRInstallPhase: String, Sendable, Equatable {
    case downloading
    case verifying
    case unpacking
    case activating
    case pruning
}

/// 下载失败词汇（迁移自 ASRModelDownloadService.Failure；2026-09-27 委员会
/// SRE 席 Top3 新增 `.insufficientStorage`——磁盘满与网络失败必须可区分，
/// ERR#27 纪律：失败诊断诚实）。
public enum ASRDownloadFailure: Error, Equatable {
    case badIndex          // 索引不合法/结构版本不支持
    case notPublished      // 条目未发布（空 sha256 / 零字节）
    case untrustedPackage  // 未登记于**构建期信任锚**或哈希不一致（fail closed）
    case badAddress        // URL 无法解析
    case badResponse(Int)  // 非 2xx
    case sizeMismatch      // 下载字节数与索引不符
    case checksumMismatch  // 整包 SHA-256 不符
    case unzipFailed
    case invalidPackage    // 包内 manifest/文件校验失败（ASRModelAssets 拒绝）
    case installFailed
    case insufficientStorage  // 磁盘空间不足（与网络失败区分，UI 给差异化恢复指引）
    case installInProgress // 已有安装进行中（actor 级互斥，防跨视图实例竞态）

    /// 磁盘满识别（纯函数，Linux 可测）：NSFileWriteOutOfSpaceError(640) 或
    /// POSIX ENOSPC(28)——FileHandle 写/Data.write/文件系统操作的常见形态。
    public static func storageError(from error: Error) -> ASRDownloadFailure? {
        let code = (error as NSError).code
        if code == 640 || code == 28 { return .insufficientStorage }
        // 底层 POSIX 28 可能被包在更外层 NSError 里
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError, underlying.code == 28 {
            return .insufficientStorage
        }
        return nil
    }
}
