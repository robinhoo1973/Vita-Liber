import Foundation
import Domain
#if canImport(Darwin)
import Darwin
#endif

/// 进程可用内存探针（round5 Q3）：`ModelMemoryBudget` 的唯一数据源。
/// - iOS 13+ / macOS 无对应 API：`os_proc_available_memory()` 仅 iOS/iPadOS 可用——返回本进程在被 jetsam 终止前还能分配的字节数
///   （比物理 RAM 更贴近真实上限）；
/// - 其他平台 / 不可用 → nil（策略侧 fail-open：未知不拒，已知不足才拒）。
/// 探针只读、无副作用；纯策略在 Domain，本类型只负责取数。
public enum ProcessMemory {
    public static func availableBytes() -> Int64? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int64(bytes) : nil
        #else
        return nil
        #endif
    }
}

/// 崩溃环断路标记的落盘（round5 Q3）：Application Support 下单文件；加载前写、成功后删。
/// 启动/预热前读到同身份标记 → 上次加载未完成（jetsam / `SHERPA_ONNX_EXIT`），本会话不自动预热该模型。
public struct LoadAttemptMarkerStore: Sendable {
    private let url: URL

    public init(directory: URL? = nil, fileName: String = "asr-load-attempt.json") {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent(fileName)
    }

    public func current() -> LoadAttemptMarker? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return LoadAttemptMarker.decode(data)
    }

    /// 加载开始：写标记（目录缺失即建；写失败不阻断加载——断路器是纵深防御不是门禁）。
    public func begin(identity: String) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LoadAttemptMarker(identity: identity).encoded().write(to: url, options: .atomic)
        } catch { /* 标记写失败：无断路保护但不影响加载本身 */ }
    }

    /// 加载成功：清标记。
    public func finish() {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { /* 残留标记下次启动会误报一次「上次未完成」——可接受的保守侧 */ }
        }
    }
}
