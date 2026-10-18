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

    /// B1 脚本金样放行线（2026-10-18 双 flag 拆分）：
    /// B1 确定性轨道不以真人语料为门（真人 500 条只约束 B2 模型轨），
    /// 但必须有脚本金样覆盖三类任务，且数值/结构阈值与 FR17.4 同线。
    public struct DeterministicReport: Sendable, Equatable {
        public var sampleCount: Int
        public var numericAccuracy: Double
        public var structureRate: Double
        public var passesReleaseLine: Bool {
            sampleCount >= requiredScriptedSamples
                && numericAccuracy >= requiredNumericAccuracy
                && structureRate >= requiredStructureRate
        }
        public init(sampleCount: Int, numericAccuracy: Double, structureRate: Double) {
            self.sampleCount = sampleCount
            self.numericAccuracy = numericAccuracy
            self.structureRate = structureRate
        }
    }

    /// B1 脚本金样最低条数（三任务 × 20 条；不含真人配额）。
    public static let requiredScriptedSamples = 60

    /// 跑 B1 脚本定标：不筛 `isHumanRecorded`，其余口径与 `evaluate` 相同。
    public static func evaluateDeterministic(
        corpus: Corpus,
        extract: (Sample) -> [String: String]
    ) -> DeterministicReport {
        var numericTotal = 0, numericHit = 0
        var structureTotal = 0, structureHit = 0
        for sample in corpus.samples {
            let actual = extract(sample)
            structureTotal += 1
            if sample.expected.allSatisfy({ actual[$0.key] == $0.value }) { structureHit += 1 }
            for (key, want) in sample.expected where isNumeric(want) {
                numericTotal += 1
                if actual[key] == want { numericHit += 1 }
            }
        }
        return DeterministicReport(
            sampleCount: corpus.samples.count,
            numericAccuracy: numericTotal == 0 ? 0 : Double(numericHit) / Double(numericTotal),
            structureRate: structureTotal == 0 ? 0 : Double(structureHit) / Double(structureTotal))
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
///
/// 2026-10-18 委员会裁决：结构化路径拆双 flag——
/// - `voiceDeterministicEnabled`（B1 确定性规则轨）：脚本金样定标驱动；
/// - `voiceModelEnabled`（B2 模型轨）：≥500 条真人语料定标驱动。
/// 二者都只由定标结果回写，**不是**可手工打开的开关（不变量不变）。
public enum FeatureFlags {
    /// B1 确定性结构化路径（文法抽取 → 字段草案）。
    /// 定标未过时必须为 false —— 此时语音/文本仅作纯转写，用户走触屏录入。
    public static var voiceDeterministicEnabled: Bool { deterministicCalibrationPassed }

    /// B2 模型结构化路径（意图/槽位模型）。真人语料未达 500 条时必须为 false。
    public static var voiceModelEnabled: Bool { modelCalibrationPassed }

    /// 由定标结果驱动，**不是**可以手工打开的开关——
    /// 若允许手工置 true，这个不变量立刻退化成一句注释。
    /// 审查修复：可变静态跨线程读写（定标回写 vs 语音会话读取）必须显式
    /// 声明并发语义——与全仓其余可变静态（L10n.languageCache 等）同纪律。
    public private(set) nonisolated(unsafe) static var deterministicCalibrationPassed = false
    public private(set) nonisolated(unsafe) static var modelCalibrationPassed = false

    /// 仅供定标流程回写（CI 跑完脚本金样后置位）。
    public static func applyDeterministicCalibration(_ report: VoiceCalibration.DeterministicReport) {
        deterministicCalibrationPassed = report.passesReleaseLine
    }

    /// 仅供定标流程回写（CI 跑完 ≥500 条真人金样后置位）。
    public static func applyModelCalibration(_ report: VoiceCalibration.Report) {
        modelCalibrationPassed = report.passesReleaseLine
    }
}
