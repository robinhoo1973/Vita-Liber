import Foundation

/// 模型安装目录布局与保留规则（业主 2026-09-16 多档模型定案；2026-10-05 修订）。
///
/// 语义（2026-10-05 业主裁定修订）：
///   ① **可切换档位** —— 同一家族的不同变体各有独立目录，互不覆盖；
///   ② **同一时刻只有一档生效** —— `active.json` 指针指向哪一档，引擎只加载一份权重；
///   ③ **每家族最多保留一个已装档** —— 安装新档即删除旧档（含其它变体；被租用时
///      登记延后删除），切换回旧档需重新下载。目录粒度 prune 在家族根内执行，
///      保留集 = 新装目录。
///
/// 目录名：`<variant>~<version>-<sha12>-<uuid>`；**变体缺省时不带变体段**，
/// 退回历史布局 `<version>-<sha12>-<uuid>` —— 故既有安装**零迁移**、单档家族行为不变。
///
/// 分隔符取 `~` 而非 `-`：`ModelResourcePolicy.isSlug` 只允许字母数字与 `-._`，
/// 而版本号自身含 `-`（如 `small-ctc-int8-2025-04-02`），用 `-` 无法无歧义切分；
/// `~` 不在 slug 字符集内，切分唯一。
public enum ASRInstallLayout {
    public static let variantSeparator: Character = "~"
    /// 目录尾段里 sha256 前缀的长度（与 `ASRModelDownloadService` 的命名同源）。
    public static let shortHashLength = 12

    /// 生成安装目录名。`variant` 为 nil / 空 → 历史布局（单档家族）。
    public static func directoryName(variant: String?, version: String,
                                     sha256: String, uuid: String) -> String {
        let tail = String(version.prefix(60))
            + "-" + String(sha256.prefix(shortHashLength))
            + "-" + uuid
        guard let variant, !variant.isEmpty else { return tail }
        return variant + String(variantSeparator) + tail
    }

    /// 解析目录名。返回 nil = **不是**本布局（调用方必须忽略、绝不可删）。
    ///
    /// **从末尾定长解析，绝不按 `-` 切分**：UUID 自身含 4 个连字符
    /// （`0F1E2D3C-4B5A-...`），按分隔符切会把 uuid 拆成 5 段——首版即踩此坑，
    /// 由 `ASRInstallLayoutTests.解析无歧义()` 抓出。末尾结构是定长的：
    /// `<36 字符 uuid>` ← `-` ← `<12 字符 sha 前缀>` ← `-` ← `<version 任意>`。
    public static func parseDirectory(_ name: String) -> (variant: String?, version: String)? {
        let variant: String?
        let rest: Substring
        if let sep = name.firstIndex(of: variantSeparator) {
            variant = String(name[name.startIndex..<sep])
            rest = name[name.index(after: sep)...]
        } else {
            variant = nil
            rest = name[...]
        }
        // 最短形态：version(≥1) + "-" + sha(12) + "-" + uuid(36)
        guard rest.count >= 1 + 1 + shortHashLength + 1 + 36 else { return nil }
        let uuidText = String(rest.suffix(36))
        guard UUID(uuidString: uuidText) != nil else { return nil }
        // 去掉 uuid 本身（36 字符），**保留**它前面那个 `-` 用于校验——
        // 写成 dropLast(37) 会连带吃掉分隔符（首版即此 off-by-one，末字符得 "b" 而非 "-"）。
        let withoutUUID = rest.dropLast(36)
        guard withoutUUID.last == "-" else { return nil }
        let head = withoutUUID.dropLast()                   // 去掉该 '-'
        let shortHash = head.suffix(shortHashLength)
        guard shortHash.count == shortHashLength, head.count > shortHashLength else { return nil }
        let version = head.dropLast(shortHashLength + 1)    // 再去掉 "-<sha12>"
        guard !version.isEmpty else { return nil }
        return (variant, String(version))
    }

    /// 保留集（业主 2026-10-05 裁定：**每家族最多保留一个已装档**）。
    ///
    /// 新装即生效，旧档（含同家族其它变体、历史布局目录）一律清出——切换档位
    /// 后旧档不在盘上，切回需重新下载。租用中的旧档由 Infrastructure 的
    /// `removeIfUnused` 登记延后删除，不被本函数硬删。
    /// 单档家族的版本更新行为不变（保留新装）。
    ///
    /// 收口批D（第九轮审查 I2/D3，2026-10-10）：`candidates` / `activeName`
    /// 两个**假参数已删**——单保留语义下二者按裁定本就被忽略（生效档保护由
    /// `isDeletable` + `removeIfUnused` 租约承担），签名却暗示一份「按变体/
    /// 按生效档」的 keep-set 策略，与实现相悖（本仓先例：假面签名=误导接口）。
    /// 调用点（ASRModelDownloadService.pruneOldVersions 与测试）同步。
    public static func keepingForPrune(newlyInstalled: String) -> Set<String> {
        [newlyInstalled]
    }

    /// 可删除性（业主第 ③ 条）：正在生效的一档不可删——引擎正加载它；
    /// 被租用（有活跃识别会话）的一档不可删，由 `ASRModelAssets.removeIfUnused` 兜底。
    /// 此处只判「是否为当前生效档」这一条业务规则，租用判定留在 Infrastructure。
    public static func isDeletable(directoryName: String, activeName: String?) -> Bool {
        guard let activeName else { return true }
        return directoryName != activeName
    }
}
