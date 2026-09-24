import Testing
import Foundation
@testable import Domain

/// 2026-09-24 契约轮：GBNF 文法必须与 T2 解码器（`ModelSpanResult`：`shared:[{key,value,unit,lineIndex}]`、
/// `rows:[[…]]`）同形——旧版生成「字段键→字符串」对象，文法可生成、解码必失败，T2 静默降级 T3。
/// 本套件按结构断言：根含 shared/rows 两数组、span 微形状四键齐全、键取值域收窄到 spec 键、
/// 空 scope 收口为字面空数组、字符串规则与旧版规则名不得残留。
@Suite("SU-CE-GBNF · 抽取文法形状（span 契约）")
struct GBNFGrammarGeneratorTests {

    private func prescription() throws -> ExtractionSpec {
        try #require(ExtractionSpecRegistry.spec(for: "prescription"), "prescription spec 必须存在")
    }

    @Test("根形状 = {\"shared\":[…],\"rows\":[[…]]}（与 ModelSpanResult 同形）")
    func rootShapeMatchesDecoder() throws {
        let g = GBNFGrammarGenerator.generate(for: try prescription())
        #expect(g.contains(#""\"shared\"" ":" "[" shared-span* "]""#), "shared 必须是 span 数组")
        #expect(g.contains(#""\"rows\"" ":" "[" row-array* "]""#), "rows 必须是行数组的数组")
        #expect(g.contains("shared-span ::= "), "shared span 规则必须存在")
        #expect(g.contains("row-array ::= "), "行数组规则必须存在")
        #expect(g.contains("row-span+"), "行内至少一个 span")
    }

    @Test("span 微形状四键：key/value/unit/lineIndex；unit 可空；lineIndex 非负整数")
    func spanMicroShape() throws {
        let g = GBNFGrammarGenerator.generate(for: try prescription())
        for literal in [#""\"key\""#, #""\"value\""#, #""\"unit\""#, #""\"lineIndex\""#] {
            #expect(g.contains(literal), "缺 span 键字面量 \(literal)")
        }
        #expect(g.contains(#"unit ::= "null" | str"#), "unit 必须可空")
        #expect(g.contains("line-index ::= digit+"), "lineIndex 必须是非负整数")
    }

    @Test("键取值域收窄：每个 spec 键都在对应 scope 的枚举里（shared-key / row-key）")
    func keysAreEnumerated() throws {
        let spec = try prescription()
        let g = GBNFGrammarGenerator.generate(for: spec)
        for key in spec.shared.map(\.key) {
            #expect(g.contains("\\\"\(key)\\\""), "shared 键 \(key) 未进文法枚举")
        }
        for key in spec.row.map(\.key) {
            #expect(g.contains("\\\"\(key)\\\""), "row 键 \(key) 未进文法枚举")
        }
        guard let sharedRange = g.range(of: "shared-key ::= "),
              let rowRange = g.range(of: "row-key ::= ") else {
            Issue.record("缺 shared-key / row-key 规则"); return
        }
        let sharedSection = String(g[sharedRange.lowerBound..<rowRange.lowerBound])
        #expect(sharedSection.contains("prescribed_at"))
        #expect(!sharedSection.contains("drug_name"), "行键不得混入 shared 枚举")
        let rowSection = String(g[rowRange.lowerBound...])
        #expect(rowSection.contains("drug_name"))
        #expect(!rowSection.contains("prescribed_at"), "共享键不得混入 row 枚举")
    }

    @Test("空 scope 收口：无 shared 的 spec（medication）只允许字面空数组")
    func emptySharedIsLiteralEmptyArray() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "medication"), "medication spec 必须存在")
        #expect(spec.shared.isEmpty, "测试前提：medication 共享字段为空")
        let g = GBNFGrammarGenerator.generate(for: spec)
        #expect(g.contains(#""\"shared\"" ":" "[" "]""#), "空 shared 必须是字面空数组")
        #expect(!g.contains("shared-key"), "shared 为空时不得残留 shared-key 规则")
        #expect(!g.contains("shared-span"), "shared 为空时不得残留 shared-span 规则")
    }

    @Test("无 row 的 spec（immunization）：rows 收口为字面空数组")
    func emptyRowsIsLiteralEmptyArray() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "immunization"), "immunization spec 必须存在")
        #expect(spec.row.isEmpty, "测试前提：immunization 行字段为空")
        let g = GBNFGrammarGenerator.generate(for: spec)
        #expect(g.contains(#""\"rows\"" ":" "[" "]""#), "空 rows 必须是字面空数组")
        #expect(!g.contains("row-key ::= "), "rows 为空时不得残留 row-key 规则")
        #expect(!g.contains("row-span"), "rows 为空时不得残留 row-span 规则")
    }

    @Test("str 字符类排除引号/反斜杠/控制字符；旧版 value-/date-str 规则不得残留")
    func stringRuleAndNoLegacyLeftovers() throws {
        let g = GBNFGrammarGenerator.generate(for: try prescription())
        #expect(g.contains(#"[^"\\\u0000-\u001F]"#), "str-char 排除表必须保留")
        #expect(!g.contains("value-"), "旧版「字段键→value 规则」残留")
        #expect(!g.contains("date-str"), "值统一走 str，日期专用规则应已移除")
    }

    @Test("generateAll 覆盖全部注册卡种且非空")
    func generateAllCoversRegistry() throws {
        let all = GBNFGrammarGenerator.generateAll()
        #expect(!ExtractionSpecRegistry.specs.isEmpty)
        for spec in ExtractionSpecRegistry.specs {
            let grammar = all[spec.kind]
            #expect(grammar != nil, "卡种 \(spec.kind) 缺文法")
            #expect(!(grammar ?? "").isEmpty, "卡种 \(spec.kind) 文法为空")
            #expect(grammar?.contains("root ::= ") == true, "卡种 \(spec.kind) 缺 root 规则")
        }
    }
}
