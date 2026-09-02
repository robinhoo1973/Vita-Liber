import Foundation

/// 跨平台几何类型（零框架，Domain 可用）。
///
/// Apple 侧可桥接 CoreGraphics；Linux 侧纯 Swift 实现。

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

#if os(iOS) || os(macOS)
import CoreGraphics

public extension Size {
    init(_ cg: CGSize) { self.init(width: cg.width, height: cg.height) }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

public extension Point {
    init(_ cg: CGPoint) { self.init(x: cg.x, y: cg.y) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public extension Rect {
    init(_ cg: CGRect) { self.init(origin: Point(cg.origin), size: Size(cg.size)) }
    var cgRect: CGRect { CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
}
#endif