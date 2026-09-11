import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage   // Apple 平台专用（NLTokenizer CJK 分词）——Linux 无此模块，守卫后仅词表直配
#endif
import Domain
import Protocols

// MARK: - 兜底轨：NaturalLanguage + 正则 + 启发式 + F25 词表（ADR-029 期一）

/// 兜底轨理解引擎（coreml-minilm-spec §4.2）：零资产恒可用、全 iOS 17+。
/// 期一实现 = Domain 纯函数分类器（正则文法 + 关键词启发式）编排 +
/// NaturalLanguage CJK 分词 + 科室词表直配（裸科室行「消化内科」，
/// 补「科室：」前缀正则之外的常见形态）+ F25 惰性接线挂点（编码解析在
/// App 层经 `UnderstandingCodeResolution` 执行——引擎保持 DB 无关，
/// 工厂零依赖装配）。NLTagger NER/NLGazetteer（需 Create ML 资产文件）
/// 期二随词表资产接入——已登记规格（coreml-minilm-spec 变更记录）。
/// 期二备轨（Core ML 量化编码器）与期三主轨（Foundation Models）在
/// 同端口替换本类，上层零感知。
public actor NLTextUnderstanding: TextUnderstanding {
    public init() {}

    /// 科室词表（coreml §4.2「机构/科室词表」组件——静态内置零资产；
    /// 词表词按最长优先匹配，行尾命中或 CJK 分词 token 命中即产出 dept）
    private static let deptWords: Set<String> = [
        "内科", "外科", "儿科", "妇产科", "产科", "眼科", "耳鼻喉科", "口腔科",
        "皮肤科", "骨科", "泌尿外科", "神经内科", "消化内科", "呼吸内科",
        "心血管内科", "心内科", "内分泌科", "血液科", "肿瘤科", "感染科",
        "肾内科", "风湿免疫科", "老年科", "全科", "康复医学科", "康复科",
        "中医科", "针灸科", "急诊科", "重症医学科", "麻醉科", "放射科",
        "影像科", "超声科", "检验科", "病理科", "体检中心", "保健科",
    ]

    public func understand(_ input: TextUnderstandingInput) async -> UnderstandingResult {
        switch input.source {
        case .ocr:
            return classifyOCR(input)
        case .voice:
            return classifyVoice(input)
        }
    }

    /// OCR 侧（§6.1）：文档类型判定（D 级草稿）+ 启发式语义字段。
    /// 字段目录随判定类型收敛（处方由 PrescriptionFieldMapper 承担、
    /// 检验/病历由 DocumentTypeClassifierFallback.guessFields、
    /// 其余由调用方通用 line_N 兜底）——本层只产理解结果，不产 UI。
    private func classifyOCR(_ input: TextUnderstandingInput) -> UnderstandingResult {
        let lines = input.lines ?? input.text.components(separatedBy: .newlines)
        let classification = DocumentTypeClassifierFallback.classify(lines: lines)
        guard let target = classification.target else {
            // 零命中：无法判定——调用方引导用户选择类型（§5 不预选数据去向）；
            // 全部行视为 line_N 草稿已认领（调用方不再补兜底行）
            return UnderstandingResult(suggestedTarget: nil, targetConfidence: 0,
                                       fields: Self.lineDrafts(lines),
                                       claimedLineIndices: Set(lines.indices))
        }
        var fields: [FieldDraft] = []
        var claimed = Set<Int>()
        if target != "prescription" {
            // 检验/病历等非处方类型：逐行启发式语义字段；未命中行由调用方
            // 以通用 line_N 兜底（claimed 随结果返回，调用方不再重跑抽取）。
            // 启发式未命中的行再走词表直配（裸科室行「消化内科」——
            // NLTokenizer CJK 分词，§4.2 词表组件）
            for (idx, line) in lines.enumerated() {
                let drafts = DocumentTypeClassifierFallback.guessFields(line: line)
                if !drafts.isEmpty {
                    claimed.insert(idx)
                    fields.append(contentsOf: drafts)
                } else if let dept = Self.deptDraft(forLine: line) {
                    claimed.insert(idx)
                    fields.append(dept)
                }
            }
        }
        return UnderstandingResult(suggestedTarget: target,
                                   targetConfidence: classification.confidence,
                                   secondaryTargets: classification.secondary,
                                   fields: fields,
                                   claimedLineIndices: claimed)
    }

    /// 语音侧（§6.2）：意图目录（FR17.19 单一事实源）自动分类 + 槽位抽取。
    /// 置信度 = 调用方实测转写置信度（此前恒 0.9——低置信转写被当作高置信
    /// 预填，<0.5 复核闸不可达）
    private func classifyVoice(_ input: TextUnderstandingInput) -> UnderstandingResult {
        VoiceIntentCatalog.classify(input.text, confidence: input.transcriptionConfidence ?? 0.9)
    }

    /// 零判定时的行草稿（原文保留，通用呈现；BR-002 不丢内容）。
    private static func lineDrafts(_ lines: [String]) -> [FieldDraft] {
        lines.enumerated().map { idx, line in
            var draft = FieldDraft(key: "line_\(idx)", value: line,
                                   confidence: 0.6, rawText: line)
            draft.source = .unknown
            return draft
        }
    }

    /// 词表直配：裸科室行 → dept 草稿（source=.heuristic；D 级需复核）。
    /// 命中规则：整行（去空白）行尾命中词表词（最长优先），或 NLTokenizer
    /// CJK 分词后任一 token 命中。≤20 字防长句误claim。
    private static func deptDraft(forLine line: String) -> FieldDraft? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20 else { return nil }
        for word in deptWords.sorted(by: { $0.count > $1.count }) {
            if text == word || text.hasSuffix(word) {
                return deptDraft(value: word, rawText: line)
            }
        }
        // CJK 分词 token 命中（仅 Apple 平台；Linux 无 NaturalLanguage，
        // 回落整行/行尾匹配口径——测试桩行为一致）
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]))
            return true
        }
        if let hit = tokens.first(where: { deptWords.contains($0) }) {
            return deptDraft(value: hit, rawText: line)
        }
        #endif
        return nil
    }

    private static func deptDraft(value: String, rawText: String) -> FieldDraft {
        var draft = FieldDraft(key: "dept", value: value,
                               confidence: 0.6, rawText: rawText)
        draft.source = .heuristic
        return draft
    }
}

// MARK: - 降级链组合器（ADR-029 §4.2：三轨同一端口，降级零崩溃）

/// 三轨降级链：按序尝试各轨，首个产出非空结果者胜。
/// 期一成员=[兜底轨]；期二加备轨、期三加主轨（只增成员、调用方零改——
/// 防三轨各自接线，coreml-minilm-spec V1.8 期一实施条目②）。
public actor FallbackTextUnderstanding: TextUnderstanding {
    private let tracks: [any TextUnderstanding]

    public init(tracks: [any TextUnderstanding]) {
        self.tracks = tracks
    }

    public func understand(_ input: TextUnderstandingInput) async -> UnderstandingResult {
        for track in tracks {
            guard !Task.isCancelled, await track.isAvailable(for: input) else { continue }
            let result = await track.understand(input)
            if !result.engineUnavailable {
                return result
            }
        }
        return UnderstandingResult(suggestedTarget: nil, targetConfidence: 0, fields: [])
    }
}
