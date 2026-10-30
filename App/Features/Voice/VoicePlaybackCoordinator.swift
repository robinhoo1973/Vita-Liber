import Foundation
import AVFoundation
import Perception

/// 语音消息重放的应用级单出口（2026-10-21；2026-10-30 增加播放器状态）。
///
/// 此前聊天页自持 `AVAudioPlayer`，TTS/录音只能靠页面内互斥；
/// 现由 AppState 持有本协调器：
/// - `AppState.speak/stopSpeaking` 先停止语音消息，TTS 不会与重放叠音；
/// - 录音入口（DictationInteraction/按压）走同一停止路径；
/// - 播放结束/解码失败复位气泡图标，离开会话/页面统一 stop。
///
/// 2026-10-30 业主（语音详情页，mock v4 第 7 帧）：协调器暴露
/// 进度/总时长/倍速，供详情页画进度条与 ±15 秒；状态仍只有
/// 一个播放器、一个出口，不在视图层再建第二套 AVAudioPlayer。
@MainActor
@Perceptible
final class VoicePlaybackCoordinator {
    private(set) var playingID: UUID?
    /// 当前音频总时长（秒；未播放 = 0）。
    private(set) var duration: TimeInterval = 0
    /// 当前播放位置（秒；ticker 约 5Hz 刷新）。
    private(set) var elapsed: TimeInterval = 0
    /// 播放倍速（1 / 1.5 / 2；跨重放保留，与常见语音播放器一致）。
    private(set) var rate: Float = 1
    /// 当前是否正在出声（暂停态 false）。作为可观察存储属性而非计算属性：
    /// 详情页暂停后，聊天气泡的播放/暂停图标必须随 Perception 一起刷新。
    private(set) var isAudible = false

    private var player: AVAudioPlayer?
    private var delegate: VoicePlaybackDelegate?
    private var ticker: Timer?
    /// 播放代次：旧播放器晚到的完成回调不得清掉新播放器的状态
    /// （用户连续点两条语音、或上一段自然结束回调与新播放同时到达）。
    private var generation: UInt64 = 0

    /// 播放指定消息；同一消息再次调用由调用方先 stop（toggle 语义在视图层）。
    /// 返回 false = 文件缺失/损坏/无法播放（调用方给可见失败提示）。
    @discardableResult
    func play(url: URL, id: UUID) -> Bool {
        play(url: url, id: id, rate: rate)
    }

    @discardableResult
    func play(url: URL, id: UUID, rate requestedRate: Float) -> Bool {
        stop()
        rate = Self.normalizedRate(requestedRate)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let token = generation
            let delegate = VoicePlaybackDelegate()
            delegate.onFinish = { [weak self] in self?.finish(token: token) }
            player.delegate = delegate
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.delegate = delegate
            self.player = player
            playingID = id
            duration = max(0, player.duration)
            elapsed = 0
            // play() 返回 false = 解码/路由失败（旧视图层实现会显式提示）；
            // 不能只凭 AVAudioPlayer 构造成功就报成功。
            guard player.play() else {
                stop()
                return false
            }
            isAudible = true
            startTicker()
            return true
        } catch {
            stop()
            return false
        }
    }

    func stop() {
        generation &+= 1
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        delegate = nil
        playingID = nil
        duration = 0
        elapsed = 0
        isAudible = false
    }

    // MARK: - 详情页播放器控制（2026-10-30）

    func isPlaying(id: UUID) -> Bool { playingID == id && isAudible }

    /// 暂停/继续（只作用于当前播放器；无播放器时 no-op）。
    func togglePause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            ticker?.invalidate()
            ticker = nil
        } else {
            guard player.play() else { return }
            startTicker()
        }
        isAudible = player.isPlaying
        refreshProgress()
    }

    /// ±15 秒；越界夹到 [0, duration]。
    func seek(by delta: TimeInterval) {
        guard let player else { return }
        let target = min(max(0, player.currentTime + delta), max(0, player.duration))
        player.currentTime = target
        refreshProgress()
    }

    /// 1 → 1.5 → 2 → 1；当前播放器立即应用。
    @discardableResult
    func cycleRate() -> Float {
        let next: Float
        switch rate {
        case 1: next = 1.5
        case 1.5: next = 2
        default: next = 1
        }
        rate = next
        player?.rate = next
        return next
    }

    /// 进度刷新（ticker 与手动 seek 共用）。
    func refreshProgress() {
        guard let player else { return }
        duration = max(0, player.duration)
        elapsed = min(max(0, player.currentTime), duration)
        isAudible = player.isPlaying
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func finish(token: UInt64) {
        guard token == generation else { return }
        ticker?.invalidate()
        ticker = nil
        player = nil
        delegate = nil
        playingID = nil
        elapsed = 0
        duration = 0
        isAudible = false
    }

    private static func normalizedRate(_ value: Float) -> Float {
        switch value {
        case 1.5: return 1.5
        case 2: return 2
        default: return 1
        }
    }
}

/// AVAudioPlayer.delegate 是 weak；由协调器强持有。回调只回主线程复位状态。
private final class VoicePlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor () -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}
