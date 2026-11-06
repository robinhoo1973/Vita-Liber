import SwiftUI
import Infrastructure

/// 孤儿归属动作面的环境注入（2026-11-06）：会话装配根持有唯一 actor；
/// 预览/降级未注入时视图显示不可用，不自行建库。
private struct AttributionReviewKey: EnvironmentKey {
    static let defaultValue: AttributionReviewService? = nil
}

extension EnvironmentValues {
    var attributionReview: AttributionReviewService? {
        get { self[AttributionReviewKey.self] }
        set { self[AttributionReviewKey.self] = newValue }
    }
}
