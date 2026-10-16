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

    /// 输入归一化（粘贴/手抄路径，全评审修复）：忽略大小写与分隔符（空格/连字符/分组），
    /// 只保留 ASCII 字母数字——恢复码经用户转抄，iOS 键盘/便签常在组间插空格或连字符，
    /// 未归一化的原文派生 KEK 与签发时不同（码正确却报「码错」）。不做混淆字符猜测
    /// （I/O/0/1 不在字母表，猜错=把错码变成另一个错码，误导用户）。
    public static func normalize(_ input: String) -> String {
        input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
