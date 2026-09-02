import Foundation

/// 跨平台几何类型（零框架，Domain 可用）。
///
/// 纯 Foundation 实现；如需 CoreGraphics 桥接（cgSize/cgPoint/cgRect），
/// 请放 Infrastructure 层扩展（Domain 零框架门禁 L0 [5]）。

/// 尺寸（宽/高）。
public struct Size: Sendable, Equatable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width; self.height = height
    }
}

/// 点（x/y）。
public struct Point: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x; self.y = y
    }
}

/// 矩形。
public struct Rect: Sendable, Equatable, Codable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin; self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = Point(x: x, y: y)
        self.size = Size(width: width, height: height)
    }
}