import Foundation
import Domain

/// F16 信源库（FR16.4）——**医学数字单一事实源**。
///
/// 为什么是「编译期常量 + 数据库承载」而不是 JSON 资源文件：
/// - 离线零网络是硬约束，编译进包的常量天然离线、不可被热更篡改；
/// - 阈值数字照抄原文、禁止改写——类型安全（Double）优于手改 JSON；
/// - 与 `SchemaV2.ddl` 的「schema-as-code」同纪律：可 grep、可 diff、可门禁断言。
///
/// **准入纪律（FR16.4）**：仅国家级学会指南/政府卫生机构/WHO/AHA/ESC。
/// **发布前评审闸门（FR16.4/L3 阈值清单上线前评审）**：下列数值为**工程占位值**，
/// 在医疗顾问逐条评审通过前不得上架——测试断言中已锁定该闸门的存在。
/// 任何模块不得私设第二套医学数值；本库缺失的指标 = 范围不可用（独立渲染态），
/// 绝不臆造阈值。
public enum GuidelineSource {

    /// 内置信源条目（B 级缺省）。每条：权威出处 + 版本 + 检查日期 + 阈值。
    public static let bundledSeeds: [GuidelineEntry] = [
        GuidelineEntry(
            title: "中国 2 型糖尿病防治指南", org: "中华医学会糖尿病学分会",
            year: 2020, clauseRef: "表 3 血糖控制目标",
            citationUrl: "https://guide.medlive.cn/guideline/2020-cds-t2dm",
            version: "2020", checkedAt: Date(timeIntervalSince1970: 1_753_000_000),
            metricKey: "glucose", unit: "mmol/L",
            l1Low: 3.9, l1High: 7.0, l2High: 13.9, l3High: 16.7),
        GuidelineEntry(
            title: "中国高血压防治指南", org: "中国高血压联盟",
            year: 2018, clauseRef: "血压水平分类",
            citationUrl: "https://example.org/guideline/hypertension-2018",
            version: "2018 修订版", checkedAt: Date(timeIntervalSince1970: 1_753_000_000),
            metricKey: "blood_pressure_sys", unit: "mmHg",
            l1High: 140, l2High: 160, l3High: 180),
        GuidelineEntry(
            title: "AHA 血氧与心率参考", org: "American Heart Association",
            year: 2021, clauseRef: "Oxygen Saturation and Pulse",
            citationUrl: "https://www.heart.org/en/health-topics",
            version: "2021", checkedAt: Date(timeIntervalSince1970: 1_753_000_000),
            metricKey: "blood_oxygen", unit: "%",
            l1Low: 94, l2Low: 90, l3Low: 85),
    ]

    /// **发布前评审闸门**：L3 阈值清单未经医疗顾问逐条评审前，App 不得上架。
    /// 测试断言存在此常量，而非其值——值由医疗评审流程写入。
    public static let thresholdsAwaitMedicalReview = true

    /// 指标 → 阈值 JSON（`guideline_source.thresholds_json` 的存储形态）。
    /// 用 JSON 而非逐列承载：阈值档位随指南版本演进而变（现在 L1-L3，
    /// 将来可能增补），单一 JSON 列让「版本升级」变成整条替换而非 ALTER。
    public struct Thresholds: Codable, Sendable, Equatable {
        public var l1Low: Double?
        public var l1High: Double?
        public var l2Low: Double?
        public var l2High: Double?
        public var l3Low: Double?
        public var l3High: Double?
        public init(l1Low: Double? = nil, l1High: Double? = nil,
                    l2Low: Double? = nil, l2High: Double? = nil,
                    l3Low: Double? = nil, l3High: Double? = nil) {
            self.l1Low = l1Low; self.l1High = l1High
            self.l2Low = l2Low; self.l2High = l2High
            self.l3Low = l3Low; self.l3High = l3High
        }
        public static func from(_ entry: GuidelineEntry) -> Thresholds {
            Thresholds(l1Low: entry.l1Low, l1High: entry.l1High,
                       l2Low: entry.l2Low, l2High: entry.l2High,
                       l3Low: entry.l3Low, l3High: entry.l3High)
        }
        public func applying(to entry: GuidelineEntry) -> GuidelineEntry {
            var e = entry
            e.l1Low = l1Low; e.l1High = l1High
            e.l2Low = l2Low; e.l2High = l2High
            e.l3Low = l3Low; e.l3High = l3High
            return e
        }
    }
}
