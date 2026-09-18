import Foundation

/// ADR-008 铝箔板盘点技术验证（P2 视觉）占位端口。
///
/// M3 零阻塞项只做**技术验证的验证**：确认「OCR 派生条目必待确认（BR-003）」
/// 这条纪律在铝箔板识别场景的落点——计数识别结果一律 D 级，绝不自动作数。
/// 真机 Vision 实现归 P2；此占位让 BR-003 在协议层就有约束。
public protocol InventoryScanner: Sendable {
    /// 从铝箔板图像识别剩余药片数。结果恒 D 级待确认（BR-003）。
    func scanBlisterCount(_ imageData: Data) async throws -> BlisterScanResult
}

public struct BlisterScanResult: Sendable, Equatable {
    public var count: Int
    /// 恒 false —— 机器识别计数是候选不是事实，入库前必须用户确认
    public var autoConfirmed: Bool { false }
    public init(count: Int) { self.count = count }
}

public actor StubInventoryScanner: InventoryScanner {
    private let scriptedCount: Int
    public init(count: Int = 0) { self.scriptedCount = count }
    public func scanBlisterCount(_ imageData: Data) async throws -> BlisterScanResult {
        BlisterScanResult(count: scriptedCount)
    }
}
