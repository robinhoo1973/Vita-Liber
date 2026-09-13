import Foundation

/// FR16.1 高频心率小时窗口聚合（health-import V1.3 / tech §5.29 V3.86）：
/// 本地日历整点 [H:00, H+1:00)（wall-clock；DST 由 Calendar 处理），
/// 窗口行 = value(均值) + value_min/max + sample_count。
/// 纪律：有效样本 <3 不落行（原始分钟级不落盘预算）；非有限值剔除
/// （剔除计数入 rejected 元数据，不静默——AlertEngine 非有限剔除先例）；
/// >200 bpm 等疑似异常**保留**交评估（可能是真 L3）。Domain 纯函数，金样单测。

public struct HourWindowSample: Sendable, Equatable {
    public var value: Double
    public var at: Date
    public init(value: Double, at: Date) {
        self.value = value
        self.at = at
    }
}

public struct HourWindow: Sendable, Equatable {
    /// 窗口左边界（epoch 语义：跨时区不重算，对齐迁移 v15 纪律）
    public var windowStart: Date
    public var avg: Double
    public var min: Double
    public var max: Double
    public var sampleCount: Int
    public init(windowStart: Date, avg: Double, min: Double, max: Double, sampleCount: Int) {
        self.windowStart = windowStart
        self.avg = avg
        self.min = min
        self.max = max
        self.sampleCount = sampleCount
    }
}

/// 小时窗口聚合结果（round2 H-N2）：统计行 + 非有限剔除计数 + 稀疏窗计数三者分列，
/// 任何一类都不静默——稀疏不是错误，但必须可见（无手表用户心率天然稀疏）。
public struct HourWindowAggregate: Sendable, Equatable {
    public let windows: [HourWindow]
    /// 非有限值剔除计数（伪迹）
    public let rejected: Int
    /// 有效样本 < minSamples 未形成统计行的小时桶数（按来源分组后逐桶计）——H-N2 计数上送
    public let sparseWindows: Int
    public init(windows: [HourWindow], rejected: Int, sparseWindows: Int) {
        self.windows = windows
        self.rejected = rejected
        self.sparseWindows = sparseWindows
    }
}

public enum HourWindowAggregator {
    /// 最小有效样本数（<3 不落行）
    public static let minSamples = 3

    public static func aggregate(_ samples: [HourWindowSample],
                                 calendar: Calendar = .current) -> HourWindowAggregate {
        var buckets: [Date: [Double]] = [:]
        var rejected = 0
        var sparse = 0
        for sample in samples {
            guard sample.value.isFinite else {
                rejected += 1   // 仅剔除非有限伪迹（0/负值保留交评估）
                continue
            }
            let bucket = calendar.dateInterval(of: .hour, for: sample.at)?.start
                ?? calendar.startOfDay(for: sample.at)
            buckets[bucket, default: []].append(sample.value)
        }
        var windows: [HourWindow] = []
        for (start, values) in buckets.sorted(by: { $0.key < $1.key }) {
            guard values.count >= minSamples else {
                sparse += 1     // round2 H-N2：门槛不变，但不再静默丢弃——计数上送供 UI 提示
                continue
            }
            let sum = values.reduce(0, +)
            windows.append(HourWindow(
                windowStart: start,
                avg: sum / Double(values.count),
                min: values.min() ?? sum,
                max: values.max() ?? sum,
                sampleCount: values.count))
        }
        return HourWindowAggregate(windows: windows, rejected: rejected, sparseWindows: sparse)
    }
}
