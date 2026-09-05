import Foundation

/// F25 P0.5 内置码表种子（tech-spec §5.52 码表构建管线的最小内置子集）。
///
/// 为什么是「编译期常量」而不是 JSON 资源（GuidelineSource 同纪律）：
/// - 离线零网络是硬约束，编译进包的常量天然离线、可 grep、可 diff、可门禁断言；
/// - 编码/换算因子是医学数值级事实，类型安全（Double）优于手改 JSON。
///
/// 数值事实来源（2026-09-05 网络核验）：
/// - LOINC：718-7 血红蛋白 / 2345-7 血糖 mg/dL / 14749-6 血糖 mmol/L /
///   14771-0 空腹血糖 mmol/L / 2093-3 总胆固醇 mg/dL / 14647-2 总胆固醇 mmol/L；
/// - 摩尔质量：葡萄糖 180.156 g/mol、胆固醇 386.65 g/mol（mg/dL ↔ mmol/L：
///   mmol/L = mg/dL × 10 / 摩尔质量）。
///
/// 扩充纪律：本文件是 P0.5 起点子集——全量子集经 `scripts/build-code-sets.sh`
/// 切割（tech §5.52，体积预算 ≤10MB），扩充码表不得改动本文件既有条目
/// （已发布行只补不覆，FR25.11）。
public enum CodeSetSeeds {

    public static let bundleVersion = "p0.5-seeds-2026-09-05"

    public struct SeedConcept: Sendable, Equatable {
        public var id: String
        public var canonicalCode: String
        public var codingSystem: CodingSystem
        public var displayZhHans: String
        public var displayEn: String
        public var kind: CodeKind
        public var canonicalUnit: String?
        public init(id: String, canonicalCode: String, codingSystem: CodingSystem,
                    displayZhHans: String, displayEn: String, kind: CodeKind,
                    canonicalUnit: String?) {
            self.id = id; self.canonicalCode = canonicalCode
            self.codingSystem = codingSystem; self.displayZhHans = displayZhHans
            self.displayEn = displayEn; self.kind = kind; self.canonicalUnit = canonicalUnit
        }
    }

    public struct SeedAlias: Sendable, Equatable {
        public var aliasText: String
        public var locale: String
        public var conceptId: String
        public var route: MatchRoute
        public var priority: Int
        public init(aliasText: String, locale: String, conceptId: String,
                    route: MatchRoute = .curated, priority: Int = 0) {
            self.aliasText = aliasText; self.locale = locale
            self.conceptId = conceptId; self.route = route; self.priority = priority
        }
    }

    /// FR25.2 单位特异编码（落库为 code_map：source_system='loinc-unit'，
    /// source_code='<conceptId>|<unit>'）
    public struct SeedUnitSpecific: Sendable, Equatable {
        public var conceptId: String
        public var unit: String
        public var targetConceptId: String
        public init(conceptId: String, unit: String, targetConceptId: String) {
            self.conceptId = conceptId; self.unit = unit; self.targetConceptId = targetConceptId
        }
    }

    public struct SeedOverride: Sendable, Equatable {
        public var queryPattern: String
        public var conceptId: String
        public var note: String
        public init(queryPattern: String, conceptId: String, note: String) {
            self.queryPattern = queryPattern; self.conceptId = conceptId; self.note = note
        }
    }

    public struct SeedUcumUnit: Sendable, Equatable {
        public var unitCode: String
        public var family: String
        public var dimension: String
        public var factor: Double
        public var offset: Double
        public var kind: String
        public init(unitCode: String, family: String, dimension: String,
                    factor: Double, offset: Double = 0, kind: String = "simple") {
            self.unitCode = unitCode; self.family = family; self.dimension = dimension
            self.factor = factor; self.offset = offset; self.kind = kind
        }
    }

    public struct SeedBridge: Sendable, Equatable {
        public var conceptId: String
        public var fromUnit: String
        public var toUnit: String
        public var factor: Double
        public var note: String
        public init(conceptId: String, fromUnit: String, toUnit: String,
                    factor: Double, note: String) {
            self.conceptId = conceptId; self.fromUnit = fromUnit
            self.toUnit = toUnit; self.factor = factor; self.note = note
        }
    }

    public static let concepts: [SeedConcept] = [
        SeedConcept(id: "c-hgb", canonicalCode: "718-7", codingSystem: .loinc,
                    displayZhHans: "血红蛋白", displayEn: "Hemoglobin",
                    kind: .metric, canonicalUnit: "g/dL"),
        SeedConcept(id: "c-glu-mass", canonicalCode: "2345-7", codingSystem: .loinc,
                    displayZhHans: "血糖", displayEn: "Glucose",
                    kind: .metric, canonicalUnit: "mg/dL"),
        SeedConcept(id: "c-glu-molar", canonicalCode: "14749-6", codingSystem: .loinc,
                    displayZhHans: "血糖", displayEn: "Glucose (molar)",
                    kind: .metric, canonicalUnit: "mmol/L"),
        SeedConcept(id: "c-glu-fasting", canonicalCode: "14771-0", codingSystem: .loinc,
                    displayZhHans: "空腹血糖", displayEn: "Fasting glucose",
                    kind: .metric, canonicalUnit: "mmol/L"),
        SeedConcept(id: "c-chol-mass", canonicalCode: "2093-3", codingSystem: .loinc,
                    displayZhHans: "总胆固醇", displayEn: "Total cholesterol",
                    kind: .metric, canonicalUnit: "mg/dL"),
        SeedConcept(id: "c-chol-molar", canonicalCode: "14647-2", codingSystem: .loinc,
                    displayZhHans: "总胆固醇", displayEn: "Total cholesterol (molar)",
                    kind: .metric, canonicalUnit: "mmol/L"),
    ]

    public static let aliases: [SeedAlias] = [
        SeedAlias(aliasText: "血红蛋白", locale: "zh-Hans", conceptId: "c-hgb"),
        SeedAlias(aliasText: "血色素", locale: "zh-Hans", conceptId: "c-hgb"),
        SeedAlias(aliasText: "血紅素", locale: "zh-Hant", conceptId: "c-hgb"),
        SeedAlias(aliasText: "血紅蛋白", locale: "zh-Hant", conceptId: "c-hgb", route: .fold),
        SeedAlias(aliasText: "hemoglobin", locale: "en", conceptId: "c-hgb"),
        SeedAlias(aliasText: "Hb", locale: "en", conceptId: "c-hgb"),
        SeedAlias(aliasText: "ヘモグロビン", locale: "ja", conceptId: "c-hgb"),
        SeedAlias(aliasText: "血糖", locale: "zh-Hans", conceptId: "c-glu-mass"),
        SeedAlias(aliasText: "glucose", locale: "en", conceptId: "c-glu-mass"),
        SeedAlias(aliasText: "Glu", locale: "en", conceptId: "c-glu-mass"),
        SeedAlias(aliasText: "空腹血糖", locale: "zh-Hans", conceptId: "c-glu-fasting", priority: 1),
        SeedAlias(aliasText: "总胆固醇", locale: "zh-Hans", conceptId: "c-chol-mass"),
        SeedAlias(aliasText: "胆固醇", locale: "zh-Hans", conceptId: "c-chol-mass"),
        SeedAlias(aliasText: "total cholesterol", locale: "en", conceptId: "c-chol-mass"),
        SeedAlias(aliasText: "cholesterol", locale: "en", conceptId: "c-chol-mass"),
    ]

    public static let unitSpecific: [SeedUnitSpecific] = [
        SeedUnitSpecific(conceptId: "c-glu-mass", unit: "mmol/L", targetConceptId: "c-glu-molar"),
        SeedUnitSpecific(conceptId: "c-glu-molar", unit: "mg/dL", targetConceptId: "c-glu-mass"),
        SeedUnitSpecific(conceptId: "c-chol-mass", unit: "mmol/L", targetConceptId: "c-chol-molar"),
        SeedUnitSpecific(conceptId: "c-chol-molar", unit: "mg/dL", targetConceptId: "c-chol-mass"),
    ]

    public static let overrides: [SeedOverride] = [
        SeedOverride(queryPattern: "血红蛋白浓度", conceptId: "c-hgb",
                     note: "人写行覆盖：带修饰词的常见化验单写法，表面匹配易漏"),
    ]

    public static let ucumUnits: [SeedUcumUnit] = [
        SeedUcumUnit(unitCode: "g/L", family: "mass-per-volume", dimension: "M/L3", factor: 1),
        SeedUcumUnit(unitCode: "g/dL", family: "mass-per-volume", dimension: "M/L3", factor: 10),
        SeedUcumUnit(unitCode: "mg/dL", family: "mass-per-volume", dimension: "M/L3", factor: 0.01),
        SeedUcumUnit(unitCode: "mmol/L", family: "molar-per-volume", dimension: "N/L3", factor: 1),
        SeedUcumUnit(unitCode: "degC", family: "temperature", dimension: "Θ", factor: 1),
        SeedUcumUnit(unitCode: "degF", family: "temperature", dimension: "Θ",
                     factor: 5.0 / 9.0, offset: -160.0 / 9.0),
    ]

    /// 摩尔质量事实（2026-09-05 核验）：葡萄糖 180.156 g/mol、胆固醇 386.65 g/mol。
    /// 桥接行按「该读数解析落到的概念」键定：质量概念（mg/dL 规范）持双向行，
    /// 摩尔概念（mmol/L 规范，经单位特异重选得到）持回换算行——否则
    /// mmol/L 读数永远无法回显 mg/dL（FR25.3 换算能力对摩尔半区失效）。
    public static let bridges: [SeedBridge] = [
        SeedBridge(conceptId: "c-glu-mass", fromUnit: "mg/dL", toUnit: "mmol/L",
                   factor: 10.0 / 180.156, note: "葡萄糖摩尔质量 180.156 g/mol"),
        SeedBridge(conceptId: "c-glu-mass", fromUnit: "mmol/L", toUnit: "mg/dL",
                   factor: 180.156 / 10.0, note: "葡萄糖摩尔质量 180.156 g/mol"),
        SeedBridge(conceptId: "c-glu-molar", fromUnit: "mmol/L", toUnit: "mg/dL",
                   factor: 180.156 / 10.0, note: "葡萄糖摩尔质量 180.156 g/mol"),
        SeedBridge(conceptId: "c-chol-mass", fromUnit: "mg/dL", toUnit: "mmol/L",
                   factor: 10.0 / 386.65, note: "胆固醇摩尔质量 386.65 g/mol"),
        SeedBridge(conceptId: "c-chol-mass", fromUnit: "mmol/L", toUnit: "mg/dL",
                   factor: 386.65 / 10.0, note: "胆固醇摩尔质量 386.65 g/mol"),
        SeedBridge(conceptId: "c-chol-molar", fromUnit: "mmol/L", toUnit: "mg/dL",
                   factor: 386.65 / 10.0, note: "胆固醇摩尔质量 386.65 g/mol"),
    ]
}
