import Foundation

/// 值承接盒：`@Sendable` 闭包（并发执行上下文）与调用方之间传递单值的安全通道。
/// Swift 6 语言模式禁止并发执行代码变异捕获 var（'mutation of captured var in
/// concurrently-executing code'，CI 35588830526 告警族）——承接盒以 NSLock 串行化
/// 读写代替裸 var 捕获（与 Infrastructure ProgressCounter 同纪律；锁序：
/// 每次读写独立加锁，无嵌套锁）。
public final class ValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    public init() {}

    public var value: Value? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}
