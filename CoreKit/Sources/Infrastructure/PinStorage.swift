#if os(iOS) || os(macOS)
// CryptoKit 仅 Apple 平台可用（Linux swiftly 工具链无此模块）；PIN 哈希是设备端
// 关注点，Linux CI 只守 Domain 层门禁——平台守卫与 GRDB 条件依赖同构（ERR#8）。
import Foundation
import CryptoKit
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

/// PIN 哈希与恒定时间比较（评审 S2：原 hash() 是恒等函数，PIN 明文落盘且注释失实）
public enum PinHasher {
    /// 盐 16 字节随机；哈希 = SHA256(盐‖pin)，落盘格式 "saltHex:digestHex"（区分明文条目）
    public static func makeHash(pin: String) -> (saltHex: String, stored: String) {
        var salt = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { salt[i] = UInt8.random(in: 0...255) }
        let saltHex = salt.map { String(format: "%02x", $0) }.joined()
        return (saltHex, "\(saltHex):\(digest(pin: pin, salt: salt))")
    }

    public static func verify(pin: String, stored: String) -> Bool {
        let parts = stored.split(separator: ":").map(String.init)
        guard parts.count == 2, let salt = hexBytes(parts[0]) else { return false }
        let expected = parts[1]
        let actual = digest(pin: pin, salt: salt)
        return constantTimeEqual(actual, expected)
    }

    /// 常量时间比较（防逐位时序侧信道，评审 S2）
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ua = Array(a.utf8), ub = Array(b.utf8)
        guard ua.count == ub.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ua.count { diff |= ua[i] ^ ub[i] }
        return diff == 0
    }

    static func digest(pin: String, salt: [UInt8]) -> String {
        var data = salt
        data.append(contentsOf: Array(pin.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

#endif
