import Foundation

/// 长音频分段策略（tech-spec §11 清偿项「SFSpeechRecognizer 60s 截断」，归属 M1.5）。
///
/// 基线轨 SFSpeechRecognizer 单次识别约 60s 后被系统截断，长录音必须切窗续接；
/// 升级轨（ADR-023，iOS 26+）支持长音频，不分段。两轨经同一 `TranscriptionEngine`
/// 协议暴露，分段与否是**实现细节**，调用方零感知。
public enum TranscriptionSegmentation {
    /// 方言无独立引擎时的回落 locale（FR17.15/FR17.16 发声与识别回退链）
    public static let fallbackLocale = "zh-Hans-CN"

    public struct Window: Sendable, Equatable {
        public var startSeconds: Int
        public var lengthSeconds: Int
        public init(startSeconds: Int, lengthSeconds: Int) {
            self.startSeconds = startSeconds; self.lengthSeconds = lengthSeconds
        }
    }

    /// 切窗规划。窗口间留 `overlapSeconds` 重叠，避免切点正好落在字中间导致丢字。
    /// - 升级轨（supportsLongForm）恒为单窗；
    /// - 基线轨按 `maxSegmentSeconds` 切，且**留 5s 安全余量**再切——
    ///   卡着 60s 切会在系统抢先截断与我方切窗之间产生竞态。
    public static func plan(durationSeconds: Int,
                            capability: TranscriptionCapability,
                            overlapSeconds: Int = 2) -> [Window] {
        guard durationSeconds > 0 else { return [] }
        if capability.supportsLongForm {
            return [Window(startSeconds: 0, lengthSeconds: durationSeconds)]
        }
        let safe = max(5, capability.maxSegmentSeconds - 5)
        if durationSeconds <= safe {
            return [Window(startSeconds: 0, lengthSeconds: durationSeconds)]
        }
        var windows: [Window] = []
        var start = 0
        while start < durationSeconds {
            let length = min(safe, durationSeconds - start)
            windows.append(Window(startSeconds: start, lengthSeconds: length))
            if start + length >= durationSeconds { break }
            start += max(1, length - overlapSeconds)
        }
        return windows
    }
}
