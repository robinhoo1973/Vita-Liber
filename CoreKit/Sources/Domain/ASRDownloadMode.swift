import Foundation

/// ASR 模型下载的传输形态（2026-09-27 委员会 P3b：自 Infrastructure 迁入——
/// 纯值类型、无 Apple 框架类型，App 视图为渲染下载进度文案而依赖它，
/// 归属 Domain 后 Features 不再为此 import Infrastructure）。
public enum ASRDownloadMode: Sendable, Equatable {
    case segmented(segments: Int)
    case singleStream
}
