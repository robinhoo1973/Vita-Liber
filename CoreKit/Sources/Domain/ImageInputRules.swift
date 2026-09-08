import Foundation

/// FR12.11 AI 图片/文档输入的 Domain 判据。
///
/// 图片识别结果一律标注「识别未确认」（D 级）——BR-003 在图片路径上的落点：
/// 机器识别的文本**不得**成为确定性陈述、不得进入计划/急救卡/AI 事实。
/// 纯影像无文字 → 「未识别到文字」+ 手输替代建议。
public enum ImageInputRules {

    public struct Recognition: Sendable, Equatable {
        /// 识别出的文本行（按序）
        public var lines: [String]
        /// 识别置信度（Vision 引擎输出，0..1）
        public var confidence: Double
        public init(lines: [String], confidence: Double) {
            self.lines = lines; self.confidence = confidence
        }
        public var text: String { lines.joined(separator: "\n") }
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 识别文本 → 待确认字段（**恒 D 级**，无论引擎置信度多高——
    /// 「识别未确认」是来源属性不是质量属性，BR-003）
    public static func draftFields(from recognition: Recognition) -> [CandidateField] {
        // 与 isEmpty 同源判定（trim 后为空 = 无文字）——两处曾不一致：
        // isEmpty 判 trim 后、本函数判原始串，导致「只有空白」的识别
        // 一边说无文字、一边产出空白草稿。
        guard !recognition.isEmpty else { return [] }
        let body = recognition.text
        // displayLabel 用语义键（与 VoiceInputTemplate.confirmationSet 同约定）——
        // 审查修复（§11 清偿残根）：原「图片识别文本」为 Domain 硬编码简体；
        // 确认卡渲染只读 value 不经 displayLabel（ImageConfirmSheet），
        // 键语义与语音路径的 displayLabel=key 约定对齐。
        return [CandidateField(key: "image_text", displayLabel: "image_text",
                               rawText: body, confidence: recognition.confidence,
                               value: body, grade: .ocrUnconfirmed)]
    }

    /// 无文字时的降级提示（纯事实 + 手输替代——不含建议/应该等负清单词，
    /// BR-006 措辞纪律同样适用）。Domain 只出类型化键，文案由 App 层 L10n
    /// 渲染（第四轮全仓审查修复：原 `noTextMessage` 为 Domain 硬编码简体
    /// 中文，zh-Hant/en 用户直见简体，且 L0 中文扫描只覆盖视图层、门禁永不红）。
    public static let noTextKey = "image_input.noText"

    /// 图片文本可否直接作为「提问」提交：
    /// - 有文字 → 必须先经确认卡（用户逐条确认后才可提交，BR-003）；
    /// - 无文字 → 返回 nil，UI 展示 noTextKey 对应文案。
    public static func requiresConfirmation(_ recognition: Recognition) -> Bool {
        !recognition.isEmpty
    }

    /// 支持的图片扩展名白名单（全仓唯一出处——快速拍摄/资料库两入口共用；
    /// 第四轮全仓审查修复：原为两份手写副本，新增格式只改一处时另一入口
    /// 对同格式悄然走「归档元数据」降级路径）。
    public static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp",
    ]

    /// 按文件字节头嗅探真实图片 MIME（扩展名不可信——相册 HEIC 曾被
    /// 硬编码为 image/jpeg，PNG 原件以 .jpg 落盘，扩展名与内容不符，
    /// BR-002 原图语义受损）。未知字节回落调用方提供的兜底值。
    public static func sniffMimeType(of data: Data, fallback: String = "image/jpeg") -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            return "image/png"
        }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return "image/jpeg"
        }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 {
            return "image/gif"
        }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return "image/webp"
        }
        // 第六轮全仓审查修复：HEIF 容器品牌不止 heic——heix/heif/mif1/msf1/
        // hevc/hevx 同为 HEIF 族，原实现只认 "heic" 四字节，其余品牌落
        // fallback(image/jpeg) → 原件以 .jpg 扩展名落盘（BR-002 扩展名与
        // 内容一致的约定被破坏）。
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "heif", "mif1", "msf1", "hevc", "hevx"].contains(brand) {
                return "image/heic"
            }
        }
        return fallback
    }

    /// MIME → 落盘扩展名（BR-002 原件扩展名与内容一致；未知回落 "jpg"）。
    public static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/jpeg", "image/jpg": return "jpg"
        default: return "jpg"
        }
    }
}
