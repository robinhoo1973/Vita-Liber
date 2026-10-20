import Foundation

/// 采集电平广播（2026-10-20）：聊天内语音波形的唯一读面。
///
/// 单一活跃采集会话：`AudioFileRecorder` 在写本机音频的同一缓冲上计算 RMS
/// 并 `emit`；当前 `VoiceDictationModel` 注册 handler 消费。节流在 emit 侧
/// （≥50 ms 或电平变化 ≥0.02），避免 48 kHz 每个 buffer 都驱动 SwiftUI 重算。
public final class AudioLevelMonitor: @unchecked Sendable {
    public static let shared = AudioLevelMonitor()

    private let lock = NSLock()
    private var handler: (@Sendable (Float) -> Void)?
    private var lastEmit = Date.distantPast
    private var lastValue: Float = -1

    public func setHandler(_ handler: (@Sendable (Float) -> Void)?) {
        lock.lock()
        self.handler = handler
        lastEmit = .distantPast
        lastValue = -1
        lock.unlock()
    }

    /// 归一化 RMS（0…1）。无 handler 时零开销。
    public func emit(_ rms: Float) {
        lock.lock()
        let now = Date()
        if now.timeIntervalSince(lastEmit) < 0.05, abs(rms - lastValue) < 0.02 {
            lock.unlock()
            return
        }
        lastEmit = now
        lastValue = rms
        let sink = handler
        lock.unlock()
        sink?(rms)
    }
}
