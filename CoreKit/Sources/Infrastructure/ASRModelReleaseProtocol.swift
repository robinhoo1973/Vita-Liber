import Foundation

/// ASR Release 线协议常量与资产名文法(2026-10-03 cutover 定案)。
/// 逐项对齐 `scripts/release/model_trust.py` 与 `publish-asr-release.py`,
/// 任何一侧改动须同步另一侧。
public enum ASRModelReleaseProtocol {
    public static let repository = "robinhoo1973/Resources"
    public static let releaseTag = "asr-models"
    /// CNB 资源下载基址(与发布侧 baseUrl 断言逐字节一致)。
    public static let releaseBaseURL = "https://cnb.cool/" + repository + "/-/releases/download/" + releaseTag
    /// 基址主机(cnb.cool)+ 传输主机(asset.cnb.cool)。附件重定向链的最终宿主
    /// 集以探针为准(设计文档 §8:未实证前不猜测主机);扩列需随 App 发版。
    public static let allowedHosts: Set<String> = ["cnb.cool", "asset.cnb.cool"]
    /// GitHub 旧基址(旧内测包冻结面):新 App 根校验仍接受两个已知基址
    /// 精确匹配之一,使在途 GitHub 域根与 CNB 域根轮换共享同一套验证。
    public static let legacyGitHubBaseURL = "https://github.com/robinhoo1973/Vita-Liber/releases/download/asr-models"
    /// tag 页:目录发现的唯一面;目录资产为固定名 index.json(2026-10-06 业主
    /// 单一 JSON 架构:TUF fixed-name 形态,单调版本在签名载荷 catalogVersion,
    /// 回滚防护由客户端持久化守卫承担;不再有版本化副本)。
    public static var tagPageURL: URL {
        URL(string: "https://cnb.cool/" + repository + "/-/releases/tag/" + releaseTag)!
    }

    /// 固定名数据文件:index.json(签名信封)——CNB 唯一目录资产与 App 唯一下载面。
    public static let catalogAssetFixedName = "index.json"

    /// 历史版本化目录/根资产名文法(N.catalog.json / N.root.json,旧 CNB 面
    /// 判读兼容用;新架构不再产生这些资产)。
    public static func catalogAssetName(version: Int) -> String { String(version) + ".catalog.json" }
    public static func rootAssetName(version: Int) -> String { String(version) + ".root.json" }

    static func parseVersionedAssetName(_ name: String, suffix: String) -> Int? {
        guard name.hasSuffix(suffix) else { return nil }
        let body = name.dropLast(suffix.count)
        guard (1...19).contains(body.count), body.first != "0", body.allSatisfy(\.isNumber),
              let version = Int(body), version > 0 else { return nil }
        return version
    }

    public static func catalogVersion(fromAssetName name: String) -> Int? {
        parseVersionedAssetName(name, suffix: ".catalog.json")
    }
    public static func rootVersion(fromAssetName name: String) -> Int? {
        parseVersionedAssetName(name, suffix: ".root.json")
    }

    /// 下载与每一跳 redirect 的地址门(与医疗线同强度):HTTPS、固定 Release 主机、
    /// 无凭据、默认端口。
    public static func allowsTransferURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }
}
