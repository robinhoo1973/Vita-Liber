import Foundation

/// 统一引擎抽象层（EAL, ADR-027）共享类型。
///
/// 设计目标（tech-spec §5.2.4）：将各可替换引擎能力（OCR / 语音输入 / 语音输出 /
/// 未来 AI·翻译）的「协议隔离 + 编译期分派 + 降级零差异」抽为一套共享类型 +
/// 中央注册表，使调用方经 `EngineRegistry.resolve(XxxFactory.self)` 取用能力协议，
/// 永不直接 import 具体引擎类型、永不知双轨/降级。
///
/// 依赖方向（tech-spec §1.1）：本文件（协议 / 工厂契约 / 注册表）在 `Protocols`；
/// 值对象 `EngineCapabilityProfile` 在 `Domain`（见 Domain/EngineCapabilityProfile.swift）。

// MARK: - 运行时上下文（if #available 的唯一集中处）

public struct EngineContext: Sendable {
    public enum Platform: String, Sendable, Equatable {
        case iOS, macOS, linux, other
    }
    public let platform: Platform
    /// 是否强制端侧 / 零网络（默认 true，离线红线）
    public let onDeviceOnlyRequired: Bool
    /// 可选：外部注入的 locale 探测结果
    public let probeLocales: [Locale]?

    public init(platform: Platform,
                onDeviceOnlyRequired: Bool = true,
                probeLocales: [Locale]? = nil) {
        self.platform = platform
        self.onDeviceOnlyRequired = onDeviceOnlyRequired
        self.probeLocales = probeLocales
    }

    /// 当前运行环境（编译期平台判定）
    public static let current: EngineContext = {
        #if os(iOS)
        EngineContext(platform: .iOS)
        #elseif os(macOS)
        EngineContext(platform: .macOS)
        #elseif os(Linux)
        EngineContext(platform: .linux)
        #else
        EngineContext(platform: .other)
        #endif
    }()
}

// MARK: - 工厂契约

/// 每个可替换引擎能力提供一个 EngineFactory 遵循体。
public protocol EngineFactory {
    associatedtype Capability
    /// 由 EngineContext 决定返回哪个具体引擎；外部依赖须按平台守卫
    static func make(_ context: EngineContext) -> Capability
    /// 该能力是否强制端侧 / 零网络（默认 true，离线红线）
    static var onDeviceOnly: Bool { get }
}

// MARK: - 中央引擎注册表（依赖注入容器）

public enum EngineError: Error, Sendable, Equatable {
    case offlineViolation
    case notRegistered
}

public final class EngineRegistry: @unchecked Sendable {
    public static let shared = EngineRegistry()

    private struct Registration {
        let capability: Any
        let factory: any EngineFactory.Type
    }

    /// 评审修正（线程安全）：`shared` 是公开可变单例——注册发生在组合根（MainActor），
    /// 解析却可能来自任何 Task。无锁字典在并发 register/resolve 下是数据竞争。
    /// NSLock 保护全部读写；`@unchecked Sendable` 与 InMemoryPinLockStore 同一纪律
    /// （锁保护的 final class 自身线程安全）。
    private let lock = NSLock()
    private var store: [ObjectIdentifier: Registration] = [:]

    public init() {}

    /// 注册某能力的具体引擎实例（由对应 EngineFactory.make 产出）
    public func register<C, F: EngineFactory>(_ capability: C, for factory: F.Type)
        where C == F.Capability {
        lock.lock(); defer { lock.unlock() }
        store[ObjectIdentifier(factory)] = Registration(capability: capability, factory: factory)
    }

    /// 解析某能力协议（调用方只拿协议，不拿具体类型）。
    /// 未注册即 fatalError：这是装配次序契约（组合根必须先 register），
    /// 宁可启动即崩也不带病运行——调用方可用 `isRegistered` 先探。
    public func resolve<C, F: EngineFactory>(_ factory: F.Type) -> C
        where C == F.Capability {
        lock.lock()
        guard let reg = store[ObjectIdentifier(factory)] else {
            lock.unlock()
            fatalError("EngineRegistry 未注册工厂: \(factory)")
        }
        lock.unlock()
        // 评审修正（审查问题 1）：契约保证 → 显式诊断。类型擦除注册表的
        // key = ObjectIdentifier(factory) 保证类型一致，但强制类型转换一旦被未来代码
        // 破坏（如跨模块重复注册）即裸崩且不可定位；改 as? + 显式 fatalError，
        // 崩溃信息带实际/期望类型，且维持「零强制解包」纪律。
        guard let capability = reg.capability as? C else {
            fatalError("EngineRegistry 类型契约被破坏: 工厂 \(factory) 注册了 \(type(of: reg.capability))，期望 \(C.self)")
        }
        return capability
    }

    public func isRegistered<F: EngineFactory>(_ factory: F.Type) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store[ObjectIdentifier(factory)] != nil
    }

    /// 离线守卫（红线一票否决）：任一已注册能力的工厂 `onDeviceOnly == false` 即失败。
    public func assertOfflineOnly() -> Result<Void, EngineError> {
        lock.lock(); defer { lock.unlock() }
        for reg in store.values where !reg.factory.onDeviceOnly {
            return .failure(.offlineViolation)
        }
        return .success(())
    }
}
