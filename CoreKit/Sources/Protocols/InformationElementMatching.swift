import Foundation
import Domain

/// 信息元匹配端口（2026-11-06）：Core ML 判别式模型按行给出字段键/值候选。
///
/// 与 `CardExtractionEngine` 的分工：本端口只做“文本 → 候选”；
/// 区域切分、轨切换、grounding、去重并集仍由 `CardExtractionRegistry` 统一执行。
/// 实现必须端侧、零网络；缺模型时 `isAvailable == false`，调用方回落规则轨。
public protocol InformationElementMatching: Sendable {
    /// 模型身份（诊断/调试 JSON 用；不参与 UI 文案）。
    var modelID: String { get }
    func isAvailable() async -> Bool
    /// 逐行匹配；返回的 `sourceLineIndex` 相对传入的 `lines` 数组。
    func match(lines: [String], documentTypeKey: String?) async throws -> [InformationElementMatch]
}

/// 契约桩（Linux/测试）：脚本化返回，不依赖 Core ML。
public struct StubInformationElementMatching: InformationElementMatching {
    public let modelID: String
    private let available: Bool
    private let body: @Sendable ([String], String?) async throws -> [InformationElementMatch]

    public init(modelID: String = "stub", available: Bool = true,
                _ body: @escaping @Sendable ([String], String?) async throws -> [InformationElementMatch]) {
        self.modelID = modelID
        self.available = available
        self.body = body
    }

    public func isAvailable() async -> Bool { available }
    public func match(lines: [String], documentTypeKey: String?) async throws -> [InformationElementMatch] {
        try await body(lines, documentTypeKey)
    }
}
