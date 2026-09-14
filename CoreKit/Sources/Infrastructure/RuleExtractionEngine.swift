import Foundation
import Domain
import Protocols

/// 子项目 E3：T3 规则轨引擎——`CardExtractionEngine` 端口包 Domain 纯函数 `RuleExtractor`。
/// 确定性、零资产、零网络、不限时（单页 < 100 ms），恒可用；注册表中永远是链尾兜底轨（design §5.3）。
/// grounding 不在此处（注册表统一执行 `ExtractionGrounding.validate`，第二道防线）。
public struct RuleExtractionEngine: CardExtractionEngine {
    public let track: ExtractionTrack = .rules
    public let regionTimeout: Duration? = nil
    public init() {}
    public func availability(for request: ExtractionRequest) async -> EngineAvailability { .available }
    public func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
        let (shared, rows) = RuleExtractor.extract(region: region, spec: spec, lines: request.lines)
        return RegionExtraction(shared: shared, rows: rows)
    }
}
