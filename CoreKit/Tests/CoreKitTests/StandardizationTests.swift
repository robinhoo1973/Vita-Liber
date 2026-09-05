import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// F25 医学数据标准化引擎 · Domain 层金样与红线用例
/// 绑定：`// binds: SU-M15-STD`（gate-suites.tsv / test-plan TC-M15-08——
/// 门禁 [8] 要求 token 出现在 @Suite 名中，贴标签≠接线）
@Suite("SU-M15-STD · F25 术语解析与 UCUM 换算（ADR-028/§5.52）")
struct StandardizationTests {

    // MARK: - 内存码表（CodeSetSeeds 的测试实现）

    /// 内存索引：直接消费 CodeSetSeeds——与生产 GRDBCodeIndex 消费同一份种子，
    /// 保证「金样通过的规则 = 生产加载的规则」。
    actor InMemoryCodeIndex: CodeIndex, UnitIndex {
        private let concepts: [String: CodeResolution]
        private let aliases: [String: [AliasHit]]
        private let overrides: [String: AliasHit]
        private let unitSpecific: [String: String]   // "<conceptId>|<unit>" -> targetConceptId
        private let units: [String: UcumUnit]
        private let bridges: [String: UcumMolarBridge]  // "<conceptId>|<from>|<to>"

        init() {
            var c: [String: CodeResolution] = [:]
            for s in CodeSetSeeds.concepts {
                c[s.id] = CodeResolution(conceptId: s.id, canonicalCode: s.canonicalCode,
                                         codingSystem: s.codingSystem,
                                         displayZhHans: s.displayZhHans, displayEn: s.displayEn,
                                         kind: s.kind, canonicalUnit: s.canonicalUnit,
                                         matchedVia: .curated, confidence: 1)
            }
            self.concepts = c
            var a: [String: [AliasHit]] = [:]
            for s in CodeSetSeeds.aliases {
                a[s.aliasText, default: []].append(
                    AliasHit(conceptId: s.conceptId, route: s.route, priority: s.priority))
            }
            self.aliases = a
            var o: [String: AliasHit] = [:]
            for s in CodeSetSeeds.overrides {
                o[s.queryPattern] = AliasHit(conceptId: s.conceptId, route: .override, priority: 0)
            }
            self.overrides = o
            var u: [String: String] = [:]
            for s in CodeSetSeeds.unitSpecific {
                u["\(s.conceptId)|\(s.unit)"] = s.targetConceptId
            }
            self.unitSpecific = u
            var us: [String: UcumUnit] = [:]
            for s in CodeSetSeeds.ucumUnits {
                us[s.unitCode] = UcumUnit(unitCode: s.unitCode, family: s.family,
                                          dimension: s.dimension, factor: s.factor,
                                          offset: s.offset, kind: s.kind)
            }
            self.units = us
            var b: [String: UcumMolarBridge] = [:]
            for s in CodeSetSeeds.bridges {
                b["\(s.conceptId)|\(s.fromUnit)|\(s.toUnit)"] =
                    UcumMolarBridge(conceptId: s.conceptId, fromUnit: s.fromUnit,
                                    toUnit: s.toUnit, factor: s.factor, note: s.note)
            }
            self.bridges = b
        }

        func overrideHit(_ raw: String) async throws -> AliasHit? { overrides[raw] }
        func resolveAlias(_ raw: String, locale: Locale) async throws -> [AliasHit] { aliases[raw] ?? [] }
        func concept(_ id: String) async throws -> CodeResolution? { concepts[id] }
        func unitSpecificConcept(conceptId: String, unit: String) async throws -> CodeResolution? {
            guard let target = unitSpecific["\(conceptId)|\(unit)"] else { return nil }
            return concepts[target]
        }
        func unit(_ code: String) async throws -> UcumUnit? { units[code] }
        func molarBridge(from: String, to: String, conceptId: String) async throws -> UcumMolarBridge? {
            bridges["\(conceptId)|\(from)|\(to)"]
        }
    }

    private func makeIndex() -> InMemoryCodeIndex { InMemoryCodeIndex() }

    // MARK: - FR25.1 金样：四语言归一

    @Test func 四语言别名解析至同一LOINC718_7() async throws {
        let idx = makeIndex()
        for raw in ["血红蛋白", "血色素", "Hb", "ヘモグロビン"] {
            let r = try await CodeResolver.resolve(raw, locale: Locale(identifier: "zh-Hans"),
                                                   index: idx)
            #expect(r != nil, "「\(raw)」应解析命中")
            #expect(r?.canonicalCode == "718-7")
            #expect(r?.codingSystem == .loinc)
        }
    }

    @Test func 简繁折叠命中且置信度低于curated() async throws {
        let idx = makeIndex()
        // 血紅蛋白 = zh-Hant 脚本折叠产物（route=.fold）
        let folded = try await CodeResolver.resolve("血紅蛋白", locale: Locale(identifier: "zh-Hant"),
                                                    index: idx)
        #expect(folded?.canonicalCode == "718-7")
        #expect(folded?.matchedVia == .fold)
        let curated = try await CodeResolver.resolve("血红蛋白", locale: Locale(identifier: "zh-Hans"),
                                                     index: idx)
        #expect(curated?.matchedVia == .curated)
        #expect((folded?.confidence ?? 1) < (curated?.confidence ?? 0))
    }

    // MARK: - FR25.1 链序与不猜码

    @Test func 覆盖表优先于curated() async throws {
        let idx = makeIndex()
        // 「血红蛋白浓度」无别名行，仅覆盖表命中——人写的行胜过表面匹配
        let r = try await CodeResolver.resolve("血红蛋白浓度", locale: Locale(identifier: "zh-Hans"),
                                               index: idx)
        #expect(r?.canonicalCode == "718-7")
        #expect(r?.matchedVia == .override)
        #expect(r?.confidence == 1.0)
    }

    @Test func 带修饰词查询不猜码() async throws {
        let idx = makeIndex()
        // 「血红蛋白（贫血待查）」无任何别名/覆盖行——绝不返回「最接近」匹配
        let r = try await CodeResolver.resolve("血红蛋白（贫血待查）",
                                               locale: Locale(identifier: "zh-Hans"), index: idx)
        #expect(r == nil)
    }

    @Test func 空输入返回nil() async throws {
        let idx = makeIndex()
        let r = try await CodeResolver.resolve("   ", locale: Locale(identifier: "zh-Hans"),
                                               index: idx)
        #expect(r == nil)
    }

    // MARK: - FR25.2 单位参与定码

    @Test func 胆固醇单位参与定码() async throws {
        let idx = makeIndex()
        let molar = try await CodeResolver.resolveReading(
            raw: "total cholesterol", value: "5.0", unit: "mmol/L",
            locale: Locale(identifier: "en"), index: idx, units: idx)
        #expect(molar.resolution?.canonicalCode == "14647-2")
        #expect(molar.canonicalUnit == "mmol/L")
        let mass = try await CodeResolver.resolveReading(
            raw: "总胆固醇", value: "200", unit: "mg/dL",
            locale: Locale(identifier: "zh-Hans"), index: idx, units: idx)
        #expect(mass.resolution?.canonicalCode == "2093-3")
    }

    @Test func 血糖摩尔桥接换算与留痕() async throws {
        let idx = makeIndex()
        // 200 mg/dL ≈ 11.10 mmol/L（180.156 g/mol）
        let reading = try await CodeResolver.resolveReading(
            raw: "血糖", value: "200", unit: "mg/dL",
            locale: Locale(identifier: "zh-Hans"), index: idx, units: idx)
        #expect(reading.resolution?.canonicalCode == "2345-7")
        // canonicalUnit = mg/dL，同单位无需换算 → canonicalValue nil
        #expect(reading.canonicalValue == nil)
        // 显式 mg/dL→mmol/L：留痕换算（原值+规则）
        let conv = try await UcumRules.convert(200, from: "mg/dL", to: "mmol/L",
                                               units: idx, conceptId: "c-glu-mass")
        #expect(conv != nil)
        let expected = 200.0 * 10.0 / 180.156
        #expect(abs((conv?.convert(200) ?? 0) - expected) < 1e-9)
        #expect(conv?.note.contains("180.156") == true)
    }

    // MARK: - FR25.3 UCUM 族换算与非线性

    @Test func 同量纲族内换算留痕() async throws {
        let idx = makeIndex()
        // g/dL → g/L：factor 10
        let conv = try await UcumRules.convert(12.5, from: "g/dL", to: "g/L",
                                               units: idx, conceptId: nil)
        #expect(conv != nil)
        #expect(abs((conv?.convert(12.5) ?? 0) - 125.0) < 1e-9)
        #expect(conv?.fromUnit == "g/dL" && conv?.toUnit == "g/L")
    }

    @Test func 温度仿射换算() async throws {
        let idx = makeIndex()
        // 98.6°F → 37°C（factor+offset 族内换算）
        let conv = try await UcumRules.convert(98.6, from: "degF", to: "degC",
                                               units: idx, conceptId: nil)
        #expect(conv != nil)
        #expect(abs((conv?.convert(98.6) ?? 0) - 37.0) < 1e-9)
        // 零值安全：0°C → 32°F，且换算系数不除以输入值（v=0 无除零）
        let zero = try await UcumRules.convert(0, from: "degC", to: "degF",
                                               units: idx, conceptId: nil)
        #expect(abs((zero?.convert(0) ?? 0) - 32.0) < 1e-9)
    }

    @Test func 非线性单位返回nil保留原值() async throws {
        let idx = makeIndex()
        // pH 不入 ucum_unit 表（非线性函数，FR25.3 边界）
        let conv = try await UcumRules.convert(7.4, from: "pH", to: "mmol/L",
                                               units: idx, conceptId: "c-hgb")
        #expect(conv == nil)
    }

    @Test func 同单位无换算动作() async throws {
        let idx = makeIndex()
        let conv = try await UcumRules.convert(5, from: "mg/dL", to: "mg/dL",
                                               units: idx, conceptId: nil)
        #expect(conv == nil)
    }

    // MARK: - FR25.12⑦ 聚合键

    @Test func 聚合键编码优先无编码回落() {
        #expect(TrendRules.aggregationKey(metricKey: "glucose", codeConceptId: "c-glu-mass") == "c-glu-mass")
        #expect(TrendRules.aggregationKey(metricKey: "glucose", codeConceptId: nil) == "glucose")
        #expect(TrendRules.aggregationKey(metricKey: "blood_pressure_sys", codeConceptId: "") == "blood_pressure_sys")
    }

    // MARK: - FR6 草稿槽位向后兼容

    @Test func 草稿槽位默认空且旧JSON可解码() throws {
        // 旧档案 JSON 无 codeResolution 键——decodeIfPresent 兜底不丢数据
        let legacy = """
        {"id":"\(UUID().uuidString)","key":"drug_name","displayLabel":"药名",
         "rawText":"阿莫西林","value":"阿莫西林","confidence":0.9,
         "grade":"ocrUnconfirmed","revisionHistory":[]}
        """
        let field = try JSONDecoder().decode(CandidateField.self, from: Data(legacy.utf8))
        #expect(field.codeResolution == nil)
        #expect(field.rawText == "阿莫西林")
    }

    // MARK: - FR25.12 负清单

    @Test func 负清单四处齐全() {
        #expect(StandardizationNoGoScene.allCases.count == 4)
        #expect(StandardizationNoGoScene.allCases.contains(.documentTag))
        #expect(StandardizationNoGoScene.allCases.contains(.observationKind))
        #expect(StandardizationNoGoScene.allCases.contains(.storageLocation))
        #expect(StandardizationNoGoScene.allCases.contains(.emergencyRelation))
    }

    // MARK: - 审查修复锁定（V3.69 code-review 批）

    /// 审查发现 1：链序比较器曾以 priority 先于 route——任何 priority>0 的
    /// fold 行都会越过 curated（FR25.1「curated 恒高于 fold」破坏）。
    @Test func 链序路由权重先于优先级() async throws {
        struct CraftedIndex: CodeIndex, UnitIndex {
            func overrideHit(_ raw: String) async throws -> AliasHit? { nil }
            func resolveAlias(_ raw: String, locale: Locale) async throws -> [AliasHit] {
                [AliasHit(conceptId: "c-fold", route: .fold, priority: 10),
                 AliasHit(conceptId: "c-curated", route: .curated, priority: 0)]
            }
            func concept(_ id: String) async throws -> CodeResolution? {
                CodeResolution(conceptId: id, canonicalCode: "X-\(id)", codingSystem: .loinc,
                               displayZhHans: "x", displayEn: "x", kind: .metric,
                               canonicalUnit: nil, matchedVia: .curated, confidence: 1)
            }
            func unitSpecificConcept(conceptId: String, unit: String) async throws -> CodeResolution? { nil }
            func unit(_ code: String) async throws -> UcumUnit? { nil }
            func molarBridge(from: String, to: String, conceptId: String) async throws -> UcumMolarBridge? { nil }
        }
        let r = try await CodeResolver.resolve("血红蛋白", locale: Locale(identifier: "zh-Hans"),
                                               index: CraftedIndex())
        #expect(r?.conceptId == "c-curated", "fold 行 priority=10 不得越过 curated 行")
        #expect(r?.matchedVia == .curated)
    }

    /// 审查发现 3：mmol/L 读数经单位特异重选落到摩尔概念后，回换算必须可达。
    @Test func 摩尔概念读数回换算可达() async throws {
        let idx = makeIndex()
        let reading = try await CodeResolver.resolveReading(
            raw: "血糖", value: "5.0", unit: "mmol/L",
            locale: Locale(identifier: "zh-Hans"), index: idx, units: idx)
        #expect(reading.resolution?.canonicalCode == "14749-6")
        // 摩尔概念回 mg/dL：桥接行按摩尔概念键定（V3.69 审查修复补行）
        let conv = try await UcumRules.convert(5.0, from: "mmol/L", to: "mg/dL",
                                               units: idx, conceptId: "c-glu-molar")
        #expect(conv != nil)
        #expect(abs((conv?.convert(5.0) ?? 0) - 5.0 * 180.156 / 10.0) < 1e-9)
    }

    // MARK: - SQL 层静态契约（GRDB 运行时路径由 L1 macOS 执行；本批在 Linux
    // 上以 schema-as-code 纪律锁定契约——枚举词汇 ↔ DDL CHECK 单一事实源）

    /// 审查发现 2：枚举 rawValue 与 SQL CHECK 词汇曾分叉（snomedCT vs snomed_ct）。
    @Test func 枚举词汇与DDL_CHECK一致() {
        #expect(CodingSystem.snomedCT.rawValue == "snomed_ct")
        #expect(CodingSystem.rxNorm.rawValue == "rxnorm")
        #expect(CodeKind.observationKind.rawValue == "observation_kind")
        let ddl = SchemaV2.ddl
        #expect(ddl.contains("coding_system IN ('loinc','snomed_ct','rxnorm')"))
        #expect(ddl.contains("kind IN ('metric','medication','observation_kind','other')"))
        #expect(ddl.contains("route IN ('curated','fold')"))
    }

    /// 审查发现 4：SQL 层（六表 DDL / 迁移 v14 / 种子装载）运行时无 GRDB 可跑——
    /// 以静态契约断言锁定结构存在性与版本序列（GRDB 往返金样随 L1 执行，
    /// test-plan TC-M15-08 已注记）。
    @Test func 码表六表DDL与迁移v14静态契约() {
        let ddl = SchemaV2.ddl
        for table in ["code_concept", "code_alias", "code_map",
                      "resolver_override", "ucum_unit", "ucum_molar_bridge"] {
            #expect(ddl.contains("CREATE TABLE \(table)"), "baseline 缺表 \(table)")
        }
        #expect(ddl.contains("raw_label TEXT, code_concept_id TEXT REFERENCES code_concept(id)"))
        #expect(SchemaMigrations.latestVersion == 14)
        let v14 = SchemaMigrations.steps.first { $0.version == 14 }
        #expect(v14?.name == "terminology-tables")
        for table in ["code_concept", "code_alias", "code_map",
                      "resolver_override", "ucum_unit", "ucum_molar_bridge"] {
            #expect(v14?.sql.contains("CREATE TABLE IF NOT EXISTS \(table)") == true,
                    "迁移 v14 缺表 \(table)")
        }
        #expect(v14?.sql.contains("ALTER TABLE metric_sample ADD COLUMN raw_label") == true)
        #expect(v14?.sql.contains("ALTER TABLE metric_sample ADD COLUMN code_concept_id") == true)
    }
}
