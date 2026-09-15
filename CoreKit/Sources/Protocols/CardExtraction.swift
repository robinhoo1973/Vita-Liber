import Foundation
import Domain

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §5）：按卡 spec 抽取的引擎端口。
/// T1 Foundation Models（E4）/ T2 llama.cpp 本机 LLM（子项目 F）/ T3 规则（E3）都实现 `CardExtractionEngine`；
/// grounding **不在引擎内**——注册表对每个区域结果统一执行 `ExtractionGrounding.validate`（第二道防线，design §4.6）。
/// 全部产物恒 D 级（BR-003）；零网络；不读 `EntitlementStore`（识别后理解属信任/安全面永久免费）。
/// 结构轮（2026-09-15）：编排策略（`CardExtractionRegistry`）迁入 Infrastructure——本模块只保留
/// 抽象与契约桩（P3）；请求/结果值对象迁入 Domain/ExtractedCard.swift。

public enum EngineAvailability: Sendable, Equatable { case available, unavailable(DegradedReason) }

public enum ExtractionEngineError: Error, Sendable { case unavailable, modelBusy, schemaMismatch }

/// 三轨同一端口（design §5.1）。`regionTimeout == nil` = 不限（规则轨）。
public protocol CardExtractionEngine: Sendable {
    var track: ExtractionTrack { get }
    var regionTimeout: Duration? { get }
    func availability(for request: ExtractionRequest) async -> EngineAvailability
    func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction
}

/// 契约桩（测试 / Linux）：脚本化区域结果；恒可用。
public struct StubCardExtractionEngine: CardExtractionEngine {
    public let track: ExtractionTrack, regionTimeout: Duration?
    private let body: @Sendable (ExtractionRegion, ExtractionSpec) async throws -> RegionExtraction
    public init(track: ExtractionTrack, regionTimeout: Duration?,
                _ body: @escaping @Sendable (ExtractionRegion, ExtractionSpec) async throws -> RegionExtraction) {
        self.track = track; self.regionTimeout = regionTimeout; self.body = body
    }
    public func availability(for request: ExtractionRequest) async -> EngineAvailability { .available }
    public func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
        try await body(region, spec)
    }
}
