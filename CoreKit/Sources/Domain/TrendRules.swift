import Foundation

/// F7 趋势业务规则（结构轮 2026-09-15：自 TrendService.swift 迁出——模型与规则分开，
/// 文件不再冒名 `Service`；`resolveRange` 死代码已随迁移删除——生产路径全部走
/// `resolveBands`，优先级铁律由后者实现）。
public enum TrendRules {
    /// 软删排除（§5.29）：聚合默认 WHERE excluded=0；对照视图显示已排除点（保留原值可恢复）
    public static func visible(_ points: [TrendPoint]) -> [TrendPoint] {
        points.filter { !$0.excluded }
    }

    /// **FR7.2 铁律（一票否决）：不同医院的参考范围不得合并成一条正常带。**
    ///
    /// 从点集提取 A 级参考带：按 (来源标签, 下限, 上限) 去重，**不做任何跨来源的
    /// 取交集/取并集/取平均**——三家医院即三条带，哪怕区间数值恰好相同也按来源分开
    /// （来源是分组键，不是可省略的装饰；合并会让用户误以为存在统一"正常值"）。
    ///
    /// 优先级（FR16.4）：只要存在 A 级带，就**不**混入 B 级信源库缺省带——
    /// A/B 混排等价于用 B 级替代医院原文，是 FR16.4 明令禁止的。
    /// 无任何 A 级带时才回落 B 级；两者皆无返回空数组（= 范围不可用）。
    public static func resolveBands(points: [TrendPoint],
                                    libraryFallback: ReferenceBand? = nil) -> [ReferenceBand] {
        var seen = Set<String>()
        var bands: [ReferenceBand] = []
        for p in points {
            guard let lo = p.refLow, let hi = p.refHigh else { continue }
            // 来源标签缺失时保留空串（数据缺失如实表达），不臆造文案——
            // 审查修复（V3.68 §11 清偿残根）：原实现 Domain 硬编码简体
            // 「未标注来源」直接上屏（zh-Hant/en 用户直见简体），展示缺省
            // 文案由 App 层经 L10n.trendBandUnlabeled 渲染；空串与有标签
            // 来源绝不合并（分组键不同）。
            let source = p.refSourceLabel?.trimmingCharacters(in: .whitespaces) ?? ""
            let band = ReferenceBand(sourceLabel: source, lower: lo, upper: hi, grade: .A)
            if seen.insert(band.id).inserted { bands.append(band) }
        }
        if bands.isEmpty, let fallback = libraryFallback, fallback.grade == .B {
            return [fallback]
        }
        // 稳定输出：按来源名排序，保证渲染顺序与图例顺序一致、快照可复现
        return bands.sorted { $0.sourceLabel < $1.sourceLabel }
    }

    /// 换算留痕：换算只发生在查询层，原值不动；换算后渲染「换算自 xx」
    ///
    /// **参考带必须同步换算**：只换点不换带会把 mmol/L 的读数摆在 mg/dL 的
    /// 参考带上，视觉上直接读出错误的「超标/正常」——这是 BR-006「不作判断」
    /// 之外更硬的正确性问题（旧实现只映射了 points，本次一并修正）。
    /// 排除点同样换算，否则对照视图里两组点不同量纲。
    public static func converted(_ series: TrendSeries, using conversion: UnitConversion) -> TrendSeries {
        func convert(_ p: TrendPoint) -> TrendPoint {
            var q = p
            q.value = conversion.convert(p.value)
            q.unit = conversion.toUnit
            if let lo = p.refLow { q.refLow = conversion.convert(lo) }
            if let hi = p.refHigh { q.refHigh = conversion.convert(hi) }
            if let lo = p.valueMin { q.valueMin = conversion.convert(lo) }
            if let hi = p.valueMax { q.valueMax = conversion.convert(hi) }
            return q
        }
        var s = series
        s.points = series.points.map(convert)
        s.excludedPoints = series.excludedPoints.map(convert)
        s.referenceBands = series.referenceBands.map { band in
            ReferenceBand(sourceLabel: band.sourceLabel,
                          lower: conversion.convert(band.lower),
                          upper: conversion.convert(band.upper),
                          grade: band.grade)
        }
        return s
    }

    /// 稳定排序（时间升序）
    public static func sorted(_ points: [TrendPoint]) -> [TrendPoint] {
        points.sorted { $0.measuredAt < $1.measuredAt }
    }

    /// F25 聚合键（FR25.12⑦ / §5.29）：code_concept_id 优先、无编码回落 metric_key。
    /// BR-003：未确认行 code_concept_id 为空 → 按原始 metric_key 独立成组；
    /// 确认后编码回填即并入归一序列（编码只补不覆，FR25.11）。
    /// 空串与 nil 同义（SQLite 边界：历史行可能存 ""）。
    public static func aggregationKey(metricKey: String, codeConceptId: String?) -> String {
        guard let id = codeConceptId, !id.isEmpty else { return metricKey }
        return id
    }
}
