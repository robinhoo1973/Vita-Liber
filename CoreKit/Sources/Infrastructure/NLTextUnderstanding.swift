import Foundation
import Domain
import Protocols

// MARK: - 兜底轨：NaturalLanguage + 正则 + 启发式 + F25 词表（ADR-029 期一）

/// 兜底轨理解引擎（coreml-minilm-spec §4.2）：零资产恒可用、全 iOS 17+。
/// 期一实现 = Domain 纯函数分类器（正则文法 + 关键词启发式）编排 +
/// F25 惰性接线挂点（编码解析在 App 层经 `UnderstandingCodeResolution`
/// 执行——引擎保持 DB 无关，工厂零依赖装配）。
/// 期二备轨（Core ML 量化编码器）与期三主轨（Foundation Models）在
/// 同端口替换本类，上层零感知。
public actor NLTextUnderstanding: TextUnderstanding {
    public init() {}

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
            // 零命中：无法判定——调用方引导用户选择类型（§5 不预选数据去向）
            return UnderstandingResult(suggestedTarget: nil, targetConfidence: 0,
                                       fields: Self.lineDrafts(lines))
        }
        var fields: [FieldDraft] = []
        var claimed = Set<Int>()
        if target != "prescription" {
            // 检验/病历等非处方类型：逐行启发式语义字段；未命中行由调用方
            // 以通用 line_N 兜底（本层不产行号草稿，行号归调用方职责）
            for (idx, line) in lines.enumerated() {
                let drafts = DocumentTypeClassifierFallback.guessFields(line: line)
                if !drafts.isEmpty { claimed.insert(idx) }
                fields.append(contentsOf: drafts)
            }
        }
        _ = claimed   // 预留：期二字段标签分类器按行归属收敛模板
        return UnderstandingResult(suggestedTarget: target,
                                   targetConfidence: classification.confidence,
                                   secondaryTargets: classification.secondary,
                                   fields: fields)
    }

    /// 语音侧（§6.2）：意图目录（FR17.19 单一事实源）自动分类 + 槽位抽取。
    private func classifyVoice(_ input: TextUnderstandingInput) -> UnderstandingResult {
        VoiceIntentCatalog.classify(input.text, confidence: 0.9)
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
            let result = await track.understand(input)
            // 空产出（无判定且零字段）视为该轨不可用，继续降级
            if result.suggestedTarget != nil || !result.fields.isEmpty {
                return result
            }
        }
        return UnderstandingResult(suggestedTarget: nil, targetConfidence: 0, fields: [])
    }
}
