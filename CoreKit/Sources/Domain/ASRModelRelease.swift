import Foundation

/// FR17.15（业主 2026-09-12 决定）：ASR 模型的**运行时下载索引**（Domain 纯值对象）。
///
/// 索引由 `downloads/<app>/<asset>/index.json` 提供（见仓库 `downloads/README.md`）：
/// - 一份索引覆盖一个资源类别（当前 = asr），条目与 `VoiceEngineChoice.rawValue` 对齐；
/// - 地址采用 `baseUrl` + 相对文件名（换 CDN/对象存储不改 App）；
/// - `sha256` 为空或 `bytes == 0` 视为**未发布**条目：客户端必须跳过，绝不下载未核验包。
public struct ASRModelReleaseIndex: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var baseUrl: String?
    public var models: [ASRModelRelease]

    public init(schemaVersion: Int = 1, baseUrl: String? = nil, models: [ASRModelRelease]) {
        self.schemaVersion = schemaVersion
        self.baseUrl = baseUrl
        self.models = models
    }

    /// 客户端支持的结构版本（未知版本必须拒绝——防按未知语义误装）。
    public static let supportedSchemaVersion = 1

    public var isSupported: Bool { schemaVersion == Self.supportedSchemaVersion }
}

/// 单个模型发布条目。
public struct ASRModelRelease: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var version: String
    public var bytes: Int64?
    public var sha256: String
    public var url: String
    public var minAppVersion: String?
    public var license: String?

    public init(id: String, version: String, bytes: Int64? = nil, sha256: String, url: String,
                minAppVersion: String? = nil, license: String? = nil) {
        self.id = id; self.version = version
        self.bytes = bytes; self.sha256 = sha256
        self.url = url; self.minAppVersion = minAppVersion; self.license = license
    }

    /// 已发布（可下载）：必须有非空 sha256 与正字节数——空 sha 条目只表示「占位」。
    public var isPublished: Bool {
        !sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (bytes ?? 0) > 0
    }

    /// 是否兼容当前 App 版本（未声明 minAppVersion 视为兼容）。
    public func isCompatible(appVersion: String) -> Bool {
        guard let minimum = minAppVersion, !minimum.isEmpty else { return true }
        return !ASRVersion.isNewer(minimum, than: appVersion) || minimum == appVersion
    }

    /// 解析下载地址：绝对 URL 原样；相对路径拼 `baseUrl`（无 baseUrl 则失败）。
    /// baseUrl 无尾斜杠时按 RFC 3986 会吞掉末段路径——先补斜杠再拼接，
    /// 保证 `…/asr-models` + `x.zip` ⇒ `…/asr-models/x.zip` 而非 `…/x.zip`。
    public func resolvedURL(baseURL: URL?) -> URL? {
        if let absolute = URL(string: url), absolute.scheme != nil { return absolute }
        guard let baseURL else { return nil }
        var base = baseURL
        if !base.path.hasSuffix("/") { base = base.appendingPathComponent("") }
        return URL(string: url, relativeTo: base)?.absoluteURL
    }

    /// 该条目是否比 `installedVersion` 新（installed 为 nil 时恒 true）。
    public func isNewer(than installedVersion: String?) -> Bool {
        ASRVersion.isNewer(version, than: installedVersion)
    }
}

/// 版本比较（模型版本是「上游语义版本 + 日期」混合形态，如 `0.6b-int8-v2026.03.25`）。
///
/// 规则：按非字母数字切段，逐段比较；两段均为纯数字时按整数比（`03` == `3`，
/// `20260912` > `20260325`），否则先按段首连续数字前缀比较（`6b` < `10`、
/// `9` < `10a`），前缀相同再按字典序（忽略大小写）；前缀相同时段数多者为新。
/// 这是「可解释、可测试」的最小实现——不引入 semver 库（Domain 零依赖纪律）。
public enum ASRVersion {
    public static func isNewer(_ lhs: String, than rhs: String?) -> Bool {
        guard let rhs, !rhs.isEmpty else { return !lhs.isEmpty }
        let left = segments(lhs), right = segments(rhs)
        for index in 0..<min(left.count, right.count) {
            let a = left[index], b = right[index]
            if a == b { continue }
            switch compareSegment(a, b) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: continue
            }
        }
        return left.count > right.count
    }

    /// 单段比较：纯数字按整数；混合段先比数字前缀，前缀相等再按字典序。
    private static func compareSegment(_ a: String, _ b: String) -> ComparisonResult {
        if let ai = Int(a), let bi = Int(b) {
            if ai == bi { return .orderedSame }
            return ai > bi ? .orderedDescending : .orderedAscending
        }
        let an = leadingDigits(a), bn = leadingDigits(b)
        if let an, let bn, an != bn {
            return an > bn ? .orderedDescending : .orderedAscending
        }
        return a.lowercased().compare(b.lowercased())
    }

    private static func leadingDigits(_ value: String) -> Int? {
        let prefix = value.prefix(while: { $0.isNumber })
        guard !prefix.isEmpty else { return nil }
        return Int(prefix)
    }

    static func segments(_ value: String) -> [String] {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
