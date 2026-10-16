import Foundation

/// 媒体落盘路径规则（discussions/2026-10-16-local-storage-layout-council.md §7.1）——
/// 运行时布局与载具布局的**唯一**路径知识（Domain 纯函数，Linux 可测）：
/// ```
/// Documents/MedicalNotes/                    ← 媒体根（注入点）
/// ├── originals/{sha256前2}/{sha256}.bin    ← 非敏感原件 CAS（路径可由 sha 唯一重算）
/// ├── sensitive/{memberId}/
/// │   ├── {sha256}.bin                      ← F5 敏感原件
/// │   ├── {assetId}.jpg                     ← F8 照片（不改名，asset 行权威）
/// │   └── {assetId}.blur.jpg                ← F8 模糊版
/// ```
/// 载具（zip 内）统一 `media/{sha256前2}/{sha256}.bin`，导入时剥 `media/` 前缀落盘。
/// 写盘中一律 `{final}.partial`；引用方永不读 `.partial`。
public enum MediaDestinationRules {

    /// zip 内条目路径：`media/{sha256前2}/{sha256}.bin`。
    public static func carrierRelativePath(sha256: String) -> String {
        "media/\(sha256.prefix(2))/\(sha256).bin"
    }

    /// 非敏感原件落盘路径：`originals/{sha256前2}/{sha256}.bin`。
    public static func originalRelativePath(sha256: String) -> String {
        "originals/\(sha256.prefix(2))/\(sha256).bin"
    }

    /// F5 敏感原件落盘路径：`sensitive/{memberId}/{sha256}.bin`。
    public static func sensitiveOriginalRelativePath(memberId: UUID, sha256: String) -> String {
        "sensitive/\(memberId.uuidString)/\(sha256).bin"
    }

    /// F8 照片落盘路径：`sensitive/{memberId}/{assetId}.jpg`（命名与 SensitiveAssetStore 对齐，不改名）。
    public static func photoRelativePath(memberId: UUID, assetId: UUID) -> String {
        "sensitive/\(memberId.uuidString)/\(assetId.uuidString).jpg"
    }

    /// F8 模糊版落盘路径：`sensitive/{memberId}/{assetId}.blur.jpg`。
    public static func blurRelativePath(memberId: UUID, assetId: UUID) -> String {
        "sensitive/\(memberId.uuidString)/\(assetId.uuidString).blur.jpg"
    }

    /// 哈希规范形：64 位**小写**十六进制（单规范形——文件名构造/校验器/跨端对拍唯一形态）。
    public static func isLowercaseHex64(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// 相对路径安全形：非绝对、无 `..` 分量、非空、无 `.partial` 后缀、`/` 分隔规范。
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix(".partial") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return !components.contains(where: { $0.contains("\0") || $0.hasPrefix("~") })
    }

    /// 条目规范形校验——落盘前必过：文档条目按 (sha, 敏感级, memberId) 重算比对，
    /// 照片/模糊版条目按形状校验（`sensitive/{uuid}/{uuid}.jpg|.blur.jpg`）。
    /// 非敏感文档必须 kind=original、memberId=nil；敏感件必须携带 memberId。
    public static func isCanonicalEntry(_ entry: MediaManifestEntry) -> Bool {
        guard isLowercaseHex64(entry.sha256), isSafeRelativePath(entry.relativePath) else { return false }
        switch entry.kind {
        case .original, .processed:
            if entry.isSensitive {
                guard let memberId = entry.memberId else { return false }
                return entry.relativePath == sensitiveOriginalRelativePath(memberId: memberId, sha256: entry.sha256)
            }
            return entry.memberId == nil
                && entry.relativePath == originalRelativePath(sha256: entry.sha256)
        case .photo, .blur:
            guard entry.isSensitive, let memberId = entry.memberId else { return false }
            // 评审修复：原式先比对 photoRelativePath(memberId:assetId: memberId)——把成员 id
            // 塞进 assetId 槽（恒真下被子句 isPhotoShape 吸收的死子句）。形状校验单点：
            // assetId 无法由条目字段重算，只验三段形 + assetId 为 UUID。
            return isPhotoShape(entry.relativePath, memberId: memberId, kind: entry.kind)
        }
    }

    /// 形状校验（F8 条目 assetId 无法由条目字段重算）：三段式 `sensitive/{uuid}/{uuid}[.blur].jpg`。
    private static func isPhotoShape(_ path: String, memberId: UUID, kind: MediaKind) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "sensitive",
              components[1] == Substring(memberId.uuidString) else { return false }
        let fileName = String(components[2])
        let suffix = kind == .blur ? ".blur.jpg" : ".jpg"
        guard fileName.hasSuffix(suffix) else { return false }
        let idPart = fileName.dropLast(suffix.count)
        return UUID(uuidString: String(idPart)) != nil
    }
}
