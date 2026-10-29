import Foundation
import Network
import os
import Domain
import Perception

/// 下载网络门（2026-10-29 业主）：
/// 1) **确认网络是否可用**——NWPathMonitor 提供 isConnected（启动卡离线豁免与
///    严格模式跳过依据）；
/// 2) **下载线路限制**——默认 any（蜂窝与 Wi-Fi 均可）；「我的 → 模型与数据
///    资源」可改 wifiOnly；策略以 UserDefaults 镜像为准（启动期会话建立前
///    即可读，AppSettingsStore 双写同一键）。
@MainActor
@Perceptible
final class DownloadNetworkGate {
    private(set) var isConnected = true
    private(set) var isWiFi = false
    /// 至少收到过一次系统路径更新（避免首帧「连接中」误判离线）。
    private(set) var hasPath = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vitaliber.download-network-gate")
    private let logger = Logger(subsystem: "com.vitaliber", category: "network")
    private var started = false

    /// 线路策略（"any"/"wifiOnly"；与 AppSettingKey.downloadNetworkPolicy 同键镜像）。
    static var policy: String {
        UserDefaults.standard.string(forKey: AppSettingKey.downloadNetworkPolicy.rawValue)
            ?? AppSettingKey.downloadNetworkPolicy.defaultValue
    }

    static var isWiFiOnlyPolicy: Bool { policy == "wifiOnly" }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isConnected = connected
                self?.isWiFi = wifi
                self?.hasPath = true
            }
        }
        monitor.start(queue: queue)
    }

    /// 当前策略下是否允许发起下载（policy=any：联网即可；wifiOnly：仅 Wi-Fi）。
    /// 尚未拿到系统路径时不拦截（不把「未知」当作离线——重试闭环仍由下载失败态兜底）。
    func allowsDownload() -> Bool {
        guard hasPath else { return true }
        guard isConnected else { return false }
        if Self.isWiFiOnlyPolicy, !isWiFi { return false }
        return true
    }

    /// 给用户看的拦截原因（无网络 / 仅 Wi-Fi 策略但当前为蜂窝）。
    func blockReason() -> BlockReason? {
        guard hasPath else { return nil }
        if !isConnected { return .offline }
        if Self.isWiFiOnlyPolicy, !isWiFi { return .wifiOnlyPolicy }
        return nil
    }

    enum BlockReason: Equatable {
        case offline
        case wifiOnlyPolicy

        /// 离线时建议跳系统设置（2026-10-29 业主）；仅 Wi-Fi 策略属应用内
        /// 可自解（改「下载线路」），不推用户去系统层。
        var suggestsSystemSettings: Bool { self == .offline }
    }
}
