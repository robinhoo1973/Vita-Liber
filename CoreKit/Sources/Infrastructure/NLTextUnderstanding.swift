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
    private let orchestrator: ExtractionOrchestrator

    public init() {
        // 三轨注册表经 EAL 装配（组合根 registerDefaultEngines 先行）；未装配
        // （单测/预览桩环境）回落规则轨恒可用——绝不 fatalError（resolve 契约），
        // 也不各自维护第二套抽取循环（结构轮：NL 只做卡片 → 旧 FieldDraft 形状转换）。
        let registry: CardExtractionRegistry
        if EngineRegistry.shared.isRegistered(CardExtractionFactory.self) {
            registry = EngineRegistry.shared.resolve(CardExtractionFactory.self)
        } else {
            registry = CardExtractionRegistry(engines: [RuleExtractionEngine()])
        }
        self.orchestrator = ExtractionOrchestrator(registry: registry)
    }

    /// 科室词表（coreml §4.2「机构/科室词表」组件——静态内置零资产；
    /// 词表词按最长优先匹配，行尾命中或 CJK 分词 token 命中即产出 dept）
    /// 词表单点 = ExtractionPatterns.deptWords（结构轮 2026-09-15：并集收敛，两轨一致）。
    private static let deptWords: Set<String> = ExtractionPatterns.deptWordSet

    public func understand(_ input: TextUnderstandingInput) async throws -> UnderstandingResult {
        switch input.source {
        case .ocr:
            return try await classifyOCR(input)
        case .voice:
            return classifyVoice(input)
        }
    }

    /// OCR 侧（§6.1）：文档类型判定（D 级草稿）+ 启发式语义字段。
    /// 字段目录随判定类型收敛：处方由 spec 驱动的 T3 规则轨 `RuleExtractor` 产出共享字段与逐药行
    ///（子项目 E3——此前处方分支返回 0 字段而 `PrescriptionFieldMapper.draftFields` 无调用方，
    /// 无 Foundation Models 的设备处方页恒为空，round2 O-N2）；检验/病历由
    /// DocumentTypeClassifierFallback.guessFields；其余由调用方通用 line_N 兜底——本层只产理解结果，不产 UI。
    private func classifyOCR(_ input: TextUnderstandingInput) async throws -> UnderstandingResult {
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
        if target == "prescription", let spec = ExtractionSpecRegistry.spec(for: "prescription") {
            // E5 接线（2026-09-15 结构轮）：抽取统一走 ExtractionOrchestrator 三轨注册表
            // （grounding / 逐区域失败切换内建），NL 只做 ExtractedCard → 旧 FieldDraft
            // 形状转换。授权门：本层为兜底轨理解层，恒不触发生成轨（T1/T2 由 App
            // 导入流程显式授权后经同一编排器调用）。
            let cards = try await orchestrator.analyze(lines: lines,
                                                       documentTypeKey: target,
                                                       pageConfidence: classification.confidence,
                                                       allowsGenerativeProcessing: false)
            let grounded = cards.first { $0.kind == spec.kind }
            // 旧模板 mapping 的理解层键：department → dept（CardTemplateMatcher 处方模板别名）。
            func legacyKey(_ key: String) -> String { key == "department" ? "dept" : key }
            if let grounded {
                for (key, value) in grounded.shared {
                    fields.append(FieldDraftAdapter.draft(key: legacyKey(key), value, lines: lines, pageConfidence: 0.6, track: .rules))
                    claimed.insert(value.anchor.lineIndex)
                }
                for row in grounded.rows {
                    for (key, value) in row {
                        fields.append(FieldDraftAdapter.draft(key: key, value, lines: lines, pageConfidence: 0.6, track: .rules))
                        claimed.insert(value.anchor.lineIndex)
                    }
                }
            }
        } else {
            // 检验/病历等非处方类型：逐行启发式语义字段；未命中行由调用方
            // 以通用 line_N 兜底（claimed 随结果返回，调用方不再重跑抽取）。
            // 启发式未命中的行再走词表直配（裸科室行「消化内科」——
            // NLTokenizer CJK 分词，§4.2 词表组件）。
            // 审查修复（叙事多行并入，2026-09-18 业主实测）：主诉/现病史/
            // 既往史等标签行后的无标签行并入该叙事字段（逐字换行，BR-002
            // 不丢内容），claimed 含吸收行（调用方不再补 line_N 兜底）；
            // 边界 = 下一个标签行 / 日期开头 / 编号列表 / 科室直配行。
            var idx = 0
            while idx < lines.count {
                let line = lines[idx]
                var drafts = DocumentTypeClassifierFallback.guessFields(line: line)
                if !drafts.isEmpty {
                    claimed.insert(idx)
                    if let narrativeIndex = drafts.firstIndex(where: {
                        DocumentTypeClassifierFallback.narrativeFieldKeys.contains($0.key)
                    }) {
                        let boundary: (String) -> Bool = { candidate in
                            !DocumentTypeClassifierFallback.guessFields(line: candidate).isEmpty
                                || Self.deptDraft(forLine: candidate) != nil
                                || candidate.range(of: #"^\d{4}\s*[-/年.]|^\d+[.、)]"#,
                                                   options: .regularExpression) != nil
                        }
                        let merged = DocumentTypeClassifierFallback.mergeNarrativeLines(
                            lines: lines, from: idx + 1, isBoundary: boundary)
                        if !merged.text.isEmpty {
                            drafts[narrativeIndex].value += "\n" + merged.text
                            for absorbed in (idx + 1)..<(idx + 1 + merged.absorbed) {
                                claimed.insert(absorbed)
                            }
                            idx += merged.absorbed
                        }
                    }
                    fields.append(contentsOf: drafts)
                } else if let dept = Self.deptDraft(forLine: line) {
                    claimed.insert(idx)
                    fields.append(dept)
                }
                idx += 1
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
        for word in ExtractionPatterns.deptWordsByLength {
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

    public func understand(_ input: TextUnderstandingInput) async throws -> UnderstandingResult {
        for track in tracks {
            guard !Task.isCancelled, await track.isAvailable(for: input) else { continue }
            // 审查修正：单轨非取消类异常必须降级到下一轨，不得击穿整条链
            // （「降级零崩溃」契约——ADR-029 三轨语义：一轨坏不殃及余轨）。
            // CancellationError 按协议继续上抛。
            let result: UnderstandingResult
            do {
                result = try await track.understand(input)
            } catch {
                if error is CancellationError { throw error }
                continue
            }
            if !result.engineUnavailable {
                return result
            }
        }
        return UnderstandingResult(suggestedTarget: nil, targetConfidence: 0, fields: [])
    }
}
