import Foundation

/// 模型安装目录布局与保留规则（业主 2026-09-16 多档模型定案）。
///
/// 三条语义**正交**，此前被混成一条，故 `pruneOldVersions` 只留一份：
///   ① **可同时下载多档** —— 同一家族的不同变体各有独立目录，互不覆盖；
///   ② **同一时刻只有一档生效** —— `active.json` 指针指向哪一档，引擎只加载一份权重；
///   ③ **可按档删除释放空间** —— 删某档只删它的目录（在用 / 被租用则拒）。
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

    /// 保留集：**每个变体各自的最新一个**，外加刚装成的与当前生效的。
    ///
    /// 旧规则 `keeping: [新目录, 旧激活目录]` 在单档家族下等价、在多档下**会删掉另一档**
    /// ——业主 2026-09-16 明确「可以同时下载多档」，故保留粒度必须是 (家族, 变体) 而非家族。
    /// 空变体（单档家族 / 历史布局）自成一档，行为与旧规则一致。
    public static func keepingForPrune(
        candidates: [(name: String, version: String, variant: String?)],
        newlyInstalled: String,
        activeName: String?
    ) -> Set<String> {
        var newestPerVariant: [String: (name: String, version: String)] = [:]
        for candidate in candidates {
            let key = candidate.variant ?? ""
            guard let current = newestPerVariant[key] else {
                newestPerVariant[key] = (candidate.name, candidate.version)
                continue
            }
            if ASRVersion.isNewer(candidate.version, than: current.version) {
                newestPerVariant[key] = (candidate.name, candidate.version)
            }
        }
        var keeping = Set(newestPerVariant.values.map(\.name))
        keeping.insert(newlyInstalled)
        if let activeName { keeping.insert(activeName) }
        return keeping
    }

    /// 可删除性（业主第 ③ 条）：正在生效的一档不可删——引擎正加载它；
    /// 被租用（有活跃识别会话）的一档不可删，由 `ASRModelAssets.removeIfUnused` 兜底。
    /// 此处只判「是否为当前生效档」这一条业务规则，租用判定留在 Infrastructure。
    public static func isDeletable(directoryName: String, activeName: String?) -> Bool {
        guard let activeName else { return true }
        return directoryName != activeName
    }
}
