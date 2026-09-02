#if os(iOS) || os(macOS)
// CryptoKit / CommonCrypto / Security 仅 Apple 平台可用（Linux swiftly 工具链无这些模块）；
// PIN 哈希是设备端关注点，平台守卫与 GRDB 条件依赖同构（ERR#8）。
// 注意：格式与策略已抽到 Domain `PinHashScheme`，那部分在 Linux CI 上有测试覆盖——
// 守卫内只剩「调用系统 KDF/CSPRNG」，不含任何自研算法。
import Foundation
import CryptoKit
import CommonCrypto
import Security
import Domain

/// M1a 评审修正（架构 A3 / Swift S1-S2）：
/// - Domain 的 PinLockStateMachine 必须有生产实现接线（评审前为死代码）
/// - PIN 不得明文落 UserDefaults——SHA256(盐+pin) + 恒定时间比较
/// - Keychain 受保护条目 + PBKDF2-600k 归 M1c §6 加固（§8.6 清偿表登记）

/// PinLockPersisting 的 UserDefaults 实现（M1a 过渡介质；
/// §5.32 的 Keychain 实现 KeychainPinLockStore 随 M1c 替换——协议不变）
// @unchecked Sendable：UserDefaults 自身线程安全；Swift 6 模式前清偿（M0→M1c 并发日程）
public struct UserDefaultsPinLockStore: PinLockPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "pinLockSnapshot") {
        self.defaults = defaults
        self.key = key
    }
    public func load() throws -> PinLockSnapshot {
        guard let d = defaults.data(forKey: key) else { return PinLockSnapshot() }
        return try JSONDecoder().decode(PinLockSnapshot.self, from: d)
    }
    public func save(_ s: PinLockSnapshot) throws {
        defaults.set(try JSONEncoder().encode(s), forKey: key)
    }
}

/// PIN 口令哈希（tech-spec §6 / FR1.6）。
///
/// **第一原则应用（ADR-025 成熟实现优先）**：KDF 与随机数一律用系统审计实现，
/// 本文件不自研任何加密原语——
/// - 派生：CommonCrypto `CCKeyDerivationPBKDF`（PBKDF2-HMAC-SHA256，600k 迭代）；
/// - 盐：`SecRandomCopyBytes`（CSPRNG）。旧实现用 `UInt8.random(in:)`，
///   那是通用伪随机 API，不承诺密码学强度，不该用来产盐；
/// - 格式/策略/恒时比较：Domain `PinHashScheme`（纯逻辑，Linux CI 可测）。
///
/// 旧条目（`saltHex:digestHex` = 单轮 SHA256）仍可验证，但 `verify` 会回报
/// `needsRehash`，由调用方在验证成功后透明升级并覆盖落盘（FR1.6）——
/// 单轮 SHA256 对 6 位 PIN（10^6 空间）是秒级穷举，不能留在盘上。
public enum PinHasher {
    /// 验证结果。用类型区分「失败」与「成功但需升级」，避免调用方靠布尔值猜语义。
    public enum Verification: Equatable, Sendable {
        case failed
        case ok(needsRehash: Bool)
    }

    /// 新建哈希（当前方案）。返回 saltHex 便于调用方审计，stored 为自描述落盘串。
    public static func makeHash(pin: String) -> (saltHex: String, stored: String) {
        let salt = randomBytes(PinHashScheme.saltBytes)
        let saltHex = PinHashScheme.hexString(salt)
        let digest = pbkdf2SHA256(pin: pin, salt: salt,
                                  iterations: PinHashScheme.iterations,
                                  outputBytes: 32)
        return (saltHex, PinHashScheme.format(saltHex: saltHex,
                                              digestHex: PinHashScheme.hexString(digest)))
    }

    public static func verify(pin: String, stored: String) -> Verification {
        guard let parsed = PinHashScheme.parse(stored) else { return .failed }
        switch parsed {
        case .pbkdf2(let iterations, let saltHex, let digestHex):
            guard let salt = PinHashScheme.hexBytes(saltHex) else { return .failed }
            let actual = PinHashScheme.hexString(
                pbkdf2SHA256(pin: pin, salt: salt, iterations: iterations,
                             outputBytes: digestHex.count / 2))
            guard PinHashScheme.constantTimeEquals(actual, digestHex) else { return .failed }
            return .ok(needsRehash: PinHashScheme.needsRehash(stored))
        case .legacySHA256(let saltHex, let digestHex):
            guard let salt = PinHashScheme.hexBytes(saltHex) else { return .failed }
            let actual = legacySHA256(pin: pin, salt: salt)
            guard PinHashScheme.constantTimeEquals(actual, digestHex) else { return .failed }
            return .ok(needsRehash: true)     // 旧方案一律升级
        }
    }

    // MARK: - 系统实现委托（本节不含自研算法）

    /// CSPRNG。`SecRandomCopyBytes` 失败时不静默降级到弱随机——盐不可靠等于哈希不可靠。
    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes 失败(\(status))——无法产生密码学安全盐，拒绝以弱随机继续")
        }
        return bytes
    }

    /// PBKDF2-HMAC-SHA256（CommonCrypto）。迭代数由调用方给出，便于验证旧条目与测试向量。
    static func pbkdf2SHA256(pin: String, salt: [UInt8], iterations: Int, outputBytes: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: max(outputBytes, 1))
        let pinBytes = Array(pin.utf8)
        let status = pinBytes.withUnsafeBufferPointer { pinBuf in
            salt.withUnsafeBufferPointer { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinBuf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: pinBytes.count) { $0 },
                    pinBytes.count,
                    saltBuf.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived, derived.count)
            }
        }
        guard status == kCCSuccess else {
            fatalError("CCKeyDerivationPBKDF 失败(\(status))——不得回退到弱哈希")
        }
        return derived
    }

    /// 仅用于验证 M1a 遗留条目（单轮 SHA256(盐‖pin)）。不得用于新建哈希。
    static func legacySHA256(pin: String, salt: [UInt8]) -> String {
        var data = salt
        data.append(contentsOf: Array(pin.utf8))
        return PinHashScheme.hexString(Array(SHA256.hash(data: data)))
    }
}

#endif
