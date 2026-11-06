import Foundation

/// OCR 影子调参诊断开关（2026-11-03 安全复审）。
///
/// 默认关闭：关闭时 `PaddleRecShadowRecognizer` 直接返回 Vision 结果，
/// 不加载 21MB 模型、不跑 ONNX、不写任何诊断日志。开启入口只在
/// SP-48 关于页的显式开关（2026-11-05 自帮助中心移入），并明示日志会
/// 写入“文件”App。敏感资料永不写日志；开关关闭后既有日志仍可由用户手动删除。
public enum OCRShadowDiagnostics {
    /// 与 HelpAboutView 的 `@AppStorage` 共用；改名即破坏开关。
    public static let defaultsKey = "ocrShadowDiagnosticsEnabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }
}
