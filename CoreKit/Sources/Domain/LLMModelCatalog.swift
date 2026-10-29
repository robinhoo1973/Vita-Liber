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
///
/// v3（2026-10-29 MiniCPM5 选型批，K-2026-10-29-01 §2.5）：新增 per-entry
/// `kvBytesPerToken` / `stopTokens` / `addBosToken`；**显式 frame 未知值拒收该条目**
/// （v2 的「未知即回落 chatML」= 用错帧渲染 = 训推异分布，v3 起 fail-closed；
/// 缺省无键仍按旧契约取 chatML）。formatVersion 2 与 3 均可解析——随包目录是本仓
/// 受控文件，无外部运行时旧版兼容面。
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
        /// v3：KV 单 token 字节数（F16 口径）。nil = 未钉，消费侧回落保守默认
        /// `LLMContextBudget.qwen3KVBytesPerToken`（宁可高估、不放过 jetsam 配置）。
        public let kvBytesPerToken: Int64?
        /// v3：EOS/EOG 之外的显式停止 token（如 MiniCPM5 的 `<|im_end|>` = 130073——
        /// llama.cpp 转换链是否把它标成 EOG 不由本仓决定，目录兜底）。
        public let stopTokens: [Int32]
        /// v3：tokenize 后是否显式前置 BOS（MiniCPM4 类词表 true；MiniCPM5/Qwen 系 false）。
        public let addBosToken: Bool

        public init(id: String, role: Role, fileName: String, bytes: Int64, sha256: String,
                    url: URL, version: String, license: String,
                    frame: ExtractionPromptBuilder.ChatFrameStyle = .chatML,
                    kvBytesPerToken: Int64? = nil, stopTokens: [Int32] = [],
                    addBosToken: Bool = false) {
            self.id = id
            self.role = role
            self.fileName = fileName
            self.bytes = bytes
            self.sha256 = sha256
            self.url = url
            self.version = version
            self.license = license
            self.frame = frame
            self.kvBytesPerToken = kvBytesPerToken
            self.stopTokens = stopTokens
            self.addBosToken = addBosToken
        }
    }

    /// 目录文档（`formatVersion` 2/3）。
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
    /// - 根非对象 / `formatVersion` 非整数 2 或 3 / `models` 非数组 /
    ///   `preference` 缺失或非字符串数组 → nil（整体拒）。
    /// - 条目级任一字段类型非法（含 bool/非整值浮点冒充数字、frame/addBosToken/
    ///   stopTokens 类型不符）→ 跳过该条（不半信）。类型严格性由 `JSONDecoder`
    ///   承担（Bool→Int、1.5→Int、String→Int 均拒），与 L0 [20] 门禁
    ///   `isinstance(int) and not isinstance(bool)` 同口径。
    /// - `preference` 任一 id 悬空 → 整体判 nil（宁可拒绝，不可静默错选）。
    ///   **与条目级跳过的优先级**：被跳过的条目若出现在 `preference` 里，其 id 即悬空
    ///   → 整份目录 nil（优先条目非法 = 构建期必须拦住，绝不下发「假装可用」的降级）。
    ///   非优先条目非法则只丢该条。L0 [20] 门禁按同一规则做发货前阻断。
    /// - 去重：同 id 重复（后者）覆盖前者可静默错选 → 直接剔除重复 id 的全部后验条目，
    ///   保留首个（确定性优先）。
    public static func parse(_ data: Data) -> Document? {
        guard let raw = try? JSONDecoder().decode(RawDocument.self, from: data),   // try?-ok: 根结构/优先序非法即整体拒
              (2...3).contains(raw.formatVersion) else { return nil }
        var seen = Set<String>()
        var entries: [Entry] = []
        for box in raw.models {
            guard let model = box.value,
                  let entry = makeEntry(model), seen.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }
        // 悬空引用 → 整体拒（静默错选比拒绝更糟）。
        let ids = Set(entries.map(\.id))
        guard raw.preference.allSatisfy({ ids.contains($0) }) else { return nil }
        return Document(entries: entries, preference: raw.preference)
    }

    /// 根结构（严格类型：任何一项类型不符 → 整份目录 nil）。
    private struct RawDocument: Decodable {
        let formatVersion: Int
        let models: [FailableDecodable<RawEntry>]
        let preference: [String]
    }

    /// 条目级失败隔离：单条解不出 = 丢该条（v2 起的「不半信」契约），不拖垮整份目录。
    private struct FailableDecodable<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) {
            value = try? Value(from: decoder)   // try?-ok: 条目级字段类型非法 → 只丢该条（fail-closed 跳过而非整体拒）
        }
    }

    /// 条目原始形状（全部尺寸/数量字段用定宽整数解码——Bool/浮点非法值在此被 Foundation 拒）。
    private struct RawEntry: Decodable {
        let id: String
        let role: String
        let fileName: String
        let bytes: Int64
        let sha256: String
        let url: String
        let version: String
        let license: String
        let frame: String?
        let kvBytesPerToken: Int64?
        let stopTokens: [Int32]?
        let addBosToken: Bool?
    }

    /// 条目级解析（任一字段不合法返回 nil——调用方跳过）。
    private static func makeEntry(_ model: RawEntry) -> Entry? {
        guard ModelResourcePolicy.isSlug(model.id),
              let role = Role(rawValue: model.role),
              model.fileName.hasSuffix(".gguf"), ModelResourcePolicy.isSlug(model.fileName),
              model.bytes > 0,
              ModelResourcePolicy.isSHA256(model.sha256),
              let url = URL(string: model.url), ModelResourcePolicy.allowedURL(url),
              ModelResourcePolicy.isSlug(model.version),
              !model.license.isEmpty else { return nil }
        let frame: ExtractionPromptBuilder.ChatFrameStyle
        if let rawFrame = model.frame {
            // v3 fail-closed：显式 frame 未知值 = 用错帧渲染 = 训推异分布，拒收该条目
            // （绝不静默回落 chatML——那正是 v2 的种子缺陷）。
            guard let parsed = ExtractionPromptBuilder.ChatFrameStyle(rawValue: rawFrame) else { return nil }
            frame = parsed
        } else {
            frame = .chatML   // 无键 = 旧契约缺省（v1/v2 兼容面）
        }
        if let kv = model.kvBytesPerToken, kv <= 0 { return nil }
        let stopTokens = model.stopTokens ?? []
        guard !stopTokens.contains(where: { $0 <= 0 }) else { return nil }
        return Entry(id: model.id, role: role, fileName: model.fileName, bytes: model.bytes,
                     sha256: model.sha256, url: url, version: model.version, license: model.license,
                     frame: frame, kvBytesPerToken: model.kvBytesPerToken,
                     stopTokens: stopTokens, addBosToken: model.addBosToken ?? false)
    }
}
