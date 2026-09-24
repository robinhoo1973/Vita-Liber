import Foundation

/// 子项目 F（2026-09-14）：GBNF 文法生成器——从 `ExtractionSpec` 的 `fields` 定义自动生成 llama.cpp GBNF 文法。
/// 纯 Domain、零依赖、确定性输出；T2 引擎用此文法约束模型 JSON 输出格式。
///
/// GBNF 格式参考：https://github.com/ggerganov/llama.cpp/blob/master/grammars/README.md
/// 形状：`root` 产生 `{"shared":[span…],"rows":[[span…]]}`，span = `{key,value,unit,lineIndex}`
/// （与 T2 解码器 `ModelSpanResult`、T1 `@Generable` 同一契约）；键以字符串枚举收窄到 spec 键集。
/// 文法只约束结构（JSON 格式与键域），不约束语义（值由模型从 OCR 文本中抽取，装配层再验 verbatim）。
public enum GBNFGrammarGenerator {

    // MARK: - 公共 API

    /// 从 `ExtractionSpec` 生成完整的 GBNF 文法字符串。
    ///
    /// **输出形状 = `ModelSpanResult`（2026-09-24 契约轮修复）**：T2 解码器（`LlamaCppExtractionEngine`
    /// 内 `JSONDecoder().decode(ModelSpanResult.self)`）与 T1 `@Generable` 消费的形状都是
    /// `{"shared":[{"key","value","unit","lineIndex"}],"rows":[[…span…]]}`；旧版文法生成
    /// 「字段键 → 字符串」对象（`{"drug_name":"…"}`），与解码器不同形——文法每次能生成、解码每次必失败，
    /// T2 因此对每个区域静默降级 T3。本版使文法与解码契约同形，并把键取值域按 scope 收窄
    /// （shared-key / row-key 字符串枚举），空 scope 收口为字面空数组。
    public static func generate(for spec: ExtractionSpec) -> String {
        var rules: [String] = []

        let sharedKeys = spec.shared.map(\.key)
        let rowKeys = spec.row.map(\.key)

        // root：与 ModelSpanResult 同形；空 scope 只允许字面空数组（该 scope 无键可填）。
        let sharedSection = sharedKeys.isEmpty
            ? #""\"shared\"" ":" "[" "]""#
            : #""\"shared\"" ":" "[" shared-span* "]""#
        let rowsSection = rowKeys.isEmpty
            ? #""\"rows\"" ":" "[" "]""#
            : #""\"rows\"" ":" "[" row-array* "]""#
        rules.append(#"root ::= "{" \#(sharedSection) "," \#(rowsSection) "}""#)

        // span 微形状（两 scope 同形，仅键域不同）。
        if !sharedKeys.isEmpty {
            rules.append(spanRule(name: "shared-span", keyRule: "shared-key"))
            rules.append("shared-key ::= " + keyAlternation(sharedKeys))
        }
        if !rowKeys.isEmpty {
            rules.append(#"row-array ::= "[" row-span+ "]""#)
            rules.append(spanRule(name: "row-span", keyRule: "row-key"))
            rules.append("row-key ::= " + keyAlternation(rowKeys))
        }

        // 值规则：value 一律逐字字符串（含日期/数字/枚举——都是原文子串，类型判定在装配后的校验层）。
        rules.append(#"unit ::= "null" | str"#)
        rules.append(#"line-index ::= digit+"#)
        rules.append(#"str ::= "\"" str-char* "\"""#)
        rules.append(#"str-char ::= [^"\\\u0000-\u001F]"#)
        rules.append(#"digit ::= [0-9]"#)

        // ws 规则：llama.cpp 文法匹配自动放行 token 间空白，此规则备而不用（与旧版保留一致）。
        rules.append(#"ws ::= [ \t\n]*"#)

        return rules.joined(separator: "\n") + "\n"
    }

    // MARK: - 内部规则生成

    /// span 对象微形状：四键固定顺序（key → value → unit → lineIndex），与 `ModelSpan` 编码形状一致。
    private static func spanRule(name: String, keyRule: String) -> String {
        #"\#(name) ::= "{" "\"key\"" ":" \#(keyRule) "," "\"value\"" ":" str "," "\"unit\"" ":" unit "," "\"lineIndex\"" ":" line-index "}""#
    }

    /// 键取值域枚举：`"\"a\"" | "\"b\"" | …`——小模型不得写出注册表外的键。
    private static func keyAlternation(_ keys: [String]) -> String {
        keys.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
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
