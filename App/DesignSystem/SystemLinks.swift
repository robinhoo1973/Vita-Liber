import UIKit
import Domain

/// 系统跳转单一出口（全仓审查 2026-09-18 · F-A2-05 / F-A4-02 附带）：拨号 / 健康 App /
/// 系统设置。此前 `tel://` ×4、`x-apple-health://` ×2、`openSettingsURLString` ×5 各自
/// 拼 URL——拨号号码未归一（含空格/括号时 `URL(string:)` 为 nil 或 iOS 16 静默不拨），
/// 且急救卡 Medical ID 引导曾带 https 回退 URL（死代码，但与 P0 零网络纪律相悖）。
/// 生产零网络：本出口只产生 `tel:` / `x-apple-health:` / 系统设置三类 URL。
enum SystemLinks {
    /// 拨号：号码经 Domain `PhoneNumberRules.dialable` 归一；非法/不可拨返回 false，
    /// 调用侧据此响亮提示而非静默。拨号动作本身由系统确认，App 不拦截不记录内容。
    @discardableResult
    static func dial(_ rawNumber: String) -> Bool {
        guard let number = PhoneNumberRules.dialable(rawNumber),
              let url = URL(string: "tel://\(number)"),
              UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 打开系统健康 App（F15 Medical ID 引导）。iPad/无健康 App 时 completion 回传 false，
    /// 调用侧可提示「此设备没有健康 App」而非静默。
    static func openHealthApp(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "x-apple-health://") else { completion?(false); return }
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }

    /// 打开本 App 的系统设置页（权限被拒后的「去设置」）。
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
