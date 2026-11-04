import Foundation

/// FR17.1（V3.61 停顿丢字修正）：一次「按住说话」= 一个会话；会话内识别请求可多轮——
/// 静音端点或基线轨 ~60s 上限产生的 isFinal 只是**提交一段**，麦克风不停、会话不结束，
/// 直到用户松手。显示文本 = 已提交段 + 当前部分结果；松手 `finish()` 返回全部段。
/// 纯值类型，引擎与视图模型共用（引擎侧 actor 内部持有；视图侧只读投影）。
public struct TranscriptSessionAccumulator: Sendable, Equatable {
    public private(set) var committed: [String] = []
    public private(set) var partial: String = ""
    private var finished = false

    public init() {}

    /// Empty finals/errors preserve the most recent partial without finishing the session.
    public mutating func commit(_ text: String) {
        guard !finished else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let retained = trimmed.isEmpty ? partial.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        partial = ""
        guard !retained.isEmpty else { return }
        committed.append(retained)
    }

    public mutating func updatePartial(_ text: String) {
        guard !finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        partial = text
    }

    /// 已提交段 + 当前部分（段间以空格连接：中英混说与句读由用户/润色层处理，不擅自加标点）
    public var displayText: String {
        TranscriptJoiner.join(
            (committed + [partial.trimmingCharacters(in: .whitespacesAndNewlines)])
                .filter { !$0.isEmpty })
    }

    /// 松手收尾：未提交的部分结果作为最后一段提交；幂等
    public mutating func finish() -> [String] {
        if !finished {
            commit("")
            finished = true
        }
        return committed
    }

    /// 是否应主动换段：基线轨在 `maxSegmentSeconds - 5` 秒提前换请求（与
    /// `TranscriptionSegmentation` 的 5s 安全余量同口径）；升级轨长音频免分段。
    public static func shouldRotate(elapsedSeconds: Double, capability: TranscriptionCapability) -> Bool {
        guard !capability.supportsLongForm else { return false }
        return elapsedSeconds >= Double(max(5, capability.maxSegmentSeconds - 5))
    }
}

/// FR17.15 识别词表（`contextualStrings` / sherpa hotwords，≤100 条）：主语言识别 + 领域词注入。
/// 混说开关开：用户已确认的药名优先，其后是医疗单位与（选择了英语时的）常见英文医学词。
/// 混说开关关：只注入已确认药名（round3 P0-B 解绑：药名是 OOV 主因、药箱库存是最强先验，
/// 不应随混说开关一起消失；单位与英文医学词仍只属于混说）。
/// 词表是识别偏置，不是医学结论；不含任何阈值/剂量数字。
public enum MixedSpeechVocabulary {
    /// Apple contextualStrings 建议上限
    public static let limit = 100

    static let units: [String] = [
        "mmHg", "mmol/L", "mg/dL", "g/L", "bpm", "kg", "cm", "℃", "IU", "mg", "ml", "μg",
    ]
    static let englishMedical: [String] = [
        "CT", "MRI", "B超", "X光", "CRP", "HbA1c", "BMI", "ECG", "PET", "SpO2", "ICU",
        "Vitamin D", "ibuprofen", "amoxicillin", "metformin", "insulin", "aspirin",
    ]

    /// 混说词表：已确认药名 → 医疗单位 →（选择了英语时）英文医学词。
    public static func terms(primaryLocale: String, otherLocales: [String],
                              recentDrugNames: [String], limit: Int = limit) -> [String] {
        let locales = [primaryLocale] + otherLocales
        let english = locales.contains(where: { $0.hasPrefix("en") }) ? englishMedical : []
        return capped(recentDrugNames + units + english, limit: limit)
    }

    /// 单语词表：只含已确认药名（不含单位、英文医学词）；与 `terms` 同一去重与上限口径。
    public static func drugNameTerms(recentDrugNames: [String], limit: Int = limit) -> [String] {
        capped(recentDrugNames, limit: limit)
    }

    /// 按混说开关选词表（装配入口单点；`languageMode` 仍只由开关决定，与本函数无关）。
    public static func contextualStrings(mixedInput: Bool, primaryLocale: String, otherLocales: [String],
                                         recentDrugNames: [String], limit: Int = limit) -> [String] {
        mixedInput
            ? terms(primaryLocale: primaryLocale, otherLocales: otherLocales,
                    recentDrugNames: recentDrugNames, limit: limit)
            : drugNameTerms(recentDrugNames: recentDrugNames, limit: limit)
    }

    /// 保序：去首尾空白、丢空串、按去空白后的原文去重，截到 min(调用方上限, SDK 上限)。
    private static func capped(_ candidates: [String], limit: Int) -> [String] {
        let limit = min(Self.limit, max(0, limit))
        var seen = Set<String>()
        var out: [String] = []
        for term in candidates where out.count < limit {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
