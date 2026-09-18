import Foundation

/// 子项目 F（2026-09-14）：GBNF 文法生成器——从 `ExtractionSpec` 的 `fields` 定义自动生成 llama.cpp GBNF 文法。
/// 纯 Domain、零依赖、确定性输出；T2 引擎用此文法约束模型 JSON 输出格式。
///
/// GBNF 格式参考：https://github.com/ggerganov/llama.cpp/blob/master/grammars/README.md
/// 核心思路：`root` 产生 JSON 对象，每个键按 `FieldType` 生成对应的 value 文法规则。
/// 文法只约束结构（JSON 格式），不约束语义（值由模型从 OCR 文本中抽取）。
public enum GBNFGrammarGenerator {

    // MARK: - 公共 API

    /// 从 ExtractionSpec 生成完整的 GBNF 文法字符串。
    public static func generate(for spec: ExtractionSpec) -> String {
        var rules: [String] = []

        let sharedKeys = spec.shared.map(\.key)
        let rowKeys = spec.row.map(\.key)

        // shared 字段作为顶层键（sharedKeys 与 spec.shared 同序——zip 直取，
        // 免 field(for:) 逐键线性查找与强制解包）
        var rootElements: [String] = []
        for (key, field) in zip(sharedKeys, spec.shared) {
            rootElements.append(" \"\(key)\" : " + valueRuleName(for: field))
        }
        // rows 可选数组
        if !rowKeys.isEmpty {
            rootElements.append(" \"rows\" : [ " + rowObject(spec: spec) + " ]")
        }
        rules.append("root ::= \"{\" \(rootElements.joined(separator: ","))  \"}\"")

        // 为每个 field 类型生成 value 规则
        for field in spec.fields {
            rules.append(valueRuleDefinition(for: field))
        }

        // ws 规则（空白）
        rules.append("ws ::= [ \\t\\n]*")

        // 字符串内容规则
        rules.append("str-char ::= [^\"\\\\\\u0000-\\u001F]")
        rules.append("str ::= \"\\\"\" str-char* \"\\\"\"")

        // 数字规则
        rules.append("digit ::= [0-9]")
        rules.append("number ::= \"-\"? digit+ (\".\" digit+)?")

        // 日期规则
        rules.append("date-str ::= digit digit digit digit [\\-/] digit digit [\\-/] digit digit")

        return rules.joined(separator: "\n") + "\n"
    }

    // MARK: - 内部规则生成

    private static func valueRuleName(for field: FieldSpec) -> String {
        "value-\(field.key)"
    }

    private static func valueRuleDefinition(for field: FieldSpec) -> String {
        let name = valueRuleName(for: field)
        switch field.type {
        case .text, .narrative:
            return "\(name) ::= str"
        case .number:
            return "\(name) ::= number"
        case .date:
            return "\(name) ::= str | \"\\\"\" date-str \"\\\"\""
        case .quantityWithUnit:
            return "\(name) ::= str"
        case .enumerated:
            return "\(name) ::= str"
        }
    }

    private static func rowObject(spec: ExtractionSpec) -> String {
        let elements = spec.row.map { field in
            "\"\(field.key)\" : " + valueRuleName(for: field)
        }
        return "\"{\" \(elements.joined(separator: ", ")) \"}\""
    }

    // MARK: - 快捷方法

    /// 为所有已注册的 spec 生成文法，返回字典 [kind: gbnfString]。
    public static func generateAll() -> [String: String] {
        var result: [String: String] = [:]
        for spec in ExtractionSpecRegistry.specs {
            result[spec.kind] = generate(for: spec)
        }
        return result
    }
}
