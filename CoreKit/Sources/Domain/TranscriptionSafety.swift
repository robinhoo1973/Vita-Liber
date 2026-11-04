import Foundation

/// BR-012 转写安全面（2026-11-03 round3 P0-B §8-3；tech-spec §5.13）。
///
/// **为什么不只扫交付文本**：交付文本可能经过润色、融合或主轨择优，任何一个改写环节
/// 都可能把「胸痛」改掉或丢掉（例如融合保留了没听出急救词的主轨）。急救召回不能
/// 依赖改写环节正确，所以判定口径是「交付文本 ∪ 各引擎原生 1-best」：任一命中即急救。
/// 宁可多跳一次急救卡，也不能漏一次。
public enum TranscriptionSafety {
    /// 返回第一段命中 `EmergencyKeywordRules` 的文本；都未命中时返回 nil。
    ///
    /// 扫描顺序：先查交付文本 `result.text`，命中就原样返回它（`hypotheses` 为空时与
    /// 引入证据前的行为逐字一致）；再按 `result.hypotheses` 的顺序查各引擎原生 1-best `text`，
    /// 返回第一段命中的原文。
    ///
    /// **不扫 `alternativeTexts` 与逐词 `alternatives`**：它们是同一引擎排在 1-best 之后的
    /// 低位 n-best，引擎自己已判定可能性更低，而且 n-best 尾部多是近音候选。纳入后，
    /// 引擎并不认为用户说了急救词的按压也会跳急救卡（收起面板、关闭助手会话），
    /// 误触发会打断正常录入，也会让用户习惯性忽略急救提示。不同引擎的 1-best 是
    /// 彼此独立的证据，所以纳入。
    public static func emergencyText(in result: TranscriptionResult) -> String? {
        if EmergencyKeywordRules.match(result.text) { return result.text }
        return result.hypotheses.first(where: { EmergencyKeywordRules.match($0.text) })?.text
    }
}
