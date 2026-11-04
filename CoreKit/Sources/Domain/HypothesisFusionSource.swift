import Foundation

/// 一个融合源：引擎原生假设 + 来源组 + 角色 + 可产出脚本声明。
///
/// **通用契约（2026-11-04）**：ASR（生产主轨 + Apple zh-CN/en-US）与 OCR
/// （Paddle 主轨 + Apple Vision）都映射为同一 `[HypothesisFusionSource]` 列表，
/// 交给同一个融合内核。**本层只定义数据契约**：不启动任何引擎、不读取音频/图片。
public struct HypothesisFusionSource: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable, Codable {
        /// 生产主轨（交付文本的基准）。
        case primary
        /// 参与对照的副轨。
        case secondary
    }

    public var hypothesis: TranscriptionHypothesis
    /// 来源组（如 `sherpa` / `apple-speech` / `paddle` / `apple-vision`）；只作元数据与输出标注，
    /// 不改变按 engineID 去重的投票规则。
    public var sourceGroup: String
    public var role: Role
    /// 该源可产出的脚本；nil = 沿用 `HypothesisFusionOptions.producibleScripts`。
    public var producibleScripts: Set<HypothesisFusionScript>?

    public init(hypothesis: TranscriptionHypothesis, sourceGroup: String, role: Role,
                producibleScripts: Set<HypothesisFusionScript>? = nil) {
        self.hypothesis = hypothesis
        self.sourceGroup = sourceGroup
        self.role = role
        self.producibleScripts = producibleScripts
    }
}

/// 一次多源融合请求（源列表 + 校准 + 参数）。
public struct HypothesisFusionRequest: Sendable, Equatable {
    public var sources: [HypothesisFusionSource]
    public var calibration: HypothesisFusionCalibration
    public var options: HypothesisFusionOptions

    public init(sources: [HypothesisFusionSource], calibration: HypothesisFusionCalibration,
                options: HypothesisFusionOptions = HypothesisFusionOptions()) {
        self.sources = sources
        self.calibration = calibration
        self.options = options
    }
}

extension HypothesisFusion {
    /// 多源融合入口：必须恰有一个 `.primary` 源。
    ///
    /// - 副轨仍按 engineID 排序去重（输入顺序不影响结果）；`sourceGroup` 只随结果输出。
    /// - 源级 `producibleScripts` 覆盖 `options.producibleScripts` 的同名引擎声明。
    /// - 无主轨 / 多个主轨 → fail-closed：空文本 + `.noPrimarySource` / `.ambiguousPrimary`。
    public static func fuse(_ request: HypothesisFusionRequest) -> FusedTranscript {
        fuse(sources: request.sources, calibration: request.calibration, options: request.options)
    }

    /// 多源融合入口（便捷重载）。
    public static func fuse(sources: [HypothesisFusionSource], calibration: HypothesisFusionCalibration,
                            options: HypothesisFusionOptions = HypothesisFusionOptions()) -> FusedTranscript {
        var primary: HypothesisFusionSource?
        var ambiguous = false
        var secondaries: [HypothesisFusionSource] = []
        for source in sources {
            guard source.role == .primary else {
                secondaries.append(source)
                continue
            }
            if primary != nil { ambiguous = true }
            primary = primary ?? source
        }
        guard let primary else { return unavailable(.noPrimarySource) }
        guard !ambiguous else { return unavailable(.ambiguousPrimary) }

        var effective = options
        // 按引擎键排序后写入，保证源级脚本声明与输入顺序无关。
        for source in sources.sorted(by: sourceOrder) {
            guard let scripts = source.producibleScripts else { continue }
            effective.producibleScripts[source.hypothesis.engineID] = scripts
        }
        let ordered = orderedSecondaries(secondaries.map(\.hypothesis),
                                         primaryEngineID: primary.hypothesis.engineID)
        var groups: [String: String] = [:]
        for source in secondaries.sorted(by: sourceOrder) where groups[source.hypothesis.engineID] == nil {
            groups[source.hypothesis.engineID] = source.sourceGroup
        }
        var result = fuse(primary: primary.hypothesis, secondaries: ordered,
                          calibration: calibration, options: effective)
        result.sourceGroups = [primary.sourceGroup] + ordered.map { groups[$0.engineID] ?? "" }
        return result
    }

    /// 契约错误时的 fail-closed 输出：不替调用方挑主轨、不留任何改写。
    private static func unavailable(_ reason: HypothesisFusionFallback) -> FusedTranscript {
        FusedTranscript(text: "", edits: [], disputes: [],
                        engineID: "fusion:\(formatVersion)(primary=none;secondaries=)",
                        sources: [], fallback: reason)
    }

    /// 源级确定性排序：engineID → 组 → 角色 → 文本（均按 UTF-8 字节序）。
    private static func sourceOrder(_ lhs: HypothesisFusionSource, _ rhs: HypothesisFusionSource) -> Bool {
        let left = [lhs.hypothesis.engineID, lhs.sourceGroup, lhs.role.rawValue, lhs.hypothesis.text]
        let right = [rhs.hypothesis.engineID, rhs.sourceGroup, rhs.role.rawValue, rhs.hypothesis.text]
        for (leftField, rightField) in zip(left, right) where !leftField.utf8.elementsEqual(rightField.utf8) {
            return leftField.utf8.lexicographicallyPrecedes(rightField.utf8)
        }
        return false
    }
}
