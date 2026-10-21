#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import AVFoundation
import Protocols

/// 采集缓冲 → 本机音频文件（聊天语音消息重放；2026-10-19）。
/// 只做旁路写入：采集/识别主链路不等待磁盘（写入失败静默停止，
/// 不阻断识别——`try?` 为有意的降级）。
public final class AudioFileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    /// 首次写盘失败后闩锁：不在音频线程逐 buffer 重试，也不留下半写文件。
    private var writeFailed = false
    private let emitsLevel: Bool
    private let maxFrames: AVAudioFramePosition?
    private var writtenFrames: AVAudioFramePosition = 0

    /// `emitsLevel=false` 供音量自检等不应广播电平的旁路；`maxFrames` 限制
    /// 临时试听片段（如 20s），避免页面停留时无限增长。
    public init?(url: URL, format: AVAudioFormat, emitsLevel: Bool = true,
                 maxFrames: AVAudioFramePosition? = nil) {
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            return nil
        }
        self.emitsLevel = emitsLevel
        self.maxFrames = maxFrames
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        // 实时电平（2026-10-20）：与录音旁路共用同一缓冲，不额外安装音频 tap
        //（同一 input bus 二次 tap 会顶掉识别引擎的采集）。
        if emitsLevel, let channel = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            if count > 0 {
                var sum: Float = 0
                for i in 0..<count { let sample = channel[i]; sum += sample * sample }
                AudioLevelMonitor.shared.emit(sqrt(sum / Float(count)))
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard !writeFailed, let file else { return }
        if let maxFrames, writtenFrames >= maxFrames { return }
        do {
            try file.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeFailed = true
            self.file = nil
        }
    }

    public func finish() {
        lock.lock(); defer { lock.unlock() }
        file = nil
    }
}
#endif
