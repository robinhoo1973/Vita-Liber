import Foundation

/// 统一能力画像（ADR-027）：泛化方言矩阵（M-DIALECT）与 OCR 语种包，
/// 使能力缺口由数据 + 运行时探测驱动，不硬编码（ADR-023 多语种矩阵）。
public struct EngineCapabilityProfile: Sendable, Equatable {
    public enum Tier: String, Sendable, Equatable {
        case complete    // T1 平台原生 locale，完整支持走金样定标线
        case bestEffort  // T2 无独立 locale 方言（2026-10-19 语言面收敛后零条目，枚举位保留）
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

    /// FR17.15 两语种能力矩阵（泛化为 EngineCapabilityProfile）：
    /// 普通话/英语 全部 T1 完整支持（混说=中英夹杂）。
    /// 2026-10-19 业主指令「减少 ASR 复杂度，语言只支持普通话和英文，支持混合输入」：
    /// T2 尽力识别层（闽南话/上海话/四川话）删除，粤语/日语/韩语随收敛退出。
    ///
    /// capabilityID 是能力探测/注册的**键**，矩阵内必须唯一（评审修正）：
    /// 四川话此前复用普通话的 `voiceIn.zh-Hans-CN`——按 ID 索引时两条画像互相覆盖，
    /// 且探测结果无法区分「普通话完整支持」与「四川话尽力识别」。方言不是独立
    /// BCP47 locale，用显式方言变体标签而非复用主 locale ID。
    public static func dialectMatrix() -> [EngineCapabilityProfile] {
        let t1: [(String, String)] = [
            ("zh-Hans-CN", "普通话"),
            ("en-US", "English"),
        ]
        return t1.map {
            EngineCapabilityProfile(
                capabilityID: "voiceIn.\($0.0)",
                supportedLocales: [Locale(identifier: $0.0)],
                tier: .complete, onDeviceOnly: true, notes: $0.1)
        }
    }

    /// FR17.15 两语种清单：派生自 dialectMatrix()（单一事实源，ADR-027——
    /// 禁止在视图层另建语种表，能力画像与选择器必须同源）。
    /// nativeName 为该语言原文。
    public static var twoLanguages: [(locale: String, nativeName: String, tier: Tier)] {
        dialectMatrix().map { profile in
            (profile.supportedLocales.first?.identifier ?? profile.capabilityID,
             profile.notes ?? profile.capabilityID,
             profile.tier)
        }
    }

    /// FR17.15 输入语言选项 = 两语种（2026-10-19 收敛：语言选择器只呈现两语种，
    /// 目录 extras 不再注入——语言面收敛即产品承诺收敛，不因模型目录变化扩张）。
    /// 参数保留签名兼容（实验室/语言页共用调用点），目录语言覆盖不再消费。
    public static func inputLanguageOptions(choice: VoiceEngineChoice,
                                            index: ASRModelReleaseIndex?) -> [(locale: String, nativeName: String, tier: Tier)] {
        return twoLanguages
    }
}
