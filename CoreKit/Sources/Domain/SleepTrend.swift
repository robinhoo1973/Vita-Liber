import Foundation

/// FR7.11 睡眠整合呈现（业主 2026-09-16 第 3 项：「睡眠时长的数据要整合在一起展示
/// 而不是分开展示，可以用不同颜色的 BAR 来代表不同的睡眠时长，并在趋势图上给出 legend」）。
///
/// **为什么「一晚」必须是 Domain 概念而不是视图里的拼装**：`HealthKitReader` 把
/// `SleepNightSummary.perStage` 拆成六行 `metric_sample`（sleep_total / sleep_deep /
/// sleep_rem / sleep_core / sleep_awake / sleep_unspecified，同一 `measured_at` =
/// noon 锚窗左端），那是**存储投影**；「六行同属一晚」这个业务事实必须有单一表达，
/// 否则宫格、趋势页、语音播报会各自拼一份（本仓「同一事实多处实现即漂移源」的教训）。
/// 睡眠阶段**时间轴**（真实发生顺序的 hypnogram）仍不在本层：存储只有每窗时长，
/// 不得从总量反造顺序（trend-visualization-module-spec §6.3 V1.5 边界）。

public extension MetricType {
    /// 阶段键 → 阶段（`sleep_total` 是总量键，无阶段）。
    var sleepStage: SleepStage? {
        switch self {
        case .sleepDeep: return .deep
        case .sleepCore: return .core
        case .sleepREM: return .rem
        case .sleepAwake: return .awake
        case .sleepUnspecified: return .unspecified
        case .sleepTotal: return nil
        default: return nil
        }
    }

    /// 睡眠族成员（含总量键）：一晚的六个投影键。宫格折叠、整合查询、空态判据共用。
    var isSleep: Bool { self == .sleepTotal || sleepStage != nil }

    /// 睡眠族查询键（单一事实源）：读侧 `metric_key IN (...)` 与宫格折叠都取这里，
    /// 新增阶段只改这一处。
    static let sleepGroupKeys: [MetricType] = [
        .sleepTotal, .sleepDeep, .sleepCore, .sleepREM, .sleepUnspecified, .sleepAwake
    ]
}

public extension SleepStage {
    /// 柱内堆叠顺序（自下而上）：深睡 → 核心 → 未分期 → 快速眼动 → 清醒。
    /// 与 Apple Health 睡眠图例同序（图例自上而下读作清醒/快速眼动/核心/深睡）。
    /// 这是**分类编码**，段色不表达「睡得好/不好」（BR-006 不作判断）。
    var trendStackOrder: Int {
        switch self {
        case .deep: return 0
        case .core: return 1
        case .unspecified: return 2
        case .rem: return 3
        case .awake: return 4
        case .inBed: return 5   // 存储不产该键（inBed 只进 inBedTotal）；排序兜底不崩
        }
    }

    static var trendStack: [SleepStage] {
        allCases.sorted { $0.trendStackOrder < $1.trendStackOrder }
    }
}

/// 睡眠整合输入行：一次读回的原始读数 + 它的指标键（阶段由此解析）。
public struct SleepTrendRow: Sendable, Equatable {
    public var metric: MetricType
    public var point: TrendPoint
    public init(metric: MetricType, point: TrendPoint) {
        self.metric = metric
        self.point = point
    }
}

/// 一晚之内某阶段的时长（`pointIds` = 该段的原始行，排除/恢复的动作对象）。
public struct SleepStageSlice: Sendable, Equatable, Identifiable {
    public var stage: SleepStage
    public var hours: Double
    public var pointIds: [UUID]
    public var id: SleepStage { stage }
    public init(stage: SleepStage, hours: Double, pointIds: [UUID] = []) {
        self.stage = stage
        self.hours = hours
        self.pointIds = pointIds
    }
}

/// 一晚（noon 锚窗）：堆叠柱的一段集合 + 该晚的总时长投影。
public struct SleepTrendNight: Sendable, Equatable, Identifiable {
    /// 日锚（该晚读数 `measured_at` 所在日历日的起点）——柱的位置
    public var day: Date
    /// 可见段（按 `SleepStage.trendStack` 排序）
    public var slices: [SleepStageSlice]
    /// `sleep_total` 投影（无该行 = nil，**不臆造**总量：各段之和只等于入睡各段 + 清醒段）
    public var asleepHours: Double?
    public var unit: String?
    /// `sleep_total` 原始行 id（该行不进堆叠段，但**同属这一晚**：排除一整夜必须
    /// 连它一起软删，否则宫格「睡眠总时长」瓦片与迷你线仍会显示被排除的夜——
    /// 而它没有任何别的排除入口）
    public var totalPointIds: [UUID]
    public var id: Date { day }
    public init(day: Date, slices: [SleepStageSlice], asleepHours: Double? = nil,
                unit: String? = nil, totalPointIds: [UUID] = []) {
        self.day = day; self.slices = slices; self.asleepHours = asleepHours; self.unit = unit
        self.totalPointIds = totalPointIds
    }
    /// 柱高 = 各段之和（含清醒段，与 Apple Health 睡眠柱同口径）
    public var stackedHours: Double { slices.reduce(0) { $0 + $1.hours } }
    /// 该晚全部原始行（排除动作的作用集：各段行 + `sleep_total` 行）
    public var pointIds: [UUID] { slices.flatMap(\.pointIds) + totalPointIds }
}

public struct SleepTrendSeries: Sendable, Equatable {
    /// 可见夜（`excluded = 0` 的行聚合）
    public var nights: [SleepTrendNight]
    /// 已排除夜（FR7.4：原记录可见可恢复——排除段不再进图，但逐段可恢复）
    public var excludedNights: [SleepTrendNight]
    /// 查询身份回传（与 `TrendSeries.identity` 同纪律：渲染层按身份丢弃过期结果）
    public var identity: TrendQueryIdentity?
    public init(nights: [SleepTrendNight], excludedNights: [SleepTrendNight] = [],
                identity: TrendQueryIdentity? = nil) {
        self.nights = nights; self.excludedNights = excludedNights; self.identity = identity
    }
}

public enum SleepTrendRules {
    /// 原始行 → 按夜聚合的整合序列（纯函数，金样单测）。
    ///
    /// 同一 (夜, 阶段) 出现多行时取**最大值**并保留全部行 id：
    /// 同一晚可能被两个窗口各物化一次（被 noon 锚窗裁剪的那份值更小），
    /// `SleepMerge` 已在窗内做过来源并集合并，跨行再求和即双计
    /// （SleepMerge 文件头记录的 8h+8h≈16h 教训同族）。
    public static func series(_ rows: [SleepTrendRow], identity: TrendQueryIdentity?,
                              calendar: Calendar = .current) -> SleepTrendSeries {
        struct Accumulator { var hours: Double; var pointIds: [UUID]; var unit: String?
            mutating func merge(_ point: TrendPoint) {
                if point.value > hours { hours = point.value }
                pointIds.append(point.id)
                if unit == nil { unit = point.unit }
            }
        }
        var visible: [Date: [SleepStage: Accumulator]] = [:]
        var excluded: [Date: [SleepStage: Accumulator]] = [:]
        var visibleTotals: [Date: (hours: Double, pointIds: [UUID])] = [:]
        var excludedTotals: [Date: (hours: Double, pointIds: [UUID])] = [:]
        /// 阶段行并入（同阶段多行取最大值、保留全部行 id——SleepMerge 已做窗内并集，跨行求和即双计）。
        func mergeStage(_ point: TrendPoint, day: Date, stage: SleepStage,
                        into groups: inout [Date: [SleepStage: Accumulator]]) {
            var stages = groups[day] ?? [:]
            var slot = stages[stage] ?? Accumulator(hours: 0, pointIds: [], unit: nil)
            slot.merge(point)
            stages[stage] = slot
            groups[day] = stages
        }
        /// 总量行并入（同晚取最大值；行 id 恒保留）。
        func addTotal(_ point: TrendPoint, day: Date,
                      into totals: inout [Date: (hours: Double, pointIds: [UUID])]) {
            let current = totals[day]
            totals[day] = (max(current?.hours ?? 0, point.value), (current?.pointIds ?? []) + [point.id])
        }
        for row in rows {
            let day = calendar.startOfDay(for: row.point.measuredAt)
            guard let stage = row.metric.sleepStage else {
                // 总量键（sleep_total）：只作整晚口径，不参与堆叠（否则与各段双计）；
                // 行 id 一并保留——排除一整夜时它必须同被软删（否则宫格总时长瓦片
                // 仍显示该夜，且它没有别的排除入口）
                if row.point.excluded {
                    addTotal(row.point, day: day, into: &excludedTotals)
                } else {
                    addTotal(row.point, day: day, into: &visibleTotals)
                }
                continue
            }
            if row.point.excluded {
                mergeStage(row.point, day: day, stage: stage, into: &excluded)
            } else {
                mergeStage(row.point, day: day, stage: stage, into: &visible)
            }
        }
        func night(day: Date, stages: [SleepStage: Accumulator],
                   total: (hours: Double, pointIds: [UUID])?) -> SleepTrendNight {
            let slices = stages
                .map { SleepStageSlice(stage: $0.key, hours: $0.value.hours, pointIds: $0.value.pointIds) }
                .sorted { $0.stage.trendStackOrder < $1.stage.trendStackOrder }
            let unit = stages.values.compactMap(\.unit).first
            return SleepTrendNight(day: day, slices: slices, asleepHours: total?.hours,
                                   unit: unit, totalPointIds: total?.pointIds ?? [])
        }
        return SleepTrendSeries(
            nights: visible.keys.sorted().map {
                night(day: $0, stages: visible[$0] ?? [:], total: visibleTotals[$0])
            },
            excludedNights: excluded.keys.sorted().map {
                night(day: $0, stages: excluded[$0] ?? [:], total: excludedTotals[$0])
            },
            identity: identity)
    }

    /// 宫格折叠（FR7.11 整合）：睡眠族六键在「指标总览」里**只占一块瓦片**——
    /// 六个投影键同属一晚，分列六块会把整整半屏宫格用来重复表示同一夜的读数。
    /// 保留组内 `sleep_total`（存在时）；否则暂存值最大的阶段行（其瓦片名即该阶段名，
    /// 不会把单阶段读数冒充为总时长）。
    /// - Parameter rows: 已按成员过滤的最新点行（`latestPerMetric` 输出）
    /// - Returns: 折叠后的行，顺序保持不变
    public static func gridRows<T>(_ rows: [T],
                                   metric: (T) -> MetricType?, value: (T) -> Double) -> [T] {
        var bestSleepIndex: Int?
        var result: [T] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let type = metric(row), type.isSleep else {
                result.append(row)
                continue
            }
            guard let index = bestSleepIndex else {
                bestSleepIndex = result.count
                result.append(row)
                continue
            }
            // 组内择优：sleep_total 恒胜；否则取值更大的行（键不同也换，故按类型与值判定）
            let current = result[index]
            let currentType = metric(current)
            if currentType != .sleepTotal, type == .sleepTotal || value(row) > value(current) {
                result[index] = row
            }
        }
        return result
    }
}
