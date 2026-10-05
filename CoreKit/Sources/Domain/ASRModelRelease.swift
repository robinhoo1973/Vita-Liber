import Foundation

/// FR17.15（业主 2026-09-12 决定）：ASR 模型的**运行时下载索引**（Domain 纯值对象）。
///
/// 索引由已验签的 Release 目录或 App 内嵌基线提供（见 `.github/ASR_RELEASE.md`）：
/// - 一份索引覆盖一个资源类别（当前 = asr），条目与 `VoiceEngineChoice.rawValue` 对齐；
/// - 地址采用已授权的 `baseUrl` + 相对文件名；
/// - `sha256` 为空或 `bytes == 0` 视为**未发布**条目：客户端必须跳过，绝不下载未核验包。
public struct ASRModelReleaseIndex: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var baseUrl: String?
    public var models: [ASRModelRelease]
    /// 家族级本地化文案（2026-10-05 业主定：模型文字描述全部由 CI 生成的签名目录
    /// JSON 提供，App 不写死；缺失 = 旧目录，UI 回落到内置 L10n 兜底）。
    public var families: [ASRModelFamily]?

    public init(schemaVersion: Int = 1, baseUrl: String? = nil, models: [ASRModelRelease],
                families: [ASRModelFamily]? = nil) {
        self.schemaVersion = schemaVersion
        self.baseUrl = baseUrl
        self.models = models
        self.families = families
    }

    /// 客户端支持的结构版本（未知版本必须拒绝——防按未知语义误装）。
    public static let supportedSchemaVersion = 1

    public var isSupported: Bool { schemaVersion == Self.supportedSchemaVersion }

    public func family(for id: String) -> ASRModelFamily? {
        (families ?? []).first { $0.id == id }
    }
}

/// 目录内的本地化文案（三语键与 App 资源 locale 对齐；任意语言可缺省）。
public struct ASRLocalizedText: Codable, Sendable, Equatable {
    public var zhHans: String?
    public var zhHant: String?
    public var en: String?

    enum CodingKeys: String, CodingKey {
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en
    }

    public init(zhHans: String? = nil, zhHant: String? = nil, en: String? = nil) {
        self.zhHans = zhHans; self.zhHant = zhHant; self.en = en
    }

    /// 按 App 首选语言解析：繁体系 → zh-Hant；简体/其他 zh → zh-Hans；en → en；
    /// 首选语言缺该文时**先在同一语言族内**按 zh-Hans → zh-Hant → en 兜底，
    /// 再试下一首选语言（2026-10-05 审查修正：旧实现缺键即 continue 跳到下一
    /// 语言——zh-TW 用户遇仅含 zh-Hans+en 的部分目录会看到英文而弃简体）。
    public func resolved(preferredLanguages: [String]? = nil) -> String? {
        let languages = preferredLanguages ?? Locale.preferredLanguages
        for language in languages {
            if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW")
                || language.hasPrefix("zh-HK") || language.hasPrefix("zh-MO") {
                if let zhHant { return zhHant }
                if let zhHans { return zhHans }
                continue
            }
            if language.hasPrefix("zh") {
                if let zhHans { return zhHans }
                if let zhHant { return zhHant }
                continue
            }
            if language.hasPrefix("en") { if let en { return en }; continue }
        }
        return zhHans ?? zhHant ?? en
    }
}

/// 家族级条目（id 与 `ASRModelRelease.id` 对齐）。2026-10-05 业主裁定：模型信息
/// （名称/简介/语言覆盖/方言覆盖）全由 CI 生成的目录 JSON 提供，App 不写死；
/// 旧目录缺字段解码得 nil（语言覆盖为空 → auto 链回落 classic，检查更新即修复）。
public struct ASRModelFamily: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: ASRLocalizedText?
    public var hint: ASRLocalizedText?
    public var languages: [String]?
    public var dialects: [String]?

    public init(id: String, name: ASRLocalizedText? = nil, hint: ASRLocalizedText? = nil,
                languages: [String]? = nil, dialects: [String]? = nil) {
        self.id = id; self.name = name; self.hint = hint
        self.languages = languages; self.dialects = dialects
    }
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
    public var expandedBytes: Int64?
    public var runtime: String?
    public var packaging: String?
    /// 下载包加密信封方案(2026-10-05 R1):"aes256gcm-v1" = 整包 zip 的块式
    /// AES-GCM 信封(下载字节即信封字节,sha256/bytes 覆盖信封);nil = 明文
    /// zip(历史目录条目,新发布一律加密)。旧 App 不解该键,下载新包会在
    /// 解压步 fail-closed,不构成误装。
    public var encryption: String?
    public var artifactRevision: Int?
    /// 变体档位（业主 2026-09-16 定案）：同一家族（`id`）可提供多档，**可同时下载共存**，
    /// 但**同一时刻只有一档生效**（引擎只加载一份权重），且可按档删除以释放空间。
    /// 见 `ASRInstallLayout` 的三条正交语义。
    ///
    /// 缺省 nil = 单档家族。历史条目一律无此键、解码得 nil；`id` 仍是家族身份
    /// （不新增 `VoiceEngineChoice` case），故 **无需 schema 版本变更**、
    /// `ASRModelReleaseIndex.supportedSchemaVersion` 保持 1、旧客户端忽略该键照常工作。
    public var variant: String?
    /// 档位短标签（选择器/按钮文案，如「超轻」「标准」，2026-10-05 业主定：
    /// 由 CI 目录 JSON 提供；缺失 = 旧目录，回落到 L10n small/medium/large 映射）。
    public var tierName: ASRLocalizedText?
    /// 档位说明文案（参数/性能说明，2026-10-05 业主定：由 CI 目录 JSON 提供；
    /// 缺失 = 旧目录，UI 只呈现本地计算的字节/峰值参数行）。
    public var tierHint: ASRLocalizedText?

    public init(id: String, version: String, bytes: Int64? = nil, sha256: String, url: String,
                minAppVersion: String? = nil, license: String? = nil,
                expandedBytes: Int64? = nil, runtime: String? = nil, packaging: String? = nil,
                encryption: String? = nil, artifactRevision: Int? = nil, variant: String? = nil,
                tierName: ASRLocalizedText? = nil, tierHint: ASRLocalizedText? = nil) {
        self.id = id; self.version = version
        self.bytes = bytes; self.sha256 = sha256
        self.url = url; self.minAppVersion = minAppVersion; self.license = license
        self.expandedBytes = expandedBytes; self.runtime = runtime
        self.packaging = packaging; self.encryption = encryption; self.artifactRevision = artifactRevision
        self.variant = variant
        self.tierName = tierName
        self.tierHint = tierHint
    }

    /// 档位权重（业主裁决 D6 修复）：variant 档名的字典序与大小序不一致——
    /// 清单排序、默认选择与 RAM 建议不得依赖字典序。大小序单一事实源
    /// （2026-10-05 iOS 适用性评估后扩档：tiny<base<small<medium<turbo<large，
    /// 按体积升序）；未知/缺失档按最大权重处理（排末尾，绝不误推荐给低 RAM 设备）。
    public static func variantWeight(_ variant: String?) -> Int {
        switch variant {
        case "tiny": return 0
        case "base": return 1
        case "small": return 2
        case "medium": return 3
        case "turbo": return 4
        case "large": return 5
        default: return 6
        }
    }

    /// 已发布（可下载）：必须有非空 sha256 与正字节数——空 sha 条目只表示「占位」。
    public var isPublished: Bool {
        ModelResourcePolicy.isSHA256(sha256) && (bytes ?? 0) > 0
            && (bytes ?? 0) <= ModelResourcePolicy.packageBytes
            && ModelResourcePolicy.isSlug(id) && ModelResourcePolicy.isSlug(version)
    }

    /// 是否兼容当前 App 版本（未声明 minAppVersion 视为兼容）。
    public func isCompatible(appVersion: String) -> Bool {
        guard let minimum = minAppVersion, !minimum.isEmpty else { return true }
        return !ASRVersion.isNewer(minimum, than: appVersion) || minimum == appVersion
    }

    /// 解析下载地址（安全审查 2026-09-12 加固）：索引 `url` **只允许纯相对路径**——
    /// 绝对 URL 与协议相对形式（`//host/x`）一律拒绝，保证下载目标主机恒等于
    /// `baseUrl` 主机（index 可被替换，多一个主机跳转即多一个可观测元数据的面）；
    /// `baseUrl` 必须 https（ATS 默认之外的双保险）。违规返回 nil 走 badAddress fail-closed。
    /// baseUrl 无尾斜杠时按 RFC 3986 会吞掉末段路径——先补斜杠再拼接，
    /// 保证 `…/asr-models` + `x.zip` ⇒ `…/asr-models/x.zip` 而非 `…/x.zip`。
    public func resolvedURL(baseURL: URL?) -> URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == url, !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed.hasSuffix(".zip"), ModelResourcePolicy.isSlug(String(trimmed.dropLast(4))),
              URL(string: trimmed)?.scheme == nil,
              !trimmed.hasPrefix("//") else { return nil }
        guard let baseURL, let scheme = baseURL.scheme?.lowercased(), scheme == "https" else { return nil }
        var base = baseURL
        if !base.path.hasSuffix("/") { base = base.appendingPathComponent("") }
        let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL
        guard resolved?.scheme?.lowercased() == "https", resolved?.host == base.host else { return nil }
        return resolved
    }

    /// 该条目是否比 `installedVersion` 新（installed 为 nil 时恒 true）。
    public func isNewer(than installedVersion: String?) -> Bool {
        ASRVersion.isNewer(version, than: installedVersion)
    }

    /// 是否需要安装/更新所选档位（BR 规则，2026-09-19 审查修复自视图上移——
    /// CLAUDE.md 规则 4：业务判定不得留在 View 内）。四条析取：
    /// ① 未装过（无已激活指针版本）；② 已装版本更旧；③ 同版本换档
    /// （small→large 等——只比版本号的旧判定让尺寸选择形同虚设）；
    /// ④ 同版本同档位但 artifactRevision 更高（修订重发布——2026-10-05
    /// 审查修正：此前多档家族的修订重发布在行内无任何入口，而「检查更新」
    /// 徽标会计为可更新，横幅与行内入口不对称）。
    public func needsInstall(installedVersion: String?, installedVariant: String?,
                             installedRevision: Int? = nil) -> Bool {
        guard let installedVersion else { return true }
        if isNewer(than: installedVersion) { return true }
        if version == installedVersion, variant != nil, variant != installedVariant { return true }
        if version == installedVersion, variant == installedVariant,
           let installedRevision, (artifactRevision ?? 0) > installedRevision { return true }
        return false
    }
}

/// 版本比较（模型版本是「上游语义版本 + 日期」混合形态，如 `0.6b-int8-v2026.03.25`）。
///
/// 规则：按非字母数字切段，逐段比较；两段均为纯数字时按整数比（`03` == `3`，
/// `20260912` > `20260325`），否则先按段首连续数字前缀比较（`6b` < `10`、
/// `9` < `10a`），其余按忽略大小写的自然顺序比较（段内连续数字按数值，`v9` < `v10`）；
/// 已比较的各段相同时段数多者为新。
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

    /// 单段比较：纯数字按整数；混合段先比数字前缀，其余按含数字的自然顺序。
    private static func compareSegment(_ a: String, _ b: String) -> ComparisonResult {
        if let ai = Int(a), let bi = Int(b) {
            if ai == bi { return .orderedSame }
            return ai > bi ? .orderedDescending : .orderedAscending
        }
        let an = leadingDigits(a), bn = leadingDigits(b)
        if let an, let bn, an != bn {
            return an > bn ? .orderedDescending : .orderedAscending
        }
        return a.lowercased().compare(b.lowercased(), options: .numeric)
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

/// 业主裁决 D6：设备 RAM 档位建议（纯函数，BR 规则在 Domain——视图只做格式化）。
/// 建议语义：≥6GB 取最大档（清单须按 `ASRModelRelease.variantWeight` 升序）、
/// ≥4GB 取中档、其余取最小档。清单 ≤1 档或全部无 variant 时返回 nil（不显示建议）。
/// 用户自行决定（不硬限制），RAM 判断只做提示。
public enum ASRVariantRecommendation {
    public static func variantIndex(ramBytes: UInt64, variantCount: Int) -> Int? {
        guard variantCount > 1 else { return nil }
        let ramGB = ramBytes / 1024 / 1024 / 1024
        if ramGB >= 6 { return variantCount - 1 }   // 最大档（升序清单末位）
        if ramGB >= 4 { return variantCount / 2 }   // 中档
        return 0                                    // 最小档
    }

    /// 系统推荐档下标（2026-10-05 业主反馈修复批「系统推荐可用模型尺寸」）：
    /// ① 内存探针可用 → 预算内可载的**最大档**（`ModelMemoryBudget.largestLoadableIndex`，
    ///    与 auto 档「完整解码模型优先」同语义；全不足 → 回落 ②）；
    /// ② 探针不可用/全不足 → RAM 档位建议（D6，只提示不拦截的既有口径——
    ///    探针不可用时**不得**按预算 fail-open 推最大档：未知内存推大档有风险，
    ///    建议与拒绝的 fail-open 语义不同）；
    /// ③ 均无 → 最小档（0）。输入 `expandedBytes` 须与档位顺序一致（升序清单）；
    /// 未知体积传 `Int64.max`（预算判定为不可载、不误推荐）。
    public static func recommendedIndex(expandedBytes: [Int64], availableBytes: Int64?,
                                        ramBytes: UInt64) -> Int {
        if let available = availableBytes,
           let byBudget = ModelMemoryBudget.largestLoadableIndex(modelBytes: expandedBytes,
                                                                 availableBytes: available) {
            return byBudget
        }
        return variantIndex(ramBytes: ramBytes, variantCount: expandedBytes.count) ?? 0
    }
}
