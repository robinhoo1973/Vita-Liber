import Foundation

/// 同步信封文件名契约（discussions/2026-10-16-backup-sync-share-design.md §5.3）：
/// `sync-{realmId}-{deviceId}-{seq}.vlbu` —— per-device 文件（各写各文件=单写者语义，
/// 规避 iCloud 文档容器无 CAS 的 bounced 副本/静默选赢家）；seq 单调递增
/// （modificationDate 不可靠，同设备多版本取 max seq，LWW 安全）。
/// 文件名即身份三元组——不解析信封体即可合并预选（SyncMergeRules）。
public enum SyncFileNaming {

    public static let prefix = "sync-"
    public static let `extension` = "vlbu"

    public struct Identity: Sendable, Equatable {
        public var realmId: UUID
        public var deviceId: UUID
        public var seq: UInt64
        public init(realmId: UUID, deviceId: UUID, seq: UInt64) {
            self.realmId = realmId
            self.deviceId = deviceId
            self.seq = seq
        }
    }

    public static func encode(_ identity: Identity) -> String {
        "\(prefix)\(identity.realmId.uuidString)-\(identity.deviceId.uuidString)-\(identity.seq).\(`extension`)"
    }

    /// 严格解析：前缀/扩展名/三段 UUID×2 + 十进制 seq 任一不符 → nil（目录里任何杂散文件不得入合并）。
    public static func decode(_ name: String) -> Identity? {
        guard name.hasPrefix(prefix), name.hasSuffix(".\(`extension`)") else { return nil }
        let core = String(name.dropFirst(prefix.count).dropLast(1 + Self.extension.count))
        // core = {realm}-{device}-{seq}；UUID 标准串 8-4-4-4-12 恰 5 段 × 2 + seq 1 段 = 11 段，
        // 按段位重组回 UUID（UUID 自带连字符，无法按分隔符直切）
        let parts = core.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 11,
              let seq = UInt64(parts[10]),
              let realm = UUID(uuidString: parts[0...4].joined(separator: "-")),
              let device = UUID(uuidString: parts[5...9].joined(separator: "-")) else { return nil }
        return Identity(realmId: realm, deviceId: device, seq: seq)
    }
}
