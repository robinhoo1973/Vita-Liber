import Foundation
import Domain
import Protocols

/// 识别文本 → 信息卡的抽取编排器（swift-class-design.md §5.4 `TextAnalysisEngine` 的落地形态）。
/// 阶段：稳定文档键 → 候选 spec（`ExtractionSpecRegistry.candidates`）→ 版面区域 →
/// 三轨注册表抽取（grounding / 逐区域失败切换 / 缩范围重试内建，design §5.3）→ 续页规则。
///
/// 卡片提取的**唯一生产入口**：NLTextUnderstanding 的处方分支与本编排器共用一条链，
/// 不再各自维护兼容路径（E5 接线，2026-09-15 结构轮）。授权门
/// （`allowsGenerativeProcessing`）由调用方显式传入——兜底轨理解层恒传 false，
/// App 导入流程按用户授权传真实值。
public actor ExtractionOrchestrator {
    private let registry: CardExtractionRegistry

    public init(registry: CardExtractionRegistry) {
        self.registry = registry
    }

    /// 一页行文本 → `[ExtractedCard]`（已 grounding、已续页建议）。
    /// 文档分类（打分阶段）由调用方完成（`DocumentTypeClassifierFallback.classify`），
    /// 本类只做「候选收敛 + 抽取编排」——单一职责（P2）。
    public func analyze(lines: [String],
                        pageIndex: Int = 0,
                        documentTypeKey: String,
                        pageConfidence: Double,
                        allowsGenerativeProcessing: Bool,
                        pageBudget: Duration? = nil) async -> [ExtractedCard] {
        let specs = ExtractionSpecRegistry.candidates(documentTypeKeys: [documentTypeKey])
        guard !specs.isEmpty else { return [] }
        let layout = PageLayout.linesOnly(lines)
        let request = ExtractionRequest(
            pageIndex: pageIndex,
            lines: lines,
            regions: layout.extractionRegions(pageIndex: pageIndex),
            specs: specs,
            allowsGenerativeProcessing: allowsGenerativeProcessing,
            pageConfidence: pageConfidence,
            pageBudget: pageBudget
        )
        let cards = await registry.extract(request)
        return ContinuationRules.apply(cards, specs: ExtractionSpecRegistry.spec(for:))
    }
}
