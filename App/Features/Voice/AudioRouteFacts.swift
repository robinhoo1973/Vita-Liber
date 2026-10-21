import Foundation
import AVFoundation

/// 音频路由判定的单源（2026-10-21）。
///
/// 自检页的输入设备名/低音量阈值，与确认卡 `AudioRouteMonitor` 的
/// 「是否耳机输出」此前各写一份端口集合；插拔/蓝牙切换后两处漂移会让
/// 界面提示与回读策略互相矛盾。端口集合与人类可读名集中在这里。
enum AudioRouteFacts {
    static let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
    ]

    static func hasHeadphoneOutput(_ route: AVAudioSession) -> Bool {
        route.currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    /// 输入路由增益差异：蓝牙 HFP/LE 与有线/外接麦低于内置麦，
    /// 「音量偏低」阈值按路由下调，避免用户对着正确设备白喊。
    static func lowThreshold(for portType: AVAudioSession.Port?) -> Float {
        switch portType {
        case .bluetoothHFP, .bluetoothLE: return 0.012
        case .headsetMic, .usbAudio: return 0.02
        default: return 0.03
        }
    }

    static func deviceName(for port: AVAudioSessionPortDescription?) -> String {
        guard let port else { return "" }
        let name = port.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        switch port.portType {
        case .builtInMic: return L10n.voiceguide_micDeviceBuiltIn
        case .headsetMic: return L10n.voiceguide_micDeviceHeadset
        case .bluetoothHFP: return L10n.voiceguide_micDeviceBluetooth
        case .usbAudio: return L10n.voiceguide_micDeviceUSB
        case .carAudio: return L10n.voiceguide_micDeviceCar
        default: return L10n.voiceguide_micDeviceGeneric
        }
    }
}
