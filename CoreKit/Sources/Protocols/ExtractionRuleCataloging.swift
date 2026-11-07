import Foundation
import Domain

/// 抽取规则库端口（2026-11-07 业主）：随包种子 + 端侧可写覆盖。
///
/// - 读面：`activeOverlay()` 返回当前生效的别名覆盖；缺库/损坏 → 空覆盖，
///   规则引擎继续用 Swift 内置 spec（fail-closed，不阻断导入）。
/// - 写面：Core ML 命中但不在既有别名表 → `observe` 记 `proposed`；
///   用户在确认页确认模型字段 → `confirm` 提升证据。只有达到门槛并转
///   `active` 的别名才参与抽取。
/// - 零网络、零遥测；只存标签文本与计数，不存字段值/患者数据。
public protocol ExtractionRuleCataloging: Sendable {
    func activeOverlay() async -> ExtractionRuleOverlay
    func observe(_ observations: [ExtractionRuleObservation]) async
    /// 用户确认（强证据）。`documentPseudonym` 是本机加盐哈希，只用于去重计数，
    /// 不落原文/患者 ID。达到门槛（≥5 次确认、≥3 份文档）才转 active。
    func confirm(kind: String, key: String, alias: String, documentPseudonym: String) async
}

/// 契约桩（Linux/测试）：恒空覆盖，观察/确认无副作用。
public struct StubExtractionRuleCatalog: ExtractionRuleCataloging {
    public init() {}
    public func activeOverlay() async -> ExtractionRuleOverlay { ExtractionRuleOverlay() }
    public func observe(_ observations: [ExtractionRuleObservation]) async {}
    public func confirm(kind: String, key: String, alias: String, documentPseudonym: String) async {}
}

/// 无规则库时的空实现（组合根在资源缺失时使用）。
public struct EmptyExtractionRuleCatalog: ExtractionRuleCataloging {
    public init() {}
    public func activeOverlay() async -> ExtractionRuleOverlay { ExtractionRuleOverlay() }
    public func observe(_ observations: [ExtractionRuleObservation]) async {}
    public func confirm(kind: String, key: String, alias: String, documentPseudonym: String) async {}
}
