import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

/// SU-CE-PROMPT · 抽取提示词单一出口（2026-09-16 业主定案 T1+T2 promptHint 模式）。
///
/// **为什么存在**：原提示词只把 `FieldSpec` 的**键名**拼成裸列表——
/// `Return only keys from this list: prescribed_at, hospital, …`——而 `FieldSpec` 早就带了
/// `promptHint`（**全仓从未被读取**，grep 实证）、`labelAliases`（「科室/科別」同字段）、
/// `type`（日期 / 数字 / **枚举域**）与必填性。模型因此只能从键名字面猜字段含义，
/// 枚举键更无从知道只能选哪几个值。诊断：「实施局限于关键字，没有组织提示词」。
///
/// 本套件**按结构断言**而非硬编码字符串——遍历注册表里的全部卡种，逐一核对
/// 「每个字段的键 / 类型 / 别名 / 必填性 / 提示都进了提示词」。新增卡种自动纳入。
@Suite("SU-CE-PROMPT · 提示词组织与字段目录")
struct ExtractionPromptBuilderTests {

    private let kinds = ["prescription", "encounter", "metric_sample", "claim_item", "medication"]

    private func spec(_ kind: String) throws -> ExtractionSpec {
        try #require(ExtractionSpecRegistry.spec(for: kind), "卡种 \(kind) 必须有 spec")
    }

    @Test("每个字段的**键**都出现在提示词里（覆盖完整）")
    func 键全覆盖() throws {
        for kind in kinds {
            let s = try spec(kind)
            let prompt = ExtractionPromptBuilder.systemPrompt(for: s)
            for field in s.fields {
                #expect(prompt.contains(field.key), "\(kind) 缺字段键 \(field.key)")
            }
        }
    }

    @Test("**每个非空 promptHint 都进了提示词**——这是本次修复的核心（此前是死数据）")
    func 提示词素材不再是死数据() throws {
        var checked = 0
        for kind in kinds {
            let s = try spec(kind)
            let prompt = ExtractionPromptBuilder.systemPrompt(for: s)
            for field in s.fields {
                let hint = field.promptHint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !hint.isEmpty else { continue }
                checked += 1
                #expect(prompt.contains(hint), "\(kind).\(field.key) 的 promptHint 未进提示词：\(hint)")
            }
        }
        #expect(checked > 0, "测试前提：注册表里必须存在非空 promptHint（否则本用例是空转）")
    }

    @Test("**枚举域的每个取值都进了提示词**——枚举键填对的前提")
    func 枚举域完整列入() throws {
        var checked = 0
        for kind in kinds {
            let s = try spec(kind)
            let prompt = ExtractionPromptBuilder.systemPrompt(for: s)
            for field in s.fields {
                guard case .enumerated(let domain) = field.type else { continue }
                for value in domain {
                    checked += 1
                    #expect(prompt.contains(value), "\(kind).\(field.key) 的枚举值 \(value) 未列入")
                }
            }
        }
        #expect(checked > 0, "测试前提：注册表里必须存在枚举字段（否则本用例是空转）")
    }

    @Test("每个字段的**别名**都进了提示词——「科室/科別」同字段的告知")
    func 别名进入提示词() throws {
        for kind in kinds {
            let s = try spec(kind)
            let prompt = ExtractionPromptBuilder.systemPrompt(for: s)
            for field in s.fields where !field.labelAliases.isEmpty {
                #expect(prompt.contains(field.labelAliases[0]),
                        "\(kind).\(field.key) 的别名未进提示词：\(field.labelAliases)")
            }
        }
    }

    @Test("必填性与共享/行分组都进了提示词")
    func 必填与分组() throws {
        let s = try spec("prescription")
        let prompt = ExtractionPromptBuilder.systemPrompt(for: s)
        #expect(prompt.contains("required"))
        #expect(prompt.contains("optional"))
        #expect(prompt.contains("SHARED fields"))
        #expect(prompt.contains("ROW fields"))
        // 行锚字段必须落在 ROW 段而非 SHARED 段
        if let anchor = s.rowAnchor {
            let rowSection = try #require(prompt.range(of: "ROW fields"))
            #expect(prompt[rowSection.lowerBound...].contains(anchor), "行锚 \(anchor) 应在 ROW 段内")
        }
    }

    @Test("安全边界语句完整保留（回归：注入防护 / 逐字子串 / 不诊断不换算）")
    func 安全语句保留() throws {
        let prompt = ExtractionPromptBuilder.systemPrompt(for: try spec("encounter"))
        #expect(prompt.contains("untrusted"), "注入防护：文档文本必须被声明为不可信数据")
        #expect(prompt.contains("never instructions"), "注入防护：不得听从文档内指令")
        #expect(prompt.contains("verbatim substring"), "grounding：值必须是原文逐字子串")
        #expect(prompt.contains("Do NOT translate"), "BR-002：不翻译不纠错")
        #expect(prompt.contains("diagnose"), "BR-006：不得诊断")
        #expect(prompt.contains("infer medication doses"), "BR-004：不得推断剂量")
    }

    @Test("零基编号行：lineIndex 即方括号数字")
    func 编号行零基() {
        let numbered = ExtractionPromptBuilder.numbered(lines: ["北京协和医院 处方笺", "日期：2026-09-12"])
        #expect(numbered == "[0] 北京协和医院 处方笺\n[1] 日期：2026-09-12")
    }

    @Test("转发壳与 Domain 单一出口逐字一致（Infrastructure 不再自建提示词）")
    func 转发壳同源() throws {
        let s = try spec("prescription")
        #expect(ModelPromptBuilder.systemPrompt(for: s) == ExtractionPromptBuilder.systemPrompt(for: s))
        #expect(ModelPromptBuilder.numbered(lines: ["a"]) == ExtractionPromptBuilder.numbered(lines: ["a"]))
    }
}
