import Foundation

/// 词表命中 → 字段草稿的公共工厂（2026-09-21，FR25.12⑬/⑪）：
/// OCR 行锚定（`LexiconExtraction`）与语音转写锚定（`VoiceLexiconAnchoring`）
/// **共用**同一份「置信度策略 / 槽位草稿构造 / 近失配候选构造」——两处后处理
/// 只保留各自的输入适配与消费契约差异（见下），术语→草稿的翻译纪律只维护
/// 这一处（coreml-minilm-spec §4.3：识别后文本后处理两处不得独立演化）。
///
/// 为什么不是同一个模块（设计裁决，2026-09-21 审查）：
/// - OCR 侧输入是**行坐标系统**（`[String]` + `sourceLineIndex`，grounding
///   依赖行下标与 bbox 对齐），消费契约 = 按 (键,行号) 去重 + 文档类型门控
///   （prescription 之外的裸药名需伴随证据）；
/// - 语音侧输入是**整句转写**（无行结构），消费契约 = 意图整合（unknown/
///   速记 → 用药草稿升格）与「原文草稿恒首位」（FR17.13 分发只取 first）。
/// 把两者硬并成一个函数须以「可选行号 + 文档类型 + 意图语义」三组开关换
/// 共用，内聚下降且单测边界碎裂——业界最佳实践（SRP/适配器模式）取
/// **共享核心 + 两个薄适配器**：核心 = `MedicalLexicon`（匹配）+ 本工厂
/// （翻译），适配器 = 两个锚定模块。
public enum LexiconDraftFactory {

    /// 命中置信度：逐字命中略高于折叠命中（简繁/大小写/空白归并路径）。
    public static func confidence(for hit: LexiconHit) -> Double {
        hit.match == .exact ? 0.6 : 0.55
    }

    /// 槽位草稿：值恒为原文子串（grounding 可逐字定位）；source 恒
    /// `.gazetteer`（词表证据轨，D 级由确认卡裁决去向，BR-003）。
    public static func slotDraft(key: String, value: String, confidence: Double,
                                 rawText: String, sourceLineIndex: Int? = nil) -> FieldDraft {
        FieldDraft(key: key, value: value, confidence: confidence,
                   rawText: rawText, source: .gazetteer, sourceLineIndex: sourceLineIndex)
    }

    /// 近失配候选（候选级置信度 0.5）：值 = 词条原文（校正建议词）——
    /// **只提示不写回**（FR25.1：候选是提问，不是断言）。
    public static func candidate(for entry: LexiconEntry) -> FieldDraft.Candidate {
        FieldDraft.Candidate(value: entry.term, confidence: 0.5, source: .gazetteer)
    }

    public static func candidates(for entries: [LexiconEntry]) -> [FieldDraft.Candidate] {
        entries.map(candidate(for:))
    }
}
