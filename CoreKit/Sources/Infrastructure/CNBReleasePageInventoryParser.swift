import Foundation

/// CNB tag 页 `__NEXT_DATA__` 资产清单条目——仅作候选定位,不是信任源
/// (设计文档 §3.1:页面只提供 inventory,授权仍由签名根/目录完成)。
public struct CNBInventoryAsset: Equatable, Sendable {
    public let name: String
    public let path: String
    public let hashAlgo: String
    public let hashValue: String
    public let sizeInByte: Int
}

/// CNB Release tag 页 SSR 清单的有界 fail-closed 解析(设计文档 §3.1/§7.1)。
///
/// 纯 Foundation、无平台守卫:Linux 可跑 sanitized fixture 回归(规避平台守卫
/// 空编译单元型检盲区教训)。任何 HTML/SSR 形状漂移一律抛错,由调用方归约
/// 为「检查不可用」并保留 last-good 本地目录;绝不猜测部分解析。
public enum CNBReleasePageInventoryParser {
    public static let maxPageBytes = 8 << 20
    public static let maxAssets = 512

    public struct DecodeFailure: Error, Equatable, Sendable {
        public let reason: String
    }

    public static func assets(fromPage html: Data, repository: String, tag: String) throws -> [CNBInventoryAsset] {
        guard html.count <= maxPageBytes else { throw DecodeFailure(reason: "page exceeds size bound") }
        guard let text = String(data: html, encoding: .utf8) else { throw DecodeFailure(reason: "page is not UTF-8") }
        // 只提取 <script id="__NEXT_DATA__">…</script>,不执行脚本;提取不到即拒。
        let pattern = #"<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>"#
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        } catch {
            throw DecodeFailure(reason: "page script pattern invalid")
        }
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let scriptRange = Range(match.range(at: 1), in: text) else {
            throw DecodeFailure(reason: "page has no __NEXT_DATA__ payload")
        }
        let payload = String(text[scriptRange])
        guard let data = payload.data(using: .utf8) else {
            throw DecodeFailure(reason: "__NEXT_DATA__ payload is not UTF-8")
        }
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DecodeFailure(reason: "__NEXT_DATA__ is not JSON")
        }
        guard let root = jsonObject as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            throw DecodeFailure(reason: "__NEXT_DATA__ is not a JSON object")
        }
        // 实测(2026-10-05 探针):Release 未创建时 releaseDetailStatus="pending"
        // 且 releasesDetailData=null——非 success 一律 fail-closed。
        guard pageProps["releaseDetailStatus"] as? String == "success" else {
            throw DecodeFailure(reason: "release state is not success")
        }
        guard let releaseData = pageProps["releasesDetailData"] as? [String: Any],
              let release = releaseData["release"] as? [String: Any],
              release["tagRef"] as? String == "refs/tags/" + tag else {
            throw DecodeFailure(reason: "release/tagRef mismatch")
        }
        guard let assets = release["assets"] as? [[String: Any]],
              !assets.isEmpty, assets.count <= maxAssets else {
            throw DecodeFailure(reason: "assets are missing or unbounded")
        }
        var parsed: [CNBInventoryAsset] = []
        var seen = Set<String>()
        for asset in assets {
            guard let name = asset["name"] as? String, !name.isEmpty, seen.insert(name).inserted else {
                throw DecodeFailure(reason: "asset name is missing or duplicated")
            }
            let expectedPath = "/" + repository + "/-/releases/download/" + tag + "/" + name
            guard asset["path"] as? String == expectedPath else {
                throw DecodeFailure(reason: "asset path is out of scope: " + name)
            }
            guard asset["hashAlgo"] as? String == "sha256",
                  let digest = asset["hashValue"] as? String,
                  digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let size = asset["sizeInByte"] as? Int, size > 0 else {
                throw DecodeFailure(reason: "asset metadata is incomplete: " + name)
            }
            parsed.append(CNBInventoryAsset(name: name, path: expectedPath,
                                            hashAlgo: "sha256", hashValue: digest, sizeInByte: size))
        }
        return parsed
    }
}
