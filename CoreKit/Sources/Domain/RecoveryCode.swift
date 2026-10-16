import Foundation

/// 30 位恢复码（discussions/2026-10-16-backup-sync-share-design.md §5.2）：
/// 字母表剔除易混字符（I/O/0/1）——手抄/朗读歧义最小化；
/// 一次性展示（注册时），关怀模式大字号/可粘贴；为主密钥的灾难恢复逃生舱，非主路径。
public enum RecoveryCode {

    public static let length = 30
    /// 32 字符集（A–Z 去 I/O + 2–9 去 0/1）→ 每字符 5 bit，30 字符 ≈ 150 bit 熵。
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func generate<R: RandomNumberGenerator>(using generator: inout R) -> String {
        String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }
}
