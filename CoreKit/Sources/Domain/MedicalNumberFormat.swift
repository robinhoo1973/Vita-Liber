import Foundation

/// 医学数值的显示形态**单一出口**。
///
/// 为什么需要它：同一个数字此前有三种写法散在各处——可见文本用 `String(format: "%.1f")`
/// 或 `%g`，无障碍标签用 `"\(double)"` 字符串插值。第三种是 Swift 的最短往返表示，
/// 对计算得来的值会念出 `3.7000000000000002`，而屏幕上显示 `3.7`：
/// **视障用户听到的医学数字与视力用户看到的不是同一个**。A 级医院数字上尤其不可接受。
///
/// 纪律：可见文本与无障碍标签必须取用同一个函数，二者才不可能漂移。
public enum MedicalNumberFormat: Sendable {
    /// 趋势/参考范围等「保留 1 位小数」的量（与图例、参考带文案同口径）
    public static func oneDecimal(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    /// 库存件数等「整数为主、可能有半片」的量。
    ///
    /// `%g` 是既有形态（整数不带小数点），保留以免改动用户可见的余量口径；
    /// 但它有两个已知边界：|v| ≥ 1e6 转科学计数法（`1e+06`），
    /// 且最多 6 位有效数字（1/6 显示成 `0.166667`）。药品件数达不到这些量级，
    /// 故暂不改口径——若将来要统一成 `oneDecimal`，只需改这一处。
    public static func quantity(_ v: Double) -> String {
        String(format: "%g", v)
    }

    /// 指标读数小数位数的**单一定义处**（2026-10-05 业主反馈修复批：默认 2 位）。
    /// 无任何处内联精度——视图与无障碍标签一律经 `metricDisplay` 取数。
    public static let defaultMetricDigits = 2

    /// 指标 → 显示位数（例外表）。默认 2 位（业主口径）；例外按
    /// 「显示精度 ≤ 测量精度」收敛（数据诚实纪律，ui-ux §5.45）：
    /// 整数类量纲（心率/呼吸/步数/血压）0 位；1 位惯例量纲（体温/血氧/
    /// 血糖/睡眠时长族）1 位。表即「定义的地方」——业主若坚持全 2 位，
    /// 删表即整体回退，调用面零改动。
    public static func metricDigits(_ metric: MetricType?) -> Int {
        switch metric {
        case .bloodPressureSys, .bloodPressureDia, .heartRate, .restingHeartRate,
             .respiratoryRate, .steps:
            return 0
        case .temperature, .bloodOxygen, .glucose,
             .sleepTotal, .sleepDeep, .sleepREM, .sleepAwake, .sleepCore, .sleepUnspecified:
            return 1
        case .weight, nil:
            return defaultMetricDigits
        }
    }

    /// 指标读数显示（固定小数位；同 `oneDecimal` 纪律：可见文本与无障碍
    /// 标签必须共用本出口，二者才不可能漂移）。
    public static func metricDisplay(_ value: Double, metric: MetricType?) -> String {
        String(format: "%.\(metricDigits(metric))f", value)
    }
}
