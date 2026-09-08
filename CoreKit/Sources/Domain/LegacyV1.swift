import Foundation

public struct LegacyAsset: Sendable, Equatable, Codable {
    public let id: String
    public let type: String?
    public let textBlocks: [LegacyBlock]?
}
public struct LegacyBlock: Sendable, Equatable, Codable {
    public let text: String
    public let confidence: Double
}
public struct LegacyRecord: Sendable, Equatable, Codable {
    public let id: String
    public let title: String?
    public let recordType: String?
    public let assets: [LegacyAsset]?
    public init(id: String, title: String? = nil, recordType: String? = nil, assets: [LegacyAsset]? = nil) {
        self.id = id; self.title = title; self.recordType = recordType; self.assets = assets
    }
}
public enum GoldenClass: String, Sendable { case prescription, lab, ocrBlock, generic }
public enum GoldenRules {
    /// 置信三档委托 ConfidenceTier.tier 单一事实源（此前 0.8/0.5 字面量复制，
    /// 阈值调整两处漂移即档位判定分叉）
    public static func confidenceTier(_ c: Double) -> String { ConfidenceTier.tier(c).rawValue }
    /// §5.2 路由序：doc_type 优先（DocumentTemplateRegistry 按 type 选模板）；
    /// 仅当类型缺失或 other 时，才以「含非空 OCR 块」特征兜底为 ocrBlock。
    public static func classify(recordType: String?, assets: [LegacyAsset]?) -> GoldenClass {
        switch recordType {
        case "prescription", "medication": return .prescription
        case "lab": return .lab
        default:
            if let a = assets, a.contains(where: { !($0.textBlocks ?? []).isEmpty }) { return .ocrBlock }
            return .generic
        }
    }
}
