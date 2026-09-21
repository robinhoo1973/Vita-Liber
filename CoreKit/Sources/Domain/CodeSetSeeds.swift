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
///
/// V2 扩充（2026-09-21，mirobody 审计轮 / FR25.12⑬ 词表证据层）：
/// - 新增 `lexiconTerms`（词表锚定术语：药名/剂型/给药途径/频次）——来源 = 自编
///   curated 公开通用名 + mirobody `res/dose_forms.tsv` 设计参考（Apache-2.0，
///   仅作参考登记，未拷贝其文件）、TFDA `res/medication_names.tsv` 设计参考；
/// - 药名词表 **不携标准码**（RxNorm/SNOMED 许可后经 `concept_id` 只补不覆）；
/// - 别名补语区行（zh-Hant-TW / zh-Hant-HK）与药名区域用词（如 乙醯胺酚/撲熱息痛）；
/// - 标准码/单位扩充仍以官方 LOINC/UCUM 发行件为准（`scripts/build-code-sets.sh`）。
public enum CodeSetSeeds {

    public static let bundleVersion = "p0.5.2-seeds-2026-09-21"

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

    /// 词表锚定术语（V2，2026-09-21）：识别侧匹配词汇——非编码，仅匹配建议。
    /// `category` 取值 = `lexicon_term.category` CHECK 词汇（单一事实源）。
    public struct SeedLexiconTerm: Sendable, Equatable {
        public var term: String
        public var locale: String          // zh-Hans / zh-Hant / zh-Hant-TW / zh-Hant-HK / en
        public var category: String        // medication / drug_form / route / frequency
        public var priority: Int
        public init(term: String, locale: String, category: String, priority: Int = 0) {
            self.term = term; self.locale = locale
            self.category = category; self.priority = priority
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
        // V2 语区行（2026-09-21）：区域用词单独成行（区域精确行恒胜通用行）——
        // TW：血紅素；HK：血色素；簡体字面无区域歧义的不重复登记。
        SeedAlias(aliasText: "血紅素", locale: "zh-Hant-TW", conceptId: "c-hgb", priority: 1),
        SeedAlias(aliasText: "血色素", locale: "zh-Hant-HK", conceptId: "c-hgb", priority: 1),
        SeedAlias(aliasText: "總膽固醇", locale: "zh-Hant-TW", conceptId: "c-chol-mass"),
        SeedAlias(aliasText: "總膽固醇", locale: "zh-Hant-HK", conceptId: "c-chol-mass"),
        SeedAlias(aliasText: "blood sugar", locale: "en", conceptId: "c-glu-mass"),
        SeedAlias(aliasText: "fasting glucose", locale: "en", conceptId: "c-glu-fasting", priority: 1),
        SeedAlias(aliasText: "fasting blood sugar", locale: "en", conceptId: "c-glu-fasting", priority: 1),
        SeedAlias(aliasText: "haemoglobin", locale: "en", conceptId: "c-hgb"),
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

    // MARK: - V2 词表锚定术语（FR25.12⑬；来源与许可见文件头）

    /// 词表锚定术语全集：剂型 → 途径 → 频次 → 常见药名。
    ///
    /// 纪律：
    /// - 词条只作**匹配词汇**（D 级建议的去向由用户裁决，BR-003）；
    /// - 药名以公开通用名（INN/国标通用名）自编 curated，不含商品名猜测；
    /// - 区域用词单列（TW/HK），不合并成一条（区域精确恒胜通用，FR25.1 补注）。
    public static let lexiconTerms: [SeedLexiconTerm] = [
        // —— 剂型（drug_form）——
        SeedLexiconTerm(term: "片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "膠囊", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "胶囊", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "颗粒", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "顆粒", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "缓释片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "緩釋片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "控释片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "控釋片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "咀嚼片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "泡腾片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "泡騰片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "分散片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "肠溶片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "腸溶片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "肠溶胶囊", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "腸溶膠囊", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "注射液", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "注射液", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "滴眼液", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "滴眼液", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "滴鼻液", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "滴劑", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "滴剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "口服液", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "口服液", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "糖浆", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "糖漿", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "混悬液", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "混懸液", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "乳膏", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "乳膏", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "软膏", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "軟膏", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "凝胶", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "凝膠", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "栓剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "栓劑", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "贴剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "貼劑", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "贴片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "貼片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "喷雾剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "噴霧劑", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "气雾剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "氣霧劑", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "散剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "散劑", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "含片", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "含片", locale: "zh-Hant", category: "drug_form"),
        SeedLexiconTerm(term: "胶囊剂", locale: "zh-Hans", category: "drug_form"),
        SeedLexiconTerm(term: "tablet", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "tablets", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "capsule", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "capsules", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "granule", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "injection", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "syrup", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "suspension", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "ointment", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "cream", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "suppository", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "patch", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "spray", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "drops", locale: "en", category: "drug_form"),
        SeedLexiconTerm(term: "lozenge", locale: "en", category: "drug_form"),

        // —— 给药途径（route）——
        SeedLexiconTerm(term: "口服", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "口服", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "外用", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "外用", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "静脉滴注", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "靜脈滴注", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "静脉注射", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "靜脈注射", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "肌肉注射", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "肌肉注射", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "皮下注射", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "皮下注射", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "舌下含服", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "舌下含服", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "吸入", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "吸入", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "雾化吸入", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "霧化吸入", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "滴眼", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "滴眼", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "滴鼻", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "滴鼻", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "直肠给药", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "直腸給藥", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "鼻饲", locale: "zh-Hans", category: "route"),
        SeedLexiconTerm(term: "鼻飼", locale: "zh-Hant", category: "route"),
        SeedLexiconTerm(term: "oral", locale: "en", category: "route"),
        SeedLexiconTerm(term: "intravenous", locale: "en", category: "route"),
        SeedLexiconTerm(term: "intramuscular", locale: "en", category: "route"),
        SeedLexiconTerm(term: "subcutaneous", locale: "en", category: "route"),
        SeedLexiconTerm(term: "sublingual", locale: "en", category: "route"),
        SeedLexiconTerm(term: "topical", locale: "en", category: "route"),
        SeedLexiconTerm(term: "inhalation", locale: "en", category: "route"),

        // —— 频次（frequency）——
        SeedLexiconTerm(term: "每日一次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日一次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日两次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日兩次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日三次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日三次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日四次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每日四次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每天一次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每天一次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每天两次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每天兩次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "一天一次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "一天一次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "一日一次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "一日三次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "一日三次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "隔日一次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "隔日一次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每周一次", locale: "zh-Hans", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "每週一次", locale: "zh-Hant", category: "frequency", priority: 1),
        SeedLexiconTerm(term: "睡前", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "睡前", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "晨起", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "晨起", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "饭前", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "飯前", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "饭后", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "飯後", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "空腹", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "空腹", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "必要时", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "必要時", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "每8小时", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "每8小時", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "每12小时", locale: "zh-Hans", category: "frequency"),
        SeedLexiconTerm(term: "每12小時", locale: "zh-Hant", category: "frequency"),
        SeedLexiconTerm(term: "once daily", locale: "en", category: "frequency"),
        SeedLexiconTerm(term: "twice daily", locale: "en", category: "frequency"),
        SeedLexiconTerm(term: "three times daily", locale: "en", category: "frequency"),
        SeedLexiconTerm(term: "as needed", locale: "en", category: "frequency"),
        SeedLexiconTerm(term: "as directed", locale: "en", category: "frequency"),

        // —— 常见药名（medication；公开通用名，自编 curated，无标准码）——
        // 对乙酰氨基酚：三种区域用词（CN 对乙酰氨基酚 / TW 乙醯胺酚 / HK 撲熱息痛）
        SeedLexiconTerm(term: "对乙酰氨基酚", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "對乙酰氨基酚", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "乙醯胺酚", locale: "zh-Hant-TW", category: "medication"),
        SeedLexiconTerm(term: "撲熱息痛", locale: "zh-Hant-HK", category: "medication"),
        SeedLexiconTerm(term: "acetaminophen", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "paracetamol", locale: "en", category: "medication"),
        // 阿司匹林：TW 阿斯匹靈 / HK 阿士匹靈
        SeedLexiconTerm(term: "阿司匹林", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿司匹林", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "阿斯匹靈", locale: "zh-Hant-TW", category: "medication"),
        SeedLexiconTerm(term: "阿士匹靈", locale: "zh-Hant-HK", category: "medication"),
        SeedLexiconTerm(term: "aspirin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "布洛芬", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "布洛芬", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "ibuprofen", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "阿莫西林", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿莫西林", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "amoxicillin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "阿奇霉素", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿奇黴素", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "azithromycin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "头孢呋辛", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "頭孢呋辛", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "cefuroxime", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "左氧氟沙星", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "左氧氟沙星", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "levofloxacin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "甲硝唑", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "甲硝唑", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "metronidazole", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "氟康唑", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "氟康唑", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "fluconazole", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "奥司他韦", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "奧司他韋", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "oseltamivir", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "二甲双胍", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "二甲雙胍", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "metformin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "格列美脲", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "格列美脲", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "glimepiride", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "阿卡波糖", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿卡波糖", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "acarbose", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "西格列汀", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "西格列汀", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "sitagliptin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "胰岛素", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "胰島素", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "insulin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "氨氯地平", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "氨氯地平", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "amlodipine", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "硝苯地平", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "硝苯地平", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "nifedipine", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "氯沙坦", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "氯沙坦", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "losartan", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "缬沙坦", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "纈沙坦", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "valsartan", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "厄贝沙坦", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "厄貝沙坦", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "irbesartan", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "美托洛尔", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "美托洛爾", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "metoprolol", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "比索洛尔", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "比索洛爾", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "bisoprolol", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "卡维地洛", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "卡維地洛", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "carvedilol", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "氢氯噻嗪", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "氫氯噻嗪", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "hydrochlorothiazide", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "吲达帕胺", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "吲達帕胺", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "indapamide", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "呋塞米", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "呋塞米", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "furosemide", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "螺内酯", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "螺內酯", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "spironolactone", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "阿托伐他汀", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿托伐他汀", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "atorvastatin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "瑞舒伐他汀", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "瑞舒伐他汀", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "rosuvastatin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "辛伐他汀", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "辛伐他汀", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "simvastatin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "依折麦布", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "依折麥布", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "ezetimibe", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "氯吡格雷", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "氯吡格雷", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "clopidogrel", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "华法林", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "華法林", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "warfarin", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "利伐沙班", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "利伐沙班", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "rivaroxaban", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "奥美拉唑", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "奧美拉唑", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "omeprazole", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "泮托拉唑", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "泮托拉唑", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "pantoprazole", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "雷贝拉唑", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "雷貝拉唑", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "rabeprazole", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "氯雷他定", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "氯雷他定", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "loratadine", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "西替利嗪", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "西替利嗪", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "cetirizine", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "孟鲁司特", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "孟魯司特", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "montelukast", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "布地奈德", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "布地奈德", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "budesonide", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "沙丁胺醇", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "沙丁胺醇", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "salbutamol", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "albuterol", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "泼尼松", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "潑尼松", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "prednisone", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "甲泼尼龙", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "甲潑尼龍", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "methylprednisolone", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "左甲状腺素", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "左甲狀腺素", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "levothyroxine", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "阿仑膦酸钠", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿侖膦酸鈉", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "alendronate", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "阿普唑仑", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "阿普唑侖", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "alprazolam", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "劳拉西泮", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "勞拉西泮", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "lorazepam", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "舍曲林", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "舍曲林", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "sertraline", locale: "en", category: "medication"),
        SeedLexiconTerm(term: "艾司西酞普兰", locale: "zh-Hans", category: "medication"),
        SeedLexiconTerm(term: "艾司西酞普蘭", locale: "zh-Hant", category: "medication"),
        SeedLexiconTerm(term: "escitalopram", locale: "en", category: "medication"),
    ]
}
