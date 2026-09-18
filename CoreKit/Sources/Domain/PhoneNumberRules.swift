import Foundation

/// 电话号码拨号归一（Domain 纯函数；全仓审查 2026-09-18 · F-A2-05）。
/// 此前四处 `URL(string: "tel://\(number)")` 直接拼接用户录入的号码：含空格/括号/
/// 短横时 `URL(string:)` 为 nil 或 iOS 16 静默不拨——急救路径（BR-012）拨号失败
/// 且无任何反馈。归一规则：保留数字（全角数字折为 ASCII）与首位 `+`，
/// 去空格/短横/括号/点等分隔符；出现其它字符视为非法 → nil（调用侧不拨、响亮提示）。
public enum PhoneNumberRules {
    public static func dialable(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        for (index, ch) in trimmed.enumerated() {
            if let digit = ch.wholeNumberValue, ch.isNumber {
                out.append(String(digit))
            } else if ch == "+" && index == 0 {
                out.append(ch)
            } else if separators.contains(ch) {
                continue
            } else {
                return nil
            }
        }
        return out.isEmpty || out == "+" ? nil : out
    }

    /// 允许出现在录入号码中的分隔符（归一时丢弃）。
    static let separators: Set<Character> = [" ", "-", "(", ")", ".", "　", "（", "）", "－", "·"]
}
