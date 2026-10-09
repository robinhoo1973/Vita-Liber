import Foundation

/// 本机 LLM（T2）模型目录契约 v2（2026-10-09 换型+下载化批）：
/// 模型文件**不再随包**——目录"随签名二进制发布"充当**唯一信任锚**
/// （URL + sha256 + bytes 三者构建期钉死；网络只做字节运输，无授权输入——
/// 与 ADR-030「网络目录不能自己建立信任」同构：本目录不信任任何网络目录）。
///
/// 与 v1 的差异（schema 迁移由 build 期目录文件一次性完成，无运行时兼容面——
/// v1 目录从未发布过下载面，App 侧解析器同批重写）：
///   1. **无 `bundled` 字段**：单一来源=下载安装位；Bundle 查询分支整体删除
///      （2026-09-20 回滚根因「随包与下载并存」从结构上不可再发生）。
///   2. 新增 `role`（default/medical，消费侧按 role 取用、id 只表达"是哪条"）、
///      `frame`（ChatML 帧风格：Qwen3 非思考渲染需保留空 think 段，见
///      `ExtractionPromptBuilder.ChatFrameStyle`）、`version`、`url`、`license`。
///   3. `preference` 显式化解析优先序（替代"取第一条"的隐式约定）。
///
/// 解析 fail-closed：任一条目字段非法**跳过该条目**（绝不半信）；根结构非法返回
/// nil。孤条目导致的空目录 = 消费侧「未配置」——绝不假装可用（与既有缺席回落
/// 语义同族）。
public enum LLMModelCatalog {

    /// 条目的消费角色（单值；装配点按 `preference` 顺序取首个就绪者）。
    public enum Role: String, Sendable {
        /// 通用本机 LLM（抽取；换型主位）。
        case general = "default"
        /// 医疗小模型（minimind-medical 谱系回滚/共存位）。
        case medical
    }

    /// 单条目（全部字段均为构建期钉死值）。
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let role: Role
        public let fileName: String
        public let bytes: Int64
        public let sha256: String
        /// 发布面直链（https，主机白名单见 `ModelResourcePolicy.allowedURL`）。
        public let url: URL
        public let version: String
        public let license: String
        public let frame: ExtractionPromptBuilder.ChatFrameStyle

        public init(id: String, role: Role, fileName: String, bytes: Int64, sha256: String,
                    url: URL, version: String, license: String,
                    frame: ExtractionPromptBuilder.ChatFrameStyle = .chatML) {
            self.id = id
            self.role = role
            self.fileName = fileName
            self.bytes = bytes
            self.sha256 = sha256
            self.url = url
            self.version = version
            self.license = license
            self.frame = frame
        }
    }

    /// 目录文档（`formatVersion == 2`）。
    public struct Document: Sendable, Equatable {
        public let entries: [Entry]
        /// 解析优先序（每个 id 必须存在于 entries；引用悬空即整体判非法——
        /// 优先序指向不存在条目 = 静默选错模型的种子，宁可拒绝）。
        public let preference: [String]

        public init(entries: [Entry], preference: [String]) {
            self.entries = entries
            self.preference = preference
        }

        /// 按优先序遍历的条目序列（preference 未覆盖的条目按文件序补尾——
        /// 兼容"只新增条目忘了改 preference"的误操作：新条目仍可被显式 id 寻址）。
        public var preferred: [Entry] {
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            let head = preference.compactMap { byID[$0] }
            let tail = entries.filter { !preference.contains($0.id) }
            return head + tail
        }

        public func entry(id: String) -> Entry? {
            entries.first { $0.id == id }
        }
    }

    /// 解析（纯函数）。契约：
    /// - 根非对象 / `formatVersion != 2` / `models` 非数组 → nil（整体拒）。
    /// - 条目级任一字段非法 → 跳过该条（不半信）。
    /// - `preference` 任一 id 悬空 → 整体判 nil（宁可拒绝，不可静默错选）。
    /// - 去重：同 id 重复（后者）覆盖前者可静默错选 → 直接剔除重复 id 的全部后验条目，
    ///   保留首个（确定性优先）。
    public static func parse(_ data: Data) -> Document? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],   // try?-ok: 非法 JSON 即整体拒
              (root["formatVersion"] as? Int) == 2,
              let models = root["models"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var entries: [Entry] = []
        for model in models {
            guard let entry = parseEntry(model), seen.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }
        let preference = (root["preference"] as? [String]) ?? []
        // 悬空引用 → 整体拒（静默错选比拒绝更糟）。
        let ids = Set(entries.map(\.id))
        guard preference.allSatisfy({ ids.contains($0) }) else { return nil }
        return Document(entries: entries, preference: preference)
    }

    /// 条目级解析（任一字段不合法返回 nil——调用方跳过）。
    static func parseEntry(_ model: [String: Any]) -> Entry? {
        guard let id = model["id"] as? String, ModelResourcePolicy.isSlug(id),
              let roleRaw = model["role"] as? String, let role = Role(rawValue: roleRaw),
              let fileName = model["fileName"] as? String,
              fileName.hasSuffix(".gguf"), ModelResourcePolicy.isSlug(fileName),
              let bytes = (model["bytes"] as? NSNumber)?.int64Value, bytes > 0,
              let sha256 = model["sha256"] as? String, ModelResourcePolicy.isSHA256(sha256),
              let urlRaw = model["url"] as? String, let url = URL(string: urlRaw),
              ModelResourcePolicy.allowedURL(url),
              let version = model["version"] as? String, ModelResourcePolicy.isSlug(version),
              let license = model["license"] as? String, !license.isEmpty else { return nil }
        let frame = (model["frame"] as? String)
            .flatMap(ExtractionPromptBuilder.ChatFrameStyle.init(rawValue:)) ?? .chatML
        return Entry(id: id, role: role, fileName: fileName, bytes: bytes, sha256: sha256,
                     url: url, version: version, license: license, frame: frame)
    }
}
