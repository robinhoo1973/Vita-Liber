import Foundation
import AVFoundation

/// 音频输出路由判定的单源。
///
/// 确认卡回读策略需要判断是否耳机输出；端口集合集中在这里，避免
/// 插拔/蓝牙切换后各处分类漂移。
enum AudioRouteFacts {
    static let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
    ]

    static func hasHeadphoneOutput(_ route: AVAudioSession) -> Bool {
        route.currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }
}
