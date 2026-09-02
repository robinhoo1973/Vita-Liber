import Foundation

/// PIN 口令哈希的**格式与策略**（tech-spec §6 / FR1.6）。纯逻辑，无加密原语。
///
/// 为什么拆出来：KDF 本身必须用系统审计实现（CommonCrypto `CCKeyDerivationPBKDF`），
/// 那部分只能在 Apple 平台编译；但「用哪个方案、迭代多少、旧条目要不要重哈希、
/// 比较是否恒时」全是可判定的策略，锁在 `#if os(iOS)` 里等于在 Linux CI 上完全不可测。
/// 安全关键代码此前零测试，正是因为它整体被平台守卫挡住。
///
/// 存储格式自描述，便于无损演进：
/// - 新：`pbkdf2-sha256$<iterations>$<saltHex>$<digestHex>`
/// - 旧：`<saltHex>:<digestHex>`（M1a 的 SHA256(盐‖pin)，无方案标签）
///
/// 旧格式对 6 位 PIN 只有 10^6 空间且单轮 SHA256，GPU 上是秒级穷举——
/// 因此 `needsRehash` 对一切旧条目返回 true，在下次验证成功时透明升级（FR1.6）。
public enum PinHashScheme: Sendable {
    /// 生产迭代数：对齐 OWASP 密码存储清单（2023）对 PBKDF2-HMAC-SHA256 的推荐值
    public static let iterations = 600_000
    /// 盐长度（字节）。旧实现 16B，新方案 32B
    public static let saltBytes = 32
    public static let identifier = "pbkdf2-sha256"
    /// 落盘条目允许的最大迭代数（防资源耗尽）。
    ///
    /// 5WHY：验证必须按**落盘串自报**的迭代数重跑 KDF——坏串/被篡改串报一个天文
    /// 数字（如 2^31）时，一次验证就是数小时的 CPU 燃烧，等于可用性 DoS；
    /// 报 0 或负数则已由 `> 0` 拒绝。`parse` 因此对上限外的值直接判不可识别
    /// （fail-closed：验证失败、不升级、绝不放行）。上限取 10M——是当前生产值
    /// （600k）的 16 倍余量，足够容纳将来上调生产迭代数而无需触碰历史条目语义。
    public static let maxIterations = 10_000_000

    /// 已落盘条目的形态
    public enum Stored: Equatable, Sendable {
        case legacySHA256(saltHex: String, digestHex: String)
        case pbkdf2(iterations: Int, saltHex: String, digestHex: String)
    }

    /// 解析落盘串。返回 nil = 格式不可识别（视为验证失败，绝不放行）
    public static func parse(_ stored: String) -> Stored? {
        if stored.hasPrefix(identifier + "$") {
            let parts = stored.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0] == identifier,
                  let iterations = Int(parts[1]),
                  iterations > 0, iterations <= maxIterations,
                  isHex(parts[2]), !parts[2].isEmpty,
                  isHex(parts[3]), !parts[3].isEmpty
            else { return nil }
            return .pbkdf2(iterations: iterations, saltHex: parts[2], digestHex: parts[3])
        }
        let parts = stored.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, isHex(parts[0]), !parts[0].isEmpty,
              isHex(parts[1]), !parts[1].isEmpty
        else { return nil }
        return .legacySHA256(saltHex: parts[0], digestHex: parts[1])
    }

    /// 组装落盘串（新方案）
    public static func format(iterations: Int = iterations, saltHex: String, digestHex: String) -> String {
        "\(identifier)$\(iterations)$\(saltHex)$\(digestHex)"
    }

    /// 是否需要在下次验证成功后透明重哈希（FR1.6）：
    /// 旧 SHA256 条目一律要；PBKDF2 条目在迭代数低于当前生产值时也要（便于将来上调）
    public static func needsRehash(_ stored: String) -> Bool {
        switch parse(stored) {
        case .none:
            return false                        // 无法解析 → 验证会失败，不谈升级
        case .legacySHA256:
            return true
        case .pbkdf2(let iterations, _, _):
            return iterations < self.iterations
        }
    }

    /// 恒定时间比较（防逐位时序侧信道）。长度不等直接假——长度本身不是秘密。
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ua = Array(a.utf8), ub = Array(b.utf8)
        guard ua.count == ub.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ua.count { diff |= ua[i] ^ ub[i] }
        return diff == 0
    }

    public static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.count % 2 == 0 && s.allSatisfy(\.isHexDigit)
    }

    public static func hexBytes(_ hex: String) -> [UInt8]? {
        guard isHex(hex) else { return nil }
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

    public static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
