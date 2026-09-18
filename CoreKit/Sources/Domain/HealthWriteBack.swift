import Foundation

/// 写回 Apple 健康的资格与载荷（业主 2026-09-17 定：本机确认的手输指标 → HealthKit）。
/// 纯规则零 IO；HKQuantityType/HKUnit 映射在 Infrastructure `HealthKitReader`。
///
/// **平台事实**（2026-09-17 查证）：
/// - 样本型（血压/血糖/体重/体温/心率/血氧等）**可读写**，分类型授权、只能删除自己写入的样本；
/// - 特征型（血型/出生日期/生理性别）**只读**——用户只能在「健康」App 里手改；
/// - 医疗急救卡 / SOS 联系人**无任何公开 API**（读不到、也写不进）——只能引导用户手填（FR15.2）。
///
/// 防回声：写回样本由 `HealthKitReader` 以 bundle 标识过滤，不会再被增量导入
/// 回灌 `metric_sample`（写回 → 导回 → 重复行 → 再写回的环路在源头切断）。
public struct HealthSampleDraft: Sendable, Equatable {
    /// `MetricType.rawValue`（趋势层 camelCase，如 `bloodPressureSys`）。
    public var metric: String
    public var value: Double
    /// 血压第二值（舒张压）；有值且指标为收缩压时在 HealthKit 侧合并为血压相关性对象。
    public var secondaryValue: Double?
    /// 与 `metric_sample.unit` 同值（用户自填单位）。
    public var unit: String
    public var measuredAt: Date

    public init(metric: String, value: Double, secondaryValue: Double? = nil,
                unit: String, measuredAt: Date) {
        self.metric = metric; self.value = value
        self.secondaryValue = secondaryValue; self.unit = unit
        self.measuredAt = measuredAt
    }
}

/// 写回资格规则（BR 纯函数——资格判定不进视图）。
public enum HealthWriteBack {
    /// 可写指标 → HealthKit 规范单位。**单位不符即跳过**（不换算、不猜单位——
    /// 血糖 mmol/L 与 mg/dL 的换算被刻意拒绝，诚实纪律优先于覆盖；跳过计数随
    /// 写回摘要如实呈现）。
    public static func canonicalUnit(for metric: String) -> String? {
        switch metric {
        case MetricType.bloodPressureSys.rawValue, MetricType.bloodPressureDia.rawValue: return "mmHg"
        case MetricType.glucose.rawValue: return "mg/dL"
        case MetricType.weight.rawValue: return "kg"
        case MetricType.temperature.rawValue: return "°C"
        case MetricType.heartRate.rawValue: return "bpm"
        case MetricType.bloodOxygen.rawValue: return "%"
        default: return nil
        }
    }

    /// 单位归一（trim + 全角 ℃ 归半角）——只服务逐字匹配，不做量纲换算。
    public static func normalizedUnit(_ unit: String) -> String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "℃", with: "°C")
    }

    /// 可写 = 有规范单位 ∧ 单位逐字相符 ∧ 数值有限。
    public static func isWritable(metric: String, unit: String, value: Double) -> Bool {
        guard let canonical = canonicalUnit(for: metric), value.isFinite else { return false }
        return normalizedUnit(unit) == canonical
    }

    /// 写回尺度：**应用内部数值约定 → 目标存储的数值约定**。默认 1:1。
    ///
    /// 只有 `.percent()` 类指标不 1:1：HealthKit 的血氧是**分数制**（0.98 表示 98%），
    /// 而本应用的 SpO2 约定是 0–100（读路径同一事实的镜像：`factor = 100`，
    /// `value = point.value * factor`）。写回若原样传 98，会被存成 98.0 = **9800%**——
    /// 一个生理上不可能的值；又因防回声过滤把本应用写入的样本从增量与窗口两路都滤掉，
    /// **本应用既看不见也修不回来**（只能由用户在健康 App 手工删除）。
    ///
    /// 放在 Domain 而非 Infrastructure：① 与 `canonicalUnit`/`isWritable` 同属「写回载荷
    /// 规则」的单一出口；② Infrastructure 的 `HealthKitReader` 带 `#if os(iOS)` 守卫，
    /// 在 Linux 上编译为空，规则留在那里**本机无法测试**（本次修复的唯一可验证路径）。
    /// 换算是有定义的映射，不是「猜测」——诚实写回允许换算、不允许猜。
    public static func writeScale(for metric: String) -> Double {
        switch metric {
        case MetricType.bloodOxygen.rawValue: return 0.01
        default: return 1
        }
    }
}
