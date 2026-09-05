import Foundation

/// F25 医学数据标准化引擎（ADR-028 / tech-spec §5.52）——Domain 纯函数与值类型。
///
/// 分层纪律：本文件只有 Foundation（L0 门禁 [5]）；存储端口 `CodeIndex`/`UnitIndex`
/// 定义于 Domain（FullTextSearch 先例：Domain 自声明所需端口，Infrastructure 注入实现）；
/// 码表是存储端口不是可替换引擎，不占 EAL/EngineRegistry（ADR-028）。
///
/// 红线（FR25.1）：**绝不猜码**——无命中即 nil，不存在「最接近」的静默匹配。

// MARK: - 值类型

public enum CodingSystem: String, Sendable, Codable {
    // rawValue = SQL CHECK 词汇（码表表 coding_system CHECK 单一事实源；
    // rawValue 只存在于 SQL 边界，改这里必须同步 §4.3 DDL）
    case loinc
    case snomedCT = "snomed_ct"
    case rxNorm = "rxnorm"
}

public enum CodeKind: String, Sendable, Codable {
    case metric, medication
    case observationKind = "observation_kind"
    case other
}

/// FR25.1 命中路由（解析链优先级自高到低：override > curated > fold）。
/// manual = 用户手输/确认时人工指定（不走解析链）。
public enum MatchRoute: String, Sendable, Codable {
    case override, curated, fold, manual
}

public struct CodeResolution: Sendable, Equatable, Codable {
    public var conceptId: String
    public var canonicalCode: String           // 如 718-7
    public var codingSystem: CodingSystem
    /// 码表数据，非 UI 文案（L10n 门禁豁免，GuidelineSource 先例——display 仅供
    /// 技术性展示与测试断言，呈现文案出口仍是 L10n）
    public var displayZhHans: String
    public var displayEn: String
    public var kind: CodeKind
    public var canonicalUnit: String?          // code_concept.canonical_unit，FR25.2 换算目标
    public var matchedVia: MatchRoute          // FR25.1 命中路由可查
    public var confidence: Double              // fold 置信度低于 curated（FR25.1）

    public init(conceptId: String, canonicalCode: String, codingSystem: CodingSystem,
                displayZhHans: String, displayEn: String, kind: CodeKind,
                canonicalUnit: String?, matchedVia: MatchRoute, confidence: Double) {
        self.conceptId = conceptId
        self.canonicalCode = canonicalCode
        self.codingSystem = codingSystem
        self.displayZhHans = displayZhHans
        self.displayEn = displayEn
        self.kind = kind
        self.canonicalUnit = canonicalUnit
        self.matchedVia = matchedVia
        self.confidence = confidence
    }
}

public struct ResolvedReading: Sendable, Equatable, Codable {
    public var resolution: CodeResolution?      // nil = 未解析（D 徽章保留原文，FR25.4）
    public var canonicalUnit: String?           // UCUM 规范单位
    /// 换算建议值；nil = 无法换算（原值保留）。仅作标准化建议输出——入库仍存
    /// 原值+原单位，换算只在查询/渲染层执行（FR7.8 铁律延伸，FR25.2）
    public var canonicalValue: Double?
    public var rawText: String                  // 原始名/值/单位三件保真（FR25.4）
    public var rawValue: String
    public var rawUnit: String

    public init(resolution: CodeResolution?, canonicalUnit: String?,
                canonicalValue: Double?, rawText: String, rawValue: String, rawUnit: String) {
        self.resolution = resolution
        self.canonicalUnit = canonicalUnit
        self.canonicalValue = canonicalValue
        self.rawText = rawText
        self.rawValue = rawValue
        self.rawUnit = rawUnit
    }
}

public struct AliasHit: Sendable, Equatable {
    public var conceptId: String
    public var route: MatchRoute
    public var priority: Int

    public init(conceptId: String, route: MatchRoute, priority: Int) {
        self.conceptId = conceptId
        self.route = route
        self.priority = priority
    }
}

public struct UcumUnit: Sendable, Equatable {
    public var unitCode: String
    public var family: String
    public var dimension: String
    public var factor: Double                  // 相对族基单位的换算因子（unitBase = v*factor + offset）
    public var offset: Double
    public var kind: String                    // simple/arithmetic

    public init(unitCode: String, family: String, dimension: String,
                factor: Double, offset: Double, kind: String) {
        self.unitCode = unitCode
        self.family = family
        self.dimension = dimension
        self.factor = factor
        self.offset = offset
        self.kind = kind
    }
}

/// 摩尔质量桥接（FR25.3）：跨量纲换算按指标编码查找（ucum_molar_bridge 表）——
/// 同一物质的摩尔质量因物质而异，必须按编码取值，不得按单位族推断。
public struct UcumMolarBridge: Sendable, Equatable {
    public var conceptId: String
    public var fromUnit: String
    public var toUnit: String
    public var factor: Double                  // toUnit 值 = fromUnit 值 × factor
    public var note: String                    // 来源留痕（摩尔质量出处）

    public init(conceptId: String, fromUnit: String, toUnit: String, factor: Double, note: String) {
        self.conceptId = conceptId
        self.fromUnit = fromUnit
        self.toUnit = toUnit
        self.factor = factor
        self.note = note
    }
}

// MARK: - 存储端口（Domain 自声明；Infrastructure GRDBCodeIndex 实现）

/// 实现纪律：override 恒先于 curated，curated 恒先于 fold（FR25.1 链序由
/// CodeResolver 统一施加——实现只需如实返回命中，不得自行排序过滤）。
public protocol CodeIndex: Sendable {
    func overrideHit(_ raw: String) async throws -> AliasHit?
    func resolveAlias(_ raw: String, locale: Locale) async throws -> [AliasHit]
    func concept(_ id: String) async throws -> CodeResolution?
    /// FR25.2 单位参与定码：同物质按单位选特异编码（如 glucose mg/dL→2345-7、
    /// mmol/L→14749-6）。数据落点复用 code_map 桥表
    /// （source_system='loinc-unit'，source_code='<conceptId>|<unit>'）。
    func unitSpecificConcept(conceptId: String, unit: String) async throws -> CodeResolution?
}

public protocol UnitIndex: Sendable {
    func unit(_ code: String) async throws -> UcumUnit?
    func molarBridge(from: String, to: String, conceptId: String) async throws -> UcumMolarBridge?
}

// MARK: - BR 纯函数

public enum CodeResolver {
    /// 解析链权重（FR25.1）：override 由 overrideHit 单独先行；curated 恒高于 fold。
    static func routeWeight(_ route: MatchRoute) -> Int {
        switch route {
        case .override: return 3
        case .manual: return 2   // manual 只在构造 CodeResolution 时使用，不出现在别名命中里
        case .curated: return 2
        case .fold: return 1
        }
    }

    /// fold 置信度低于 curated（FR25.1 展示可标「简繁转换」）。
    public static func confidence(_ route: MatchRoute) -> Double {
        switch route {
        case .override, .manual: return 1.0
        case .curated: return 0.95
        case .fold: return 0.6
        }
    }

    /// FR25.1 术语解析。红线：绝不猜码——空输入/无命中即 nil；
    /// 带修饰词的查询（「血红蛋白（贫血待查）」）不会命中任何别名行，自然返回 nil。
    public static func resolve(_ raw: String, locale: Locale,
                               index: any CodeIndex) async throws -> CodeResolution? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // 链序 ①：人工覆盖表（人写的行永远胜过表面匹配）
        if let hit = try await index.overrideHit(cleaned) {
            if var concept = try await index.concept(hit.conceptId) {
                concept.matchedVia = .override
                concept.confidence = confidence(.override)
                return concept
            }
        }
        // 链序 ②③：curated 别名 > fold 兜底（路由权重先于优先级——
        // FR25.1「curated 恒高于 fold」是硬链序，任何 fold 行无论 priority
        // 多大都不得越过 curated；同路由内再按 priority 取高）
        let hits = try await index.resolveAlias(cleaned, locale: locale)
        guard let best = hits.max(by: {
            (routeWeight($0.route), $0.priority) < (routeWeight($1.route), $1.priority)
        }) else { return nil }
        guard var concept = try await index.concept(best.conceptId) else { return nil }
        concept.matchedVia = best.route
        concept.confidence = confidence(best.route)
        return concept
    }

    /// FR25.2 读数解析：名称+数值+单位联合解析——单位参与决定编码。
    /// canonicalValue 仅在原值可解析为数值且可换算时产出；否则 nil（原值保留）。
    public static func resolveReading(raw: String, value: String, unit: String, locale: Locale,
                                      index: any CodeIndex,
                                      units: any UnitIndex) async throws -> ResolvedReading {
        let cleanedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolution = try await resolve(raw, locale: locale, index: index)

        // 单位参与定码（FR25.2）：同物质存在单位特异编码时按单位重选
        if let base = resolution {
            if let specific = try await index.unitSpecificConcept(
                conceptId: base.conceptId, unit: cleanedUnit) {
                var selected = specific
                selected.matchedVia = base.matchedVia
                selected.confidence = base.confidence
                resolution = selected
            }
        }

        var canonicalValue: Double?
        // 严格解析：不做逗号归一化——「1,200」是千分位还是小数逗号无法判别，
        // 猜错即产出错误医学数值。解析失败 = nil（原值保留，绝不静默近似）。
        if let parsed = Double(value),
           let res = resolution, let targetUnit = res.canonicalUnit,
           let conversion = try await UcumRules.convert(parsed, from: cleanedUnit, to: targetUnit,
                                                        units: units, conceptId: res.conceptId) {
            canonicalValue = conversion.convert(parsed)
        }
        return ResolvedReading(resolution: resolution,
                               canonicalUnit: resolution?.canonicalUnit,
                               canonicalValue: canonicalValue,
                               rawText: raw, rawValue: value, rawUnit: unit)
    }
}

public enum UcumRules {
    /// 单位族换算（同量纲 factor+offset，支持 ℃/℉ 类仿射换算）+ 摩尔质量桥接
    /// （跨量纲按 conceptId 查找）。非线性 UCUM（pH/log 等）不入 ucum_unit 表
    /// → 返回 nil = 无法换算（保留原值，FR25.3 边界）。
    /// 返回值复用 TrendService.UnitConversion 留痕语义（原值+规则，FR7.2/FR7.8 铁律延伸）。
    /// 换算恒为仿射 out = v*factor + offset——不除以输入值（v=0 安全）。
    public static func convert(_ v: Double, from: String, to: String,
                               units: any UnitIndex,
                               conceptId: String?) async throws -> UnitConversion? {
        guard from != to else { return nil }   // 同单位无换算动作
        // 同量纲：族内因子/偏移换算（unitBase = v*factor + offset）
        // out = v*(f_from/f_to) + (o_from - o_to)/f_to —— 系数与 v 无关，v=0 无除零
        if let uf = try await units.unit(from), let ut = try await units.unit(to),
           uf.family == ut.family {
            return UnitConversion(fromUnit: from, toUnit: to,
                                  factor: uf.factor / ut.factor,
                                  offset: (uf.offset - ut.offset) / ut.factor,
                                  note: "UCUM 族内换算（\(uf.family)）")
        }
        // 跨量纲：摩尔桥接（必须按指标编码，不得按单位族推断）
        if let cid = conceptId,
           let bridge = try await units.molarBridge(from: from, to: to, conceptId: cid) {
            return UnitConversion(fromUnit: from, toUnit: to,
                                  factor: bridge.factor, offset: 0, note: bridge.note)
        }
        return nil
    }
}

// MARK: - FR25.12 四处负清单（不引码场景——单一事实源，接线审查以此为准）

/// 全仓「不得引入 F25 编码」的场景负清单（FR25.12）：这些场景的数据是自由文本
/// 或本产品自有枚举，引入标准编码只会制造错误编码/无意义映射。
public enum StandardizationNoGoScene: String, Sendable, CaseIterable {
    case documentTag        // F5 文档标签（自由标签体系，非医学术语）
    case observationKind    // F8 观察类别（自有八类枚举，ObservationKind）
    case storageLocation    // F9 存放位置（家庭空间语义，非医学概念）
    case emergencyRelation  // F15 紧急卡关系（人伦关系，非医学概念）
}
