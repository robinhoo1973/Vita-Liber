// 2026-10-07 迁入 CI 簇(.github/actions/distill/extract/export_extraction_prompts/;来源
// refactor/tools/training/tools/export-prompts/main.swift,训练机共享正本;W15 归位 tools/,W16 随目录改名)。
// 逐字节一致为纪律;编译入口 = .github/actions/distill/extract/export_prompts.sh。
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 导出 App 端抽取提示词与卡种元数据（训练语料构建器的输入，单一事实源纪律的机械保证）。
///
/// 用法（经 `refactor/tools/export-extraction-prompts.sh` 编译后运行）：
///   exporter <out_dir>
///
/// 输出（每个注册卡种一组）：
///   - `prompt_<kind>.txt` —— 与 App 端 `ExtractionPromptBuilder.systemPrompt(for:)` 逐字一致的 system 段。
///     训练语料的 system 消息必须使用同一文本：训练/推理由同一函数产出 → 不存在复写漂移。
///   - `spec_<kind>.json` —— 卡种元数据（键序 / 必填 / 行锚 / 最大行数 / 输出 token 预算），
///     供语料构建器塑形 span 输出（键名与顺序与 App 完全同源）。
///   - `manifest.json` —— 导出清单（时间戳 + 各卡种行/共享键）。
///
/// 为什么不让 Python 侧「照抄」提示词：ExtractionPromptBuilder 的目录拼装涉及类型描述、
/// 别名、promptHint、枚举域、必填性五类素材——任何一处 spec 变更都必须自动流进训练语料，
/// 复写层 = 漂移源（2026-09-16 业主定案 promptHint 单一出口的同一纪律）。
@main
enum ExtractionPromptExporter {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("用法: exporter <out_dir>\n".utf8))
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        func fieldDict(_ f: FieldSpec) -> [String: Any] {
            var dict: [String: Any] = ["key": f.key, "required": f.isRequired]
            switch f.type {
            case .text(let maxChars):
                dict["type"] = "text"; dict["maxChars"] = maxChars
            case .narrative(let maxChars):
                dict["type"] = "narrative"; dict["maxChars"] = maxChars
            case .number(let integer):
                dict["type"] = "number"; dict["integer"] = integer
            case .date:
                dict["type"] = "date"
            case .quantityWithUnit:
                dict["type"] = "quantityWithUnit"
            case .enumerated(let domain):
                dict["type"] = "enumerated"; dict["domain"] = domain
            }
            // 2026-10-08 语料批(卡种 4→13):标签与打印词形随 spec 一并导出,供 CI 语料
            // 构建器给任意卡种打印行文本——单一事实源(禁 Python 复刻第二套标签)。
            dict["labels"] = f.labelAliases
            if let fb = f.fallback {
                switch fb {
                case .lineContaining(let tokens), .lineEndingWithAny(let tokens):
                    dict["fallback_tokens"] = tokens
                case .firstDateInRegion:
                    break
                }
            }
            // 枚举键的打印词形表(ClinicalFieldLabels 词表;键→表映射为导出器本地胶水;
            // 两族元组标签不同——vocabulary=tokens、TypeLabels=labels,统一归一到 [String])。
            let vocab: [(String, [String])]? = {
                switch f.key {
                case "report_type": return ClinicalFieldLabels.reportTypeVocabulary.map { ($0.type, $0.tokens) }
                case "treatment_type": return ClinicalFieldLabels.treatmentTypeVocabulary.map { ($0.type, $0.tokens) }
                case "diagnosis_type": return ClinicalFieldLabels.diagnosisTypeLabels.map { ($0.type, $0.labels) }
                case "conclusion_type": return ClinicalFieldLabels.conclusionTypeLabels.map { ($0.type, $0.labels) }
                default: return nil
                }
            }()
            if let vocab {
                dict["value_tokens"] = vocab.map { ["type": $0.0, "tokens": $0.1] }
            }
            return dict
        }

        var kinds: [[String: Any]] = []
        for spec in ExtractionSpecRegistry.specs {
            let prompt = ExtractionPromptBuilder.systemPrompt(for: spec)
            try prompt.write(to: outDir.appendingPathComponent("prompt_\(spec.kind).txt"),
                             atomically: true, encoding: .utf8)

            let specDict: [String: Any] = [
                "kind": spec.kind,
                "version": spec.version,
                "shared": spec.shared.map(fieldDict),
                "row": spec.row.map(fieldDict),
                "rowAnchor": spec.rowAnchor ?? "",
                "maxRowsPerRegion": spec.maxRowsPerRegion,
                "outputTokenBudget": spec.outputTokenBudget,
            ]
            let data = try JSONSerialization.data(withJSONObject: specDict,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: outDir.appendingPathComponent("spec_\(spec.kind).json"))

            kinds.append([
                "kind": spec.kind,
                "promptChars": prompt.count,
                "sharedKeys": spec.shared.map(\.key),
                "rowKeys": spec.row.map(\.key),
            ])
        }

        let manifest: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "generator": "refactor/tools/export_extraction_prompts/main.swift",
            "kinds": kinds,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try manifestData.write(to: outDir.appendingPathComponent("manifest.json"))

        print("[ok] exported \(ExtractionSpecRegistry.specs.count) kinds -> \(outDir.path)")
    }
}
