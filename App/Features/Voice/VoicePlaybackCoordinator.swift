import Foundation
import AVFoundation
import Perception

/// 语音消息重放的应用级单出口（2026-10-21）。
///
/// 此前聊天页自持 `AVAudioPlayer`，TTS/录音只能靠页面内互斥；
/// 现由 AppState 持有本协调器：
/// - `AppState.speak/stopSpeaking` 先停止语音消息，TTS 不会与重放叠音；
/// - 录音入口（DictationInteraction/按压）走同一停止路径；
/// - 播放结束/解码失败复位气泡图标，离开会话/页面统一 stop。
@MainActor
@Perceptible
final class VoicePlaybackCoordinator {
    private(set) var playingID: UUID?
    private var player: AVAudioPlayer?
    private let delegate = VoicePlaybackDelegate()

    init() {
        delegate.onFinish = { [weak self] in self?.finish() }
    }

    /// 播放指定消息；同一消息再次调用由调用方先 stop（toggle 语义在视图层）。
    /// 返回 false = 文件缺失/损坏（调用方给可见失败提示）。
    @discardableResult
    func play(url: URL, id: UUID) -> Bool {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = delegate
            player.prepareToPlay()
            self.player = player
            playingID = id
            player.play()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    private func finish() {
        player = nil
        playingID = nil
    }
}

/// AVAudioPlayer.delegate 是 weak；由协调器强持有。回调只回主线程复位状态。
private final class VoicePlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor () -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidFinish(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}
