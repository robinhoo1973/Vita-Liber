import Foundation

/// 媒体生命周期纯判定（discussions/2026-10-16-local-storage-layout-council.md §7.1/§8 切片 13，
/// Domain 纯函数，Linux 可测）——GC 决策与 IO 分离：
/// refcount = DB 有效集**成员判定**（非计数器：计数器在「删文件成功/减计数失败」崩溃窗不可恢复，
/// 集合判定天然幂等，崩溃后重跑收敛）；600s 宽限（与 F8 reconcileUnreferenced 同值）；
/// **keep-on-doubt**：任何非规范形态文件一律保留（BR-002 宁留勿删）。
public enum MediaLifecycleRules {

    public struct FileVerdict: Sendable, Equatable {
        public var delete: Bool
        /// 保留理由（delete=false 时非空）：keep-unknown-shape / referenced / grace / empty-refs
        public var reason: String?
        public init(delete: Bool, reason: String? = nil) {
            self.delete = delete
            self.reason = reason
        }
    }

    /// 文件名是否为规范 sha 形态（`{64hex}.bin`）——只有规范形态才参与删除判定。
    public static func isSHAFile(_ name: String) -> Bool {
        guard name.hasSuffix(".bin") else { return false }
        return MediaDestinationRules.isLowercaseHex64(String(name.dropLast(4)))
    }

    /// originals/ 判定：仅 `{sha2}/{sha}.bin` 形态文件参与；sha ∉ 引用集且 mtime 超宽限 → 删。
    /// 其余（旧布局 {patientId}/{uuid}.{ext}、.partial、其他目录）一律 keep（宁留勿删）。
    public static func verdictOriginals(relativePath: String, mtime: TimeInterval,
                                        referencedSHAs: Set<String>, now: TimeInterval,
                                        grace: TimeInterval) -> FileVerdict {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2,
              parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              isSHAFile(String(parts[1])) else {
            return FileVerdict(delete: false, reason: "keep-unknown-shape")
        }
        let sha = String(parts[1].dropLast(4))
        guard !referencedSHAs.contains(sha) else { return FileVerdict(delete: false, reason: "referenced") }
        guard now - mtime > grace else { return FileVerdict(delete: false, reason: "grace") }
        return FileVerdict(delete: true)
    }

    /// sensitive/{memberId}/ 判定：仅 `{sha}.bin` 形态参与（`{assetId}.jpg/.blur.jpg` 由
    /// F8 SensitiveAssetStore.reconcileUnreferenced 按 asset 行管辖，本规则不越界）；
    /// sha ∉ 该成员引用集且超宽限 → 删。空引用集 = 成员已删/已清空 → 全删（显式删除路径语义）。
    public static func verdictSensitive(fileName: String, mtime: TimeInterval,
                                        referencedSHAs: Set<String>, now: TimeInterval,
                                        grace: TimeInterval) -> FileVerdict {
        guard isSHAFile(fileName) else { return FileVerdict(delete: false, reason: "keep-unknown-shape") }
        let sha = String(fileName.dropLast(4))
        guard !referencedSHAs.contains(sha) else { return FileVerdict(delete: false, reason: "referenced") }
        guard now - mtime > grace else { return FileVerdict(delete: false, reason: "grace") }
        return FileVerdict(delete: true)
    }

    /// 处理版根 sha 白名单：document_file.sha256 异构 token（"sha:"/"file:"/"pdf:"+hex）
    /// 剥前缀后为 64 位小写 hex 者入集——防止把「处理版字节落 originals/ CAS 池」的文件误删。
    public static func processedRootSHAs(from tokens: [String]) -> Set<String> {
        var result = Set<String>()
        for token in tokens {
            for prefix in ["sha:", "file:", "pdf:"] where token.hasPrefix(prefix) {
                let candidate = String(token.dropFirst(prefix.count))
                if MediaDestinationRules.isLowercaseHex64(candidate) { result.insert(candidate) }
            }
        }
        return result
    }
}
