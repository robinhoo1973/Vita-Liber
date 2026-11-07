import Foundation
import Domain

/// 端侧规则学习入口（2026-11-07 业主：规则库随 App 上线；Core ML 发现的新
/// 规则及时收集）。组合根与确认页共用同一个 store。
///
/// 只有**用户确认后**的 Core ML 字段才累计强证据；模型单独输出只记
/// `candidate`（权重 0），永不自动改变抽取行为。
public enum RuleLearningCenter {
    public static let store = ExtractionRuleStore()

    /// 确认页保存成功后调用：从已确认字段的 `rawText` 提取未知标签，
    /// 作为强证据写入覆盖库。文档伪名用 `documentId`（本机 UUID，不含患者信息）。
    public static func recordConfirmed(card: MatchedCard, documentId: UUID) async {
        guard let spec = ExtractionSpecRegistry.spec(for: card.kind) else { return }
        let known = Set(spec.fields.flatMap(\.labelAliases))
        for field in card.allFields where field.source == .nlModel && field.isConfirmed {
            guard let raw = field.rawText?.components(separatedBy: "\n").first,
                  let generic = RuleExtractor.genericLabeledValue(in: raw),
                  !known.contains(generic.label) else { continue }
            await store.confirm(kind: card.kind, key: field.key, alias: generic.label,
                                documentPseudonym: documentId.uuidString)
        }
    }
}
