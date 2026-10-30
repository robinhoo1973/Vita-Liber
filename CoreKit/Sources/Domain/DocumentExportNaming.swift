import Foundation

/// 文档导出副本命名（2026-10-27 存储边界委员会两轮裁决 D4/E3）。
///
/// 设计约束：
/// - **确定性模板，禁用生成式模型**（离线可用、可测试；本机模型未装即不可用，
///   且 LLM 触 BR-006 措辞红线）。
/// - 命名素材只取**已确认（C 级）字段**——D 级机器识别值不得进入文件名（BR-003）。
/// - 与 `DocumentNaming` 同族：类型名经 `DocumentNaming.Labels` 注入，Domain 不持
///   用户可见文案。区别：`DocumentNaming.suggestTitle` 产出**展示标题**
///   （日期·机构·类型），本类型产出**磁盘文件名**（卡类型-已确认首值-日期），
///   并负责净化/截断/去重——镜像副本命名专用。
/// - 纯函数、零框架依赖（Foundation 除外）——Linux 可跑金样。
public enum DocumentExportNaming {
    /// 名称来源（v49 `document_user_export.name_source` 同值域）。
    public enum NameSource: String, Sendable, Equatable, Codable {
        case auto       // 确认标题或确定性模板
        case user       // 用户显式改名（此后锁定，不再自动改名）
        case fallback   // 无可用素材：类型-日期-短ID
    }

    public struct Request: Sendable {
        /// `document_file.title`（确认后由 DocumentNaming 生成，或用户改名）。
        public var preferredTitle: String?
        /// 标题来源；nil = 按 auto 处理。用户改名请传 .user。
        public var preferredTitleSource: NameSource?
        /// 已确认字段（调用方须先过滤 `isConfirmed`；本类型不再复核 grade）。
        public var fields: [FieldDraft]
        /// 卡类型/文档类型键（MatchedCard.kind / doc_type_key）。
        public var cardKind: String?
        /// 规范日期文本（yyyy-MM-dd，调用方按设备时区给出）；字段内日期优先。
        public var dayText: String?
        public var documentID: UUID
        /// 文件扩展名（不含点；调用方按 MIME 白名单映射，未知传 nil）。
        public var fileExtension: String?

        public init(preferredTitle: String? = nil,
                    preferredTitleSource: NameSource? = nil,
                    fields: [FieldDraft] = [],
                    cardKind: String? = nil,
                    dayText: String? = nil,
                    documentID: UUID,
                    fileExtension: String? = nil) {
            self.preferredTitle = preferredTitle
            self.preferredTitleSource = preferredTitleSource
            self.fields = fields
            self.cardKind = cardKind
            self.dayText = dayText
            self.documentID = documentID
            self.fileExtension = fileExtension
        }
    }

    public struct Name: Sendable, Equatable {
        /// 含扩展名的完整文件名。
        public var fileName: String
        /// 不含扩展名的词干（去重比较单位）。
        public var stem: String
        public var source: NameSource
    }

    /// 组件 UTF-8 字节上限（E3/I4：≤240B；留 15B 余量给扩展名与去重后缀）。
    public static let maxComponentBytes = 240

    /// 确定性回落类型名（三语由调用方经 Labels 注入；此处仅在完全无素材时兜底）。
    static let fallbackType = "文档"

    /// 不参与「首值」取材的元数据键（与 OCRCardStore 确认投影的过滤口径一致）。
    static let excludedKeys: Set<String> = ["metric_key"]

    // MARK: - 主入口

    public static func name(_ request: Request,
                            labels: DocumentNaming.Labels = .builtin) -> Name {
        let title = request.preferredTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            let stem = sanitizeComponent(title)
            if !stem.isEmpty {
                return finish(stem: stem,
                              source: request.preferredTitleSource ?? .auto,
                              ext: request.fileExtension)
            }
        }

        let dictionary = fieldDictionary(request.fields)
        let date = dictionary["report_date"] ?? dictionary["prescribed_at"]
            ?? dictionary["measured_at"] ?? dictionary["date"]
            ?? dictionary["administered_at"] ?? request.dayText
        let typeName: String? = {
            guard let kind = request.cardKind else { return nil }
            if let docTypeName = labels.forDocType(kind) { return docTypeName }
            let kindName = labels.forKind(kind)
            return kindName.isEmpty ? nil : kindName
        }()
        let firstValue = request.fields
            .first { $0.isConfirmed
                && !excludedKeys.contains($0.key)
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .value.trimmingCharacters(in: .whitespacesAndNewlines)

        // E3 裁决：有已确认首值 → 「卡类型-首值-日期」；无首值 → 回落
        // 「类型-日期-短ID」（短 ID 保证无值场景的可辨识与唯一）。
        if let firstValue, !firstValue.isEmpty {
            var parts: [String] = []
            if let typeName, !typeName.isEmpty { parts.append(typeName) }
            parts.append(firstValue)
            if let date, !date.isEmpty { parts.append(date) }
            let stem = sanitizeComponent(parts.joined(separator: "-"))
            if !stem.isEmpty {
                return finish(stem: stem, source: .auto, ext: request.fileExtension)
            }
        }
        return finish(stem: fallbackStem(request: request, typeName: typeName, date: date),
                      source: .fallback, ext: request.fileExtension)
    }

    /// 会话目录名：可选日期时间前缀 + 净化标题（空 → 未命名会话）+ 会话短 ID 消歧。
    /// 目录名在首次镜像时冻结（D5）——调用方负责持久化，本函数保持确定性。
    /// 业主 2026-10-30：AI 聊天会话目录须带日期时间前缀，便于在「文件」App 中
    /// 按时间排序；`datePrefix` 由调用方按设备时区给出（如 `20261030-1435`）。
    public static func directoryName(conversationTitle: String?,
                                     conversationID: UUID,
                                     datePrefix: String? = nil,
                                     taken: Set<String> = []) -> String {
        let title = conversationTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = title.isEmpty ? "未命名会话" : title
        let stem = sanitizeComponent(base)
        let resolved = stem.isEmpty ? "未命名会话" : stem
        let id6 = String(conversationID.uuidString.lowercased().prefix(6))
        let prefix = datePrefix.map { sanitizeComponent($0) } ?? ""
        let prefixed = prefix.isEmpty ? resolved : "\(prefix)-\(resolved)"
        var candidate = sanitizeComponent("\(prefixed)-\(id6)")
        if candidate.isEmpty { candidate = id6 }
        var attempt = 2
        while taken.contains(normalizeKey(candidate)) {
            candidate = sanitizeComponent("\(prefixed)-\(id6)-\(attempt)")
            attempt += 1
        }
        return candidate
    }

    /// 同目录重名消解：`base`、`base-2`、`base-3`…（大小写/规范化不敏感）。
    public static func deduplicatedStem(_ base: String, existing: Set<String>) -> String {
        let normalized = Set(existing.map(normalizeKey))
        guard normalized.contains(normalizeKey(base)) else { return base }
        var attempt = 2
        while true {
            let candidate = sanitizeComponent("\(base)-\(attempt)")
            if !normalized.contains(normalizeKey(candidate)) { return candidate }
            attempt += 1
        }
    }

    /// 去重比较键：precomposed + 小写（I4：碰撞键幂等/确定性）。
    public static func normalizeKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// 非聊天入口（资料库直接导入）的归档目录：`直接导入-<YYYY-MM>`。
    /// 目录名属磁盘身份而非 UI 文案——放 Domain 保持确定性（L10n 单出口只
    /// 约束视图层字面量；此处不随界面语言漂移，避免同一文档换语言换目录）。
    public static func directImportDirectory(monthText: String) -> String {
        let stem = sanitizeComponent("\(directImportPrefix)-\(monthText)")
        if !stem.isEmpty { return stem }
        return sanitizeComponent(monthText)
    }

    static let directImportPrefix = "直接导入"

    // MARK: - 净化（E3 采纳 I4 不变量）

    /// 净化一个路径组件：NFKC → 白名单（字母数字 + `-_.()·` + 空格）→
    /// 拒 `/\:` 与 NUL/控制符/格式符（含 U+202A–202E、U+2066–2069 双向覆盖）→
    /// 去首尾点/空格 → 非 `.`/`..` → Windows 保留名前缀 `_` →
    /// ≤240 UTF-8 字节（超限按字符截断 + `-<8 hex>` 稳定哈希）。
    /// 空输入/全被清洗 → 返回空串（调用方回落）。幂等。
    public static func sanitizeComponent(_ raw: String,
                                         maxUTF8Bytes: Int = maxComponentBytes) -> String {
        let folded = raw.precomposedStringWithCompatibilityMapping
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator,
                 .surrogate, .privateUse, .unassigned:
                continue
            default:
                break
            }
            if scalar == "/" || scalar == "\\" || scalar == ":" {
                scalars.append("-")   // 路径分隔符归一为连字符
            } else if properties.isAlphabetic
                        || properties.generalCategory == .decimalNumber
                        || properties.generalCategory == .letterNumber
                        || properties.generalCategory == .otherNumber
                        || allowedPunctuation.contains(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append("-")   // 非白名单符号归一为连字符（绝不透传）
            }
        }
        var value = String(String.UnicodeScalarView(scalars))
        while value.contains("--") {
            value = value.replacingOccurrences(of: "--", with: "-")
        }
        value = collapseWhitespace(value)
        value = trimEdgeCharacters(value)
        if value.isEmpty { return "" }
        if value == "." || value == ".." { return "" }
        if reservedNames.contains(value.uppercased()) {
            value = "_" + value
        }
        if value.utf8.count > maxUTF8Bytes {
            value = truncate(value, maxUTF8Bytes: maxUTF8Bytes) + "-" + shortHash(raw)
        }
        return value
    }

    // MARK: - 内部

    private static let allowedPunctuation: Set<Unicode.Scalar> = [
        "-", "_", ".", "(", ")", "·", " ",
    ]

    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    private static func fieldDictionary(_ fields: [FieldDraft]) -> [String: String] {
        Dictionary(
            fields
                .filter(\.isConfirmed)
                .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ($0.key, $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) },
            uniquingKeysWith: { first, _ in first })
    }

    private static func fallbackStem(request: Request, typeName: String?,
                                     date: String?) -> String {
        var parts: [String] = [typeName ?? fallbackType]
        if let date, !date.isEmpty {
            parts.append(date)
        } else if let day = request.dayText, !day.isEmpty {
            parts.append(day)
        }
        parts.append(String(request.documentID.uuidString.lowercased().prefix(8)))
        let stem = sanitizeComponent(parts.joined(separator: "-"))
        return stem.isEmpty
            ? String(request.documentID.uuidString.lowercased().prefix(8))
            : stem
    }

    private static func finish(stem: String, source: NameSource, ext: String?) -> Name {
        let cleanedExt = (ext ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        let extOK = !cleanedExt.isEmpty
            && cleanedExt.utf8.count <= 10
            && cleanedExt.allSatisfy { $0.isLetter || $0.isNumber }
        let fileName = extOK ? "\(stem).\(cleanedExt)" : stem
        return Name(fileName: fileName, stem: stem, source: source)
    }

    private static func collapseWhitespace(_ value: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in value {
            if character == " " {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func trimEdgeCharacters(_ value: String) -> String {
        var result = value
        // 首尾点/空格/连字符一并裁剪：路径穿越输入 "…/…" 归一为分隔符后
        // 会残留前导 "-..-"，去边后目录名干净且仍幂等。
        let edge = CharacterSet(charactersIn: ". -")
        while let first = result.unicodeScalars.first, edge.contains(first) {
            result.removeFirst()
        }
        while let last = result.unicodeScalars.last, edge.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func truncate(_ value: String, maxUTF8Bytes: Int) -> String {
        let budget = max(0, maxUTF8Bytes - 9)   // "-" + 8 hex
        var out = ""
        var used = 0
        for character in value {
            let size = String(character).utf8.count
            if used + size > budget { break }
            out.append(character)
            used += size
        }
        out = trimEdgeCharacters(out)
        return out
    }

    /// FNV-1a 64 位 → 8 hex。Domain 不得引 CryptoKit（零框架红线）；
    /// 用途仅是命名去重后缀，不承担完整性证明。
    static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String((String(repeating: "0", count: max(0, 16 - hex.count)) + hex).prefix(8))
    }
}
