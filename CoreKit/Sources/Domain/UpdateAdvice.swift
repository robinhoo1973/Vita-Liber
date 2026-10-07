import Foundation

/// CNB README 索引载荷（VL-INDEX v1 二维码）的**通告面**模型 —— 纯 Foundation，
/// Linux 可编译可测。
///
/// 委员会裁决（2026-10-07，P3 设计）：载荷是「发布方搬运的提示索引」，**非信任源**
/// （对称密钥公开，任何人可重新生成自洽载荷）。呈现规则 R2.1–R2.9 在此固化为类型：
/// 不存在「已最新」态；「未提及」独立态；载荷态永不改变交互可用性；固定「未校验」
/// 标注；不产数量结论；域链（签名目录/信任根）结论永远覆盖通告呈现。
public enum UpdateAdviceDomain: String, CaseIterable, Sendable {
    case asrModels = "asr-models"
    case medicalData = "medical-data"
}

/// 单域通告行态（封闭集，R2.1）——**没有 upToDate**：任何载荷态都不得映射为
/// 「已是最新」（那只能由已完成的域链检查产出，R2.2）。
public enum UpdateAdviceRowState: Sendable, Equatable {
    /// 载荷提及该域（正向通告；是否真有新版一律以域链为准，R2.2/R2.5）。
    case announced
    /// 载荷未提及该域（含域条目缺失，R2.3/R2.9）——显式文案，不与「无更新」共用。
    case notMentioned
    /// 载荷版本低于本机 floor，或 generatedAt 陈旧（R2.4；仅展示标注，不产结论）。
    case stale
    /// 载荷不可用/畸形/同版异文（R2.4）——一切失败归此，不细分、不暗示域链结论。
    case unavailable
}

/// 载荷契约常量（与 CNB 仓 `tools/readme-sync` 模块逐字节对齐；App 只消费）。
public enum UpdateAdvicePayloadContract {
    /// 二维码内容 = identity 前缀（ASCII 79B：`update-payload-<64hex>`）+ 信封字节。
    public static let identityPrefixLength = 79
    public static let schemaVersion = 1
    /// 载荷信封字节上限（readme-sync 提取契约 256 KiB）。
    public static let maxEnvelopeBytes = 256 * 1024
    /// PNG 取件上界（现件 ~4.4KB；64KiB 留足余量，超限即中止）。
    public static let maxPNGBytes = 64 * 1024
    /// 固定读取通道（匿名，`/git/raw`；与 README 页 `<img>` 渲染同源）。
    public static let pngURL = URL(string:
        "https://cnb.cool/robinhoo1973/Resources/-/git/raw/main/tools/readme-sync/vl-index.png")!

    /// 79 字节前缀是否为合法 identity（唯一文法出口；手写 hex 校验——不用正则/强制 try）。
    public static func isValidIdentity(_ value: String) -> Bool {
        let prefix = "update-payload-"
        guard value.hasPrefix(prefix) else { return false }
        let hex = value.dropFirst(prefix.count)
        return hex.utf8.count == 64
            && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// 从 79 字节 ASCII 前缀解码 identity；非 ASCII/文法不符 = nil（fail-closed）。
    public static func identity(fromPrefix prefix: Data) -> String? {
        guard prefix.count == identityPrefixLength,
              let value = String(data: prefix, encoding: .ascii),
              isValidIdentity(value) else { return nil }
        return value
    }
}

/// 载荷 JSON（只声明 App 所需字段；未知字段被 Codable 忽略——服务端演进宽容）。
public struct UpdateAdvicePayload: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let size: Int
        public let sha256: String
    }

    public struct Release: Codable, Sendable, Equatable {
        public let tag: String
        public let latest: [Entry]
    }

    public let schemaVersion: Int
    public let payloadVersion: Int
    public let generatedAt: String
    public let releases: [Release]

    public init(schemaVersion: Int, payloadVersion: Int, generatedAt: String, releases: [Release]) {
        self.schemaVersion = schemaVersion
        self.payloadVersion = payloadVersion
        self.generatedAt = generatedAt
        self.releases = releases
    }
}

/// floor 决策（纯函数，Linux 可测；R2.4 的判定语义与医疗 TrustStore 同构）。
public enum UpdateAdviceFloorRules {
    /// 给定载荷观测与本机 floor，判定基线态（nil = 进入 announced/notMentioned 分流）。
    ///
    /// - 观测版本 < floor：`stale`（回退/重放；仅标注，不拒展示其他信息）。
    /// - 同版本异 identity：`unavailable`（equivocation，同版异文语义）。
    /// - 其余：nil（由提及与否分流）。
    public static func baselineState(observedVersion: Int, observedIdentity: String,
                                     floorVersion: Int?, floorIdentity: String?) -> UpdateAdviceRowState? {
        guard let floorVersion else { return nil }
        if observedVersion < floorVersion { return .stale }
        if observedVersion == floorVersion, let floorIdentity, floorIdentity != observedIdentity {
            return .unavailable
        }
        return nil
    }
}
