import Foundation

/// 统一能力画像（ADR-027）：泛化方言矩阵（M-DIALECT）与 OCR 语种包，
/// 使能力缺口由数据 + 运行时探测驱动，不硬编码（ADR-023 多语种矩阵）。
public struct EngineCapabilityProfile: Sendable, Equatable {
    public enum Tier: String, Sendable, Equatable {
        case complete    // T1 平台原生 locale，完整支持走金样定标线
        case bestEffort  // T2 无独立 locale 方言，尽力识别 + 低置信强制复核
    }

    public var capabilityID: String
    public var supportedLocales: [Locale]
    public var tier: Tier
    public var onDeviceOnly: Bool
    public var maxDuration: TimeInterval?
    public var notes: String?

    public init(capabilityID: String,
                supportedLocales: [Locale],
                tier: Tier,
                onDeviceOnly: Bool,
                maxDuration: TimeInterval? = nil,
                notes: String? = nil) {
        self.capabilityID = capabilityID
        self.supportedLocales = supportedLocales
        self.tier = tier
        self.onDeviceOnly = onDeviceOnly
        self.maxDuration = maxDuration
        self.notes = notes
    }

    /// FR17.15 六语种能力矩阵（泛化为 EngineCapabilityProfile）：
    /// T1 = 普通话/粤语/英语（平台原生 locale）；T2 = 闽南话/上海话/四川话（尽力识别）。
    ///
    /// capabilityID 是能力探测/注册的**键**，矩阵内必须唯一（评审修正）：
    /// 四川话此前复用普通话的 `voiceIn.zh-Hans-CN`——按 ID 索引时两条画像互相覆盖，
    /// 且探测结果无法区分「普通话完整支持」与「四川话尽力识别」。方言不是独立
    /// BCP47 locale，用显式方言变体标签而非复用主 locale ID。
    public static func dialectMatrix() -> [EngineCapabilityProfile] {
        let t1: [(String, String)] = [
            ("zh-Hans-CN", "普通话"),
            ("yue-Hant-HK", "粤语"),
            ("en-US", "英语"),
        ]
        let t2: [(String, String)] = [
            ("nan-TW", "闽南话"),
            ("wuu-CN", "上海话"),
            ("zh-Hans-CN-Sichuan", "四川话(西南官话)"),
        ]
        let t1s = t1.map {
            EngineCapabilityProfile(
                capabilityID: "voiceIn.\($0.0)",
                supportedLocales: [Locale(identifier: $0.0)],
                tier: .complete, onDeviceOnly: true, notes: $0.1)
        }
        let t2s = t2.map {
            EngineCapabilityProfile(
                capabilityID: "voiceIn.\($0.0)",
                supportedLocales: [Locale(identifier: $0.0)],
                tier: .bestEffort, onDeviceOnly: true,
                notes: $0.1 + "·尽力识别")
        }
        return t1s + t2s
    }
}
