import Foundation

/// 杀手实验报告渲染：JSON（Codable、键排序）+ Markdown 摘要表。纯函数——同输入恒得同字节输出
/// （数值一律经 `ASREvaluation.formatFixed` 定宽格式化；系统按 engineID、句子按清单顺序）。
/// Markdown 只含指标，不含参考/假设原文（原文只在 JSON 明细里，供业主本机复核）。
public enum ASREvaluationRendering {

    /// JSON 顶层文档。
    public struct Document: Sendable, Equatable, Codable {
        public var report: ASREvaluation.Report
        public var verdict: ASREvaluationVerdict?

        public init(report: ASREvaluation.Report, verdict: ASREvaluationVerdict? = nil) {
            self.report = report
            self.verdict = verdict
        }
    }

    public static func json(report: ASREvaluation.Report, verdict: ASREvaluationVerdict? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(report: report, verdict: verdict))
    }

    public static func decodeDocument(from data: Data) throws -> Document {
        try JSONDecoder().decode(Document.self, from: data)
    }

    public static func markdown(report: ASREvaluation.Report, verdict: ASREvaluationVerdict? = nil) -> String {
        var lines: [String] = ["# ASR 杀手实验评测报告", ""]
        let tagSummary = report.tagCounts.map { "\($0.tag.rawValue) \($0.count)" }.joined(separator: " · ")
        lines.append("- 句数：\(report.utteranceCount)（\(tagSummary)）")
        lines.append("- 口径：MER = 汉字按字 + 英文按词（小写）+ 数字整体；NFKC、去标点。"
                     + "micro = Σ错误 / Σ参考 token，macro = 逐句 MER 均值；failed 按空假设计分，skipped 不计分")
        lines.append("")
        lines += systemTable(report)
        lines += tagTable(report)
        lines += oracleSection(report)
        if let verdict { lines += verdictSection(verdict) }
        if !report.warnings.isEmpty {
            lines += ["## 告警", ""]
            lines += report.warnings.map { "- " + $0 }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 分节

    static func systemTable(_ report: ASREvaluation.Report) -> [String] {
        var lines = ["## 各系统", "",
                     "| 系统 | 识别/失败/跳过 | MER micro | MER macro | 替换/删除/插入 | 数字伤害 | 否定伤害 | 保护词伤害 "
                        + "| 急救召回 | 急救误报 | 置信 AUROC（词数） | 延迟 p50/p95/首句 ms | 峰值内存 |",
                     "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for system in report.systems {
            guard system.isIncluded else {
                let reason = "已跳过：" + (system.skipReason ?? "")
                lines.append(row([system.engineID, reason] + Array(repeating: "—", count: 11)))
                continue
            }
            let overall = system.overall
            let latency = system.latency
            let latencyCell = [latency.p50, latency.p95, latency.first].map { optionalFixed($0, digits: 0) }
                .joined(separator: "/")
            let memoryCell = system.peakMemoryBytes.map { mebibytes($0) } ?? "—"
            let cells: [String] = [
                system.engineID,
                "\(system.recognizedCount)/\(system.failedCount)/\(system.skippedCount)",
                ASREvaluation.formatPercent(overall.micro),
                ASREvaluation.formatPercent(overall.macro),
                "\(overall.substitutions)/\(overall.deletions)/\(overall.insertions)",
                harmCell(system.protection.numeric),
                harmCell(system.protection.negation),
                harmCell(system.protection.protectedTerm),
                ratioCell(system.emergency.positiveDetected, system.emergency.positiveCount),
                ratioCell(system.emergency.negativeFlagged, system.emergency.negativeCount),
                aurocCell(system.confidence),
                latencyCell,
                memoryCell,
            ]
            lines.append(row(cells))
        }
        lines.append("")
        return lines
    }

    static func tagTable(_ report: ASREvaluation.Report) -> [String] {
        let tags = ASREvaluation.Tag.allCases
        var lines = ["## 按标签分层 MER（micro，括号内为计分句数）", "",
                     row(["系统"] + tags.map { $0.rawValue }),
                     "|" + Array(repeating: "---|", count: tags.count + 1).joined()]
        for system in report.systems where system.isIncluded {
            let cells = tags.map { tag -> String in
                let rate = system.rate(for: tag)
                return rate.utteranceCount == 0 ? "—" : "\(ASREvaluation.formatPercent(rate.micro)) (\(rate.utteranceCount))"
            }
            lines.append(row([system.engineID] + cells))
        }
        lines.append("")
        return lines
    }

    static func oracleSection(_ report: ASREvaluation.Report) -> [String] {
        var lines = ["## 逐句 oracle（只作参考）", "",
                     "- 每句取各系统最小 MER（整句上界）；token 级 oracle 依赖融合对齐，本期不做",
                     "- 逐句增益会系统性低估只在句内少数词上起作用的引擎——引擎去留只看止损判定中的 token 级证据"]
        guard let oracle = report.oracle else {
            lines += ["- 无参与比较的系统", ""]
            return lines
        }
        lines.append("- 系统池：\(oracle.engineIDs.joined(separator: ", "))")
        lines.append("- oracle MER：micro \(ASREvaluation.formatPercent(oracle.rate.micro)) · "
                     + "macro \(ASREvaluation.formatPercent(oracle.rate.macro))（\(oracle.rate.utteranceCount) 句）")
        lines += ["", "| 系统 | 不含该系统 oracle | 含该系统 oracle | 增益 micro（百分点） | 增益 macro（百分点） | 句数 |",
                  "|---|---|---|---|---|---|"]
        for gain in report.oracleGains {
            let cells: [String] = [
                gain.engineID,
                ASREvaluation.formatPercent(gain.withoutSystem.micro),
                ASREvaluation.formatPercent(gain.withSystem.micro),
                optionalFixed(gain.microGainPercentagePoints, digits: 2),
                optionalFixed(gain.macroGainPercentagePoints, digits: 2),
                "\(gain.withSystem.utteranceCount)",
            ]
            lines.append(row(cells))
        }
        lines.append("")
        return lines
    }

    static func verdictSection(_ verdict: ASREvaluationVerdict) -> [String] {
        let decision = verdict.decision == .continue ? "continue（多模融合可继续）" : "stop（止损：终止多模融合）"
        var lines = ["## 止损判定：**\(decision)**", "",
                     "| 规则 | 状态 | 动作 | 理由 |", "|---|---|---|---|"]
        for finding in verdict.findings {
            let ruleText: String = label(finding.rule)
            let statusText: String = label(finding.status)
            let actionText: String = label(finding.action)
            let cells: [String] = [ruleText, statusText, actionText, finding.reasons.joined(separator: "；")]
            lines.append(row(cells))
        }
        lines.append("")
        lines.append("- 自动改写：" + (verdict.automaticRewriteAllowed
            ? "放行（规则 3 继续，且 harm/fix 与置信度区分度均通过）"
            : "不放行（只保留不一致提示 / 候选点选）"))
        for harmFix in verdict.harmFixByCandidate {
            lines.append("- harm/fix（\(harmFix.candidateEngineID) 相对 \(harmFix.primaryEngineID)）：fix \(harmFix.fixes)、"
                         + "harm \(harmFix.harms)、比值 \(ASREvaluationVerdict.ratioText(harmFix))")
        }
        lines.append("- 急救样本量：" + ASREvaluationVerdict.adequacyNote(verdict.emergencySampleAdequacy))
        if let bootstrap = verdict.segmentedVersusContinuous {
            lines.append("- 配对 bootstrap（\(bootstrap.engineA) − \(bootstrap.engineB)，micro 口径）："
                         + "\(ASREvaluation.formatSigned(bootstrap.microDifference * 100, digits: 2)) 个百分点，"
                         + "95% CI [\(ASREvaluation.formatSigned(bootstrap.microLower * 100, digits: 2)), "
                         + "\(ASREvaluation.formatSigned(bootstrap.microUpper * 100, digits: 2))]")
        }
        lines.append("")
        return lines
    }

    // MARK: - 单元格

    static func row(_ cells: [String]) -> String {
        let escaped = cells.map { cell in
            cell.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        return "| " + escaped.joined(separator: " | ") + " |"
    }

    static func optionalFixed(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        return ASREvaluation.formatFixed(value, digits: digits)
    }

    static func mebibytes(_ bytes: Int64) -> String {
        ASREvaluation.formatFixed(Double(bytes) / 1_048_576, digits: 1) + " MiB"
    }

    static func aurocCell(_ confidence: ASREvaluation.ConfidenceDiscrimination) -> String {
        guard let auroc = confidence.auroc else { return confidence.sampleCount == 0 ? "—" : "单类 (\(confidence.sampleCount))" }
        return "\(ASREvaluation.formatFixed(auroc, digits: 3)) (\(confidence.sampleCount))"
    }

    static func harmCell(_ count: ASREvaluation.ClassHarmCount) -> String {
        count.total == 0 ? "—" : "\(count.harmed)/\(count.total)"
    }

    static func ratioCell(_ hit: Int, _ total: Int) -> String {
        guard total > 0 else { return "—" }
        return "\(hit)/\(total) (\(ASREvaluation.formatPercent(Double(hit) / Double(total))))"
    }

    static func label(_ rule: ASREvaluationVerdict.Rule) -> String {
        switch rule {
        case .appleEnglishMarginalGain: return "Apple-en 边际增益"
        case .segmentedVersusContinuous: return "切段 vs 连续"
        case .safetyRegression: return "急救/否定回归"
        case .harmFixRatio: return "harm/fix"
        case .confidenceDiscrimination: return "置信度区分度 AUROC"
        }
    }

    static func label(_ status: ASREvaluationVerdict.Status) -> String {
        switch status {
        case .passed: return "通过"
        case .triggered: return "触发"
        case .advisory: return "证据不足（advisory）"
        case .notEvaluated: return "未评估"
        }
    }

    static func label(_ action: ASREvaluationVerdict.Action) -> String {
        switch action {
        case .keepAppleEnglish: return "保留 Apple-en"
        case .dropAppleEnglish: return "删除 Apple-en"
        case .awaitTokenLevelEvidence: return "暂不删除（待 token 级证据）"
        case .allowSameSegmentDecoding: return "可做同段解码"
        case .skipSameSegmentDecoding: return "不做同段解码"
        case .continueFusion: return "继续融合"
        case .terminateFusion: return "终止融合"
        case .allowAutomaticRewrite: return "可放行自动改写"
        case .forbidAutomaticRewrite: return "不得放行自动改写"
        case .allowTokenLevelRewrite: return "可逐词改写（限达标置信源）"
        case .disagreementHintsOnly: return "只保留不一致提示"
        }
    }
}

// MARK: - 定宽数值格式（报告与判定理由共用；POSIX printf，平台无关）

extension ASREvaluation {
    /// 固定小数位；「-0.00」归一为「0.00」，避免浮点尾差造成渲染漂移。
    static func formatFixed(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        if text.hasPrefix("-"), !text.contains(where: { "123456789".contains($0) }) {
            return String(text.dropFirst())
        }
        return text
    }

    /// 带符号：正数加「+」，零不加。
    static func formatSigned(_ value: Double, digits: Int) -> String {
        let text = formatFixed(value, digits: digits)
        guard !text.hasPrefix("-"), text.contains(where: { "123456789".contains($0) }) else { return text }
        return "+" + text
    }

    /// 比例 → 百分数（两位小数）；nil → 「—」。
    static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return formatFixed(value * 100, digits: 2) + "%"
    }
}
