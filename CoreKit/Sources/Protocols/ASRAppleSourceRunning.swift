import Foundation
import Domain

/// Apple 第二/第三识别源的运行端口（端侧、零联网、零音频持久化）。
///
/// 只接受**临时音频 URL**（调用方负责识别后立即删除；本协议实现不得复制/保留）。
/// 生产并行接线时，采集层把同一段缓冲写临时文件或提供等价 seam；本端口不改变
/// `TranscriptionEngine` 的零文件句柄合同（音频 URL 不进入 `TranscriptionRequest`）。
public protocol ASRAppleSourceRunning: Sendable {
    /// 当前授权与端侧能力（只读探针；不弹授权框）。
    func availability() async -> ASRAppleSourceAvailabilityFacts
    /// 显式请求一次授权（仅由生产编排在首次三源识别前调用）。
    func requestAuthorization() async -> ASRAppleAuthorization
    /// 识别一个临时音频文件；失败/未授权折叠进返回值，不抛错。
    func transcribe(audioURL: URL, source: ASRAppleSource,
                    contextualStrings: [String]) async -> ASRAppleSourceResult
}

extension ASRAppleSourceRunning {
    /// 探针 + 纯策略 = 本次按压的 Apple 副源计划。
    public func plan(primaryEngineID: String?, primaryLocale: String?) async -> ASRAppleSourcePlan {
        ASRAppleSourcePolicy.plan(primaryEngineID: primaryEngineID, primaryLocale: primaryLocale,
                                  facts: await availability())
    }
}
