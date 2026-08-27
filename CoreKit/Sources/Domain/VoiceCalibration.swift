import Foundation

/// FR17.4 语音金样定标与放行线（dev-pm §3.3 一票否决项）。
///
/// **为什么需要一个「放行线」而不是一条永远红的测试**：
/// ≥500 条真人语料是运营依赖（真机录制），代码无法生成。若把它写成一条恒红的断言，
/// 整条流水线永远红，红灯就此失去信息量——所有人开始忽略它，等于没有门禁。
/// dev-pm §6 已给出正确处置：「未达标只发触屏路径，不阻塞其他 P0.5」。
///
/// 于是把它落成**不变量**而非断言：
///     语音结构化路径已启用  ⟹  定标已通过
/// 逆否即：定标没过就**不许**启用语音结构化。语料缺席时开关必须是关的，
/// 于是「缺证据」被强制表达为「功能关闭」，而不是「假装已验收」——
/// 这正是 ERR#27/#30 根因族的正解：让缺证据在产品行为上可见。
public enum VoiceCalibration {

    /// 一条金样语料：转写文本 + 期望抽取结果
    public struct Sample: Sendable, Equatable, Codable {
        public var id: String
        public var transcript: String
        /// 语料类别（metric/reminder/profile），决定走哪套文法
        public var kind: String
        /// 语种标识（FR17.15 六语种矩阵配额；混说样本用 "mixed"）
        public var locale: String
        /// 是否真人录制语料。**只有 true 才计入 FR17.4 的 ≥500 配额**——
        /// 手写样例可以验证文法正确性，但不能代表真人口音与语流。
        public var isHumanRecorded: Bool
        /// 期望的字段抽取结果（key → value）
        public var expected: [String: String]
        public init(id: String, transcript: String, kind: String, locale: String,
                    isHumanRecorded: Bool, expected: [String: String]) {
            self.id = id; self.transcript = transcript; self.kind = kind
            self.locale = locale; self.isHumanRecorded = isHumanRecorded; self.expected = expected
        }
    }

    public struct Corpus: Sendable, Equatable, Codable {
        public var version: String
        public var samples: [Sample]
        public init(version: String, samples: [Sample]) {
            self.version = version; self.samples = samples
        }
    }

    /// FR17.4 放行线
    public static let requiredHumanSamples = 500
    public static let requiredNumericAccuracy = 0.90
    public static let requiredStructureRate = 0.85

    public struct Report: Sendable, Equatable {
        public var humanSampleCount: Int
        /// 数值字段准确率（分母 = 期望里含数值字段的样本数）
        public var numericAccuracy: Double
        /// 完整结构率（全部期望字段都抽对的样本占比）
        public var structureRate: Double
        /// 六语种/混说配额分布（locale → 真人语料条数）
        public var localeQuota: [String: Int]

        /// 是否达到放行线——**三条全中才算过**，缺语料一律不过
        public var passesReleaseLine: Bool {
            humanSampleCount >= requiredHumanSamples
                && numericAccuracy >= requiredNumericAccuracy
                && structureRate >= requiredStructureRate
        }

        /// 未达标原因（人类可读，进 CI Step Summary 与台账）
        public var blockingReasons: [String] {
            var out: [String] = []
            if humanSampleCount < requiredHumanSamples {
                out.append("真人语料 \(humanSampleCount)/\(requiredHumanSamples) 条")
            }
            if numericAccuracy < requiredNumericAccuracy {
                out.append(String(format: "数值准确率 %.1f%% < 90%%", numericAccuracy * 100))
            }
            if structureRate < requiredStructureRate {
                out.append(String(format: "完整结构率 %.1f%% < 85%%", structureRate * 100))
            }
            return out
        }
    }

    /// 跑定标：对每条语料执行文法抽取，比对期望。
    /// `extract` 由调用方注入（避免 Domain 内部耦合具体文法表），
    /// 生产与测试都传 `VoiceGrammarDefaults` 那一套——单一事实源。
    public static func evaluate(
        corpus: Corpus,
        extract: (Sample) -> [String: String]
    ) -> Report {
        let human = corpus.samples.filter(\.isHumanRecorded)
        var numericTotal = 0, numericHit = 0
        var structureTotal = 0, structureHit = 0
        var quota: [String: Int] = [:]

        for sample in human {
            quota[sample.locale, default: 0] += 1
            let actual = extract(sample)
            structureTotal += 1
            if sample.expected.allSatisfy({ actual[$0.key] == $0.value }) { structureHit += 1 }
            for (key, want) in sample.expected where isNumeric(want) {
                numericTotal += 1
                if actual[key] == want { numericHit += 1 }
            }
        }
        return Report(
            humanSampleCount: human.count,
            numericAccuracy: numericTotal == 0 ? 0 : Double(numericHit) / Double(numericTotal),
            structureRate: structureTotal == 0 ? 0 : Double(structureHit) / Double(structureTotal),
            localeQuota: quota)
    }

    static func isNumeric(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// 能力开关（dev-pm §4.3：高风险能力一律 flag 化）。
///
/// 红线功能（敏感保护 / 门禁）**不设关闭路径**，故不在此处；
/// 本枚举只承载「定标未过即降级」的高风险能力。
public enum FeatureFlags {
    /// 语音**结构化**路径（文法抽取 → 字段草稿）。
    /// 定标未过时必须为 false —— 此时语音仅作纯转写填入文本框，
    /// 用户走触屏完成结构化录入（dev-pm §6 缓解策略）。
    /// 纯转写与触屏路径不受影响，其余 P0.5 功能不被阻塞。
    public static var voiceStructuringEnabled: Bool { voiceCalibrationPassed }

    /// 由定标结果驱动，**不是**可以手工打开的开关——
    /// 若允许手工置 true，这个不变量立刻退化成一句注释。
    public private(set) static var voiceCalibrationPassed = false

    /// 仅供定标流程回写（CI 跑完金样后置位）。
    public static func applyCalibration(_ report: VoiceCalibration.Report) {
        voiceCalibrationPassed = report.passesReleaseLine
    }
}
