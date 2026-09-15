#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import Domain

/// 三轨共用的音频采集控制器（结构轮 2026-09-15，A4-F3）：
/// 此前基线轨（`NativeSpeechSessionDriver`）与 sherpa 轨（`SherpaSpeechSessionDriver`）
/// 各持一份逐字重复的采集实现——共享会话快照对称、AVAudioEngine/tap 安装、PCMBuffer
/// 拷贝、配置变更/中断观察者、拆除还原全靠人工同步。该重复的代价有实证：修复注释
/// 记录的「主轨已修、降级轨漏修」两次（音频会话还原、观察者补齐）。
///
/// 本次统一取两版并集中**语义更安全者**（顺带修复既存缺口）：
/// - 采集激活失败：快照在场即还原（SFSpeech 版语义；sherpa 版此前直抛不还原——
///   失败后共享会话停留在 .record，后续 TTS/回读全部错路由）；
/// - format 非法：先经 `stop()` 还原会话再抛 `engineUnavailable`（两版此前都
///   直接抛，会话停留 .record）；
/// - 单块字节上限：由 `Configuration.maximumChunkBytes` 注入（此前 tap 内每次
///   现造 `SpeechSessionLimits()`，与邮箱侧各自持有不同默认实例）。
final class AudioCaptureController: @unchecked Sendable {
    struct Configuration: Sendable {
        var bufferSize: AVAudioFrameCount = 1024
        var maximumChunkBytes: Int

        /// 生产默认：与既有 `SpeechSessionLimits` 同源。
        static var standard: Configuration {
            Configuration(maximumChunkBytes: SpeechSessionLimits().maximumBufferedBytes)
        }
    }

    private var audio: AVAudioEngine?
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
    private var sessionState: AudioSessionCapture.State?
    #endif

    /// 安装 tap 并启动引擎。`onBuffer` 收到 (深拷贝缓冲, 源字节数)——拷贝与字节上限
    /// 校验在控制器内完成，调用方只负责把缓冲包装成各自的 chunk 类型；
    /// `onFailure` 在拷贝失败/超限/引擎配置变更/中断时调用（语义与两版一致）。
    func start(configuration: Configuration,
               onFormat: ((AVAudioFormat) throws -> Void)? = nil,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Int) -> Void,
               onFailure: @escaping @Sendable () -> Void,
               isStopped: @escaping @Sendable () -> Bool) throws {
        guard !isStopped() else { throw CancellationError() }
        #if os(iOS)
        // 采集激活单一出口 + 先记状态后激活：setActive 失败时类别已被修改，
        // 快照在场即保证拆除路径必还原（共享会话不再有停留在 .record 的窗口）。
        let prior = AudioSessionCapture.remember()
        sessionState = prior
        do { try AudioSessionCapture.activateRecordSession() }
        catch {
            AudioSessionCapture.restore(prior)
            sessionState = nil
            throw error
        }
        #endif
        let engine = AVAudioEngine()
        audio = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()   // 会话还原 + 引擎清理单出口
            throw TranscriptionError.engineUnavailable
        }
        if let onFormat {
            do { try onFormat(format) }
            catch { stop(); throw error }   // 调用方装配失败（如转换器层级不支持）：还原会话并清理
        }
        guard !isStopped() else { stop(); throw CancellationError() }
        input.installTap(onBus: 0, bufferSize: configuration.bufferSize, format: format) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            guard let copied = AudioBufferCopier.copy(buffer, maximumBytes: configuration.maximumChunkBytes) else {
                onFailure()
                return
            }
            onBuffer(copied.buffer, copied.byteCount)
        }
        tapInstalled = true
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                 object: engine, queue: nil) { _ in onFailure() })
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                 object: nil, queue: nil) { _ in onFailure() })
        #endif
        guard !isStopped() else { stop(); throw CancellationError() }
        engine.prepare()
        try engine.start()
        if isStopped() { stop(); throw CancellationError() }
    }

    /// 拆除单一出口（幂等）：观察者移除 → 引擎停止 + tap 移除 → 会话快照对称还原。
    /// 只停用不还原类别会让共享会话停留在 .record——其后的 FR17.13 回读 /
    /// FR17.11 提问朗读 / FR19.3 播报全部路由到听筒（该缺陷曾在主轨修、降级轨复现）。
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let audio {
            audio.stop()
            if tapInstalled { audio.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        audio = nil
        #if os(iOS)
        if let prior = sessionState {
            AudioSessionCapture.restore(prior)
            sessionState = nil
        }
        #endif
    }
}

/// PCMBuffer 深拷贝（memcpy 逐平面）——三轨此前各写一份同款循环。
enum AudioBufferCopier {
    /// 拷贝并返回源字节数；超上限或分配/平面不匹配时返回 nil（调用方按失败路径处理）。
    static func copy(_ buffer: AVAudioPCMBuffer, maximumBytes: Int) -> (buffer: AVAudioPCMBuffer, byteCount: Int)? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let byteCount = source.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard byteCount <= maximumBytes,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard destination.indices.contains(index),
                  source[index].mDataByteSize == destination[index].mDataByteSize,
                  let from = source[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return (copy, byteCount)
    }
}
#endif
