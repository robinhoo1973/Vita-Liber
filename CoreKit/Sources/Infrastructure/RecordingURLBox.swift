import Foundation

/// 录音目标 URL 的线程安全信箱（2026-10-19）：引擎在 coordinator 构造闭包中读取
/// 当前值，调用方在 `transcribe` 前写入。仅本机路径字符串，零音频字节。
final class RecordingURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    var value: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    func set(_ url: URL?) {
        lock.lock(); self.url = url; lock.unlock()
    }
}
