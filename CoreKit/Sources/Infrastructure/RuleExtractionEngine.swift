import Foundation
import Domain
import Protocols

/// 子项目 E3：T3 规则轨引擎——`CardExtractionEngine` 端口包 Domain 纯函数 `RuleExtractor`。
/// 确定性、零资产、零网络、不限时（单页 < 100 ms），恒可用；注册表中永远是链尾兜底轨（design §5.3）。
/// grounding 不在此处（注册表统一执行 `ExtractionGrounding.validate`，第二道防线）。
public struct RuleExtractionEngine: CardExtractionEngine {
    public let track: ExtractionTrack = .rules
    public let regionTimeout: Duration? = nil
    private let rules: any ExtractionRuleCataloging

    /// `rules` 缺省为空覆盖：内置 spec 仍是唯一兜底；规则库损坏/缺失不阻断导入。
    public init(rules: any ExtractionRuleCataloging = EmptyExtractionRuleCatalog()) {
        self.rules = rules
    }
    public func availability(for request: ExtractionRequest) async -> EngineAvailability { .available }
    public func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
        // 规则库只追加 active 别名；键/类型/顺序仍由 Swift spec 单一事实源决定。
        let overlay = await rules.activeOverlay()
        let effective = overlay.applied(to: spec)
        var (shared, rows) = RuleExtractor.extract(region: region, spec: effective, lines: request.lines)
        // 端侧学习别名命中键：置信度压到 0.5（低于 0.6 批量确认门槛）。
        for key in shared.keys where overlay.hasLearnedAlias(kind: spec.kind, key: key) {
            guard var value = shared[key] else { continue }
            value.confidence = min(0.5, value.confidence)
            shared[key] = value
        }
        for index in rows.indices {
            for key in rows[index].keys where overlay.hasLearnedAlias(kind: spec.kind, key: key) {
                guard var value = rows[index][key] else { continue }
                value.confidence = min(0.5, value.confidence)
                rows[index][key] = value
            }
        }
        return RegionExtraction(shared: shared, rows: rows)
    }
}
