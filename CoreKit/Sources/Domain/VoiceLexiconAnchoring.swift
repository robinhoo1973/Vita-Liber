import Foundation

/// FR25.12⑪ 语音侧词表锚定（2026-09-21）：ASR 转写文本 → 词表命中 →
/// 医疗槽位草稿（药名/剂型/给药途径/频次）+ 近失配候选，供 FR17.19
/// 意图目录（`VoiceIntentCatalog.extract`）与 FR17.13 统一确认卡消费。
///
/// 与 OCR 侧（`LexiconExtraction`）同一纪律，两处不得独立演化：
/// - 值恒为转写原文精确子串（grounding 可逐字定位）；近失配只产候选，
///   绝不自动改写转写文本（FR25.1 补注：候选是提问，不是断言）；
/// - 产出全 D 级草稿（BR-003：确认前不入任何事实链）；
/// - 槽位键复用处方行键（drug_name/drug_form/route/frequency，经
///   `LexiconExtraction.lexiconKey` 同一映射）；
/// - 贴码不在此处：医疗槽位由调用方统一过 `UnderstandingCodeResolution`
///   （惰性建议，coreml-minilm-spec §4.3）。
///
/// 意图整合纪律（`integrate`）：只对「未判定/速记/用药草稿」三态生效——
/// 已判定的结构化意图（指标/提醒/档案）去向不因词表证据改变（稳定性优先：
/// 「提醒我买阿司匹林」不得被改判为用药草稿；竞争式重判为 Stage B 已登记项）。
public enum VoiceLexiconAnchoring {

    /// 锚定结果：槽位草稿 + 意图证据强度。
    public struct Anchor: Sendable, Equatable {
        /// 槽位草稿（**不含**转写原文草稿——原文草稿由调用方保持首位：
        /// 期一 `.anyText` 分发只取 first 落速记正文，BR-002 不丢内容）。
        public var drafts: [FieldDraft]
        /// 药物草稿意图证据：≥1 精确药名命中，或 ≥2 个伴随槽位
        /// （剂型/途径/频次）。近失配（候选级）**不计入**证据。
        public var hasMedicationEvidence: Bool

        public init(drafts: [FieldDraft] = [], hasMedicationEvidence: Bool = false) {
            self.drafts = drafts
            self.hasMedicationEvidence = hasMedicationEvidence
        }
    }

    /// 单次锚定：精确命中优先（药名取首个命中为值、其余为候选）；无精确
    /// 药名命中时尝试转写 token 的近失配（值恒为原文 token，候选为词条）。
    public static func anchor(_ text: String, lexicon: MedicalLexicon) -> Anchor {
        guard !text.isEmpty, lexicon.entryCount > 0 else { return Anchor() }
        let hits = lexicon.hits(in: text)
        var drafts: [FieldDraft] = []
        var drugHit: LexiconHit?
        var extraDrugs: [LexiconHit] = []
        var companions = 0
        for hit in hits {
            switch hit.entry.category {
            case .medication:
                if drugHit == nil { drugHit = hit } else { extraDrugs.append(hit) }
            case .drugForm, .route, .frequency:
                guard let key = LexiconExtraction.lexiconKey(for: hit.entry.category) else { continue }
                companions += 1
                drafts.append(LexiconDraftFactory.slotDraft(key: key, value: hit.value,
                                                            confidence: LexiconDraftFactory.confidence(for: hit),
                                                            rawText: text))
            case .metric:
                continue    // 指标侧由既有文法 + F25 解析链承担，此处零重复产出
            }
        }
        if let drugHit {
            var name = LexiconDraftFactory.slotDraft(key: "drug_name", value: drugHit.value,
                                                     confidence: LexiconDraftFactory.confidence(for: drugHit),
                                                     rawText: text)
            if !extraDrugs.isEmpty {
                name.candidates = extraDrugs.map {
                    FieldDraft.Candidate(value: $0.value,
                                         confidence: LexiconDraftFactory.confidence(for: $0),
                                         source: .gazetteer)
                }
            }
            drafts.insert(name, at: 0)
        } else if let candidate = nearMissToken(in: text, lexicon: lexicon) {
            var name = FieldDraft(key: "drug_name", value: candidate.value, confidence: 0.5,
                                  rawText: text, source: .gazetteer)
            name.candidates = candidate.candidates
            drafts.insert(name, at: 0)
        }
        return Anchor(drafts: drafts,
                      hasMedicationEvidence: drugHit != nil || companions >= 2)
    }

    /// 意图整合：未判定（nil）/unknown/appendNote/appendMedDraft 四态并入
    /// 词表草稿；证据充分时把「未判定/unknown」升为 appendMedDraft。
    /// 其余意图原样返回（去向稳定）。转写原文草稿恒保持首位：期一用药草稿
    /// 与速记同走 `.anyText` 分发（只取 first），原文任何情况下不丢（BR-002）。
    public static func integrate(_ result: UnderstandingResult, text: String,
                                 lexicon: MedicalLexicon) -> UnderstandingResult {
        let anchor = anchor(text, lexicon: lexicon)
        guard !anchor.drafts.isEmpty else { return result }
        let intent = result.suggestedTarget.flatMap(VoiceIntentKey.init(rawValue:))
        switch intent {
        case nil, .unknown, .appendNote, .appendMedDraft:
            break
        default:
            return result
        }
        var out = result
        if anchor.hasMedicationEvidence, intent == nil || intent == .unknown {
            out.suggestedTarget = VoiceIntentKey.appendMedDraft.rawValue
            out.targetConfidence = max(out.targetConfidence, 0.7)
        }
        out.fields += anchor.drafts
        return out
    }

    // MARK: - 近失配（仅候选，绝不自动采用）

    private static func nearMissToken(in text: String, lexicon: MedicalLexicon)
        -> (value: String, candidates: [FieldDraft.Candidate])? {
        // ASR 整句转写常无空格/标点——token 级扫描不成立（游程=整句，
        // 超出词长窗口）：由词表侧 `nearMissSpans` 按首字桶剪枝 + 键长
        // 窗口直接定位，值恒为原文子串。
        guard let first = lexicon.nearMissSpans(in: text, category: .medication).first else {
            return nil
        }
        return (first.span, LexiconDraftFactory.candidates(for: first.candidates))
    }
}
