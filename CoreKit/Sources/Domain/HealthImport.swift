import Foundation

/// HealthKit identities are not medical values. They make deletion and replay recoverable.
public enum HealthDataKind: String, CaseIterable, Codable, Sendable {
    case heartRate, restingHeartRate, bloodOxygen, respiratoryRate, steps, sleep
}

public enum MetricAggregation: String, Codable, Sendable {
    case sample, hourlyAverage, dailySum, sleepDuration
}

public struct HealthSampleReference: Sendable, Equatable, Codable {
    public let id: UUID
    public let kind: HealthDataKind
    public let sourceID: String
    public let start: Date
    public let end: Date
    public init(id: UUID, kind: HealthDataKind, sourceID: String, start: Date, end: Date) {
        self.id = id; self.kind = kind; self.sourceID = sourceID
        self.start = start; self.end = end
    }

    public var isValid: Bool {
        !sourceID.isEmpty && HealthImportWindow.validDates(start: start, end: end)
    }
}

public struct HealthChangeBatch: Sendable, Equatable, Codable {
    public let added: [HealthSampleReference]
    public let deleted: [UUID]
    public let anchor: Data
    public let hasMore: Bool
    public init(added: [HealthSampleReference], deleted: [UUID], anchor: Data, hasMore: Bool) {
        self.added = added; self.deleted = deleted; self.anchor = anchor; self.hasMore = hasMore
    }
}

public extension HealthDataKind {
    var primaryMetric: MetricType {
        switch self {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .bloodOxygen: return .bloodOxygen
        case .respiratoryRate: return .respiratoryRate
        case .steps: return .steps
        case .sleep: return .sleepTotal
        }
    }
    /// Aggregate kinds project one row per window (hour / day / night); discrete kinds keep one row per reading.
    var isAggregated: Bool { [.heartRate, .steps, .sleep].contains(self) }
}

public struct HealthImportWindow: Sendable, Hashable, Codable {
    public let kind: HealthDataKind
    public let start: Date
    public let end: Date
    /// Window-scoped prefix. Aggregate rows embed the window start because the window *is* their identity.
    public var prefix: String { "hk:\(kind.rawValue):\(Int64(start.timeIntervalSince1970)):" }
    /// Identity prefix used to find this window's rows: discrete readings are identified by sample UUID
    /// only, so a later calendar/time-zone change replays onto the same row instead of duplicating it.
    public var identityPrefix: String { kind.isAggregated ? prefix : "hk:\(kind.rawValue):" }
    public init(kind: HealthDataKind, start: Date, end: Date) {
        self.kind = kind; self.start = start; self.end = end
    }

    public var isValid: Bool { Self.validDates(start: start, end: end) && end > start }

    fileprivate static func validDates(start: Date, end: Date) -> Bool {
        let lower = start.timeIntervalSince1970
        let upper = end.timeIntervalSince1970
        return lower.isFinite && upper.isFinite && end >= start
            && lower >= Double(Int64.min) && upper < Double(Int64.max)
    }

    /// Matches HealthKit's default sample predicate, including a sample ending at the lower boundary.
    public func overlaps(_ sample: HealthSampleReference) -> Bool {
        sample.kind == kind && sample.end >= start && sample.start < end
    }

    /// Stable identity of one discrete reading (`ordinal` distinguishes entries of a quantity series).
    public static func sampleIdentity(kind: HealthDataKind, sampleID: UUID, ordinal: Int?) -> String {
        let base = "hk:\(kind.rawValue):\(sampleID.uuidString)"
        return ordinal.map { "\(base):\($0)" } ?? base
    }

    /// Inverse of `sampleIdentity`; nil for aggregate identities or foreign formats.
    public static func sampleID(fromIdentity identity: String, kind: HealthDataKind) -> UUID? {
        guard !kind.isAggregated else { return nil }
        let head = "hk:\(kind.rawValue):"
        guard identity.hasPrefix(head) else { return nil }
        let rest = identity.dropFirst(head.count)
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let id = UUID(uuidString: String(parts[0])) else { return nil }
        if parts.count == 2 {
            guard let ordinal = Int(parts[1]), ordinal >= 0 else { return nil }
        }
        return id
    }

    /// Whether a projected row belongs to this window: aggregate rows by prefix, discrete rows by
    /// identity prefix plus half-open `measuredAt` membership.
    public func contains(sourceRef: String, measuredAt: Date) -> Bool {
        guard isValid, measuredAt.timeIntervalSince1970.isFinite,
              sourceRef.hasPrefix(identityPrefix) else { return false }
        if kind.isAggregated { return measuredAt == start }
        return Self.sampleID(fromIdentity: sourceRef, kind: kind) != nil
            && measuredAt >= start && measuredAt < end
    }

    public static func covering(_ sample: HealthSampleReference, calendar: Calendar) -> [Self] {
        guard sample.isValid else { return [] }
        var result: [Self] = []
        // Steps/sleep intervals end exclusively on a boundary; a heart-rate series may carry its last
        // instantaneous entry exactly at `end`, so that hour must be covered too (closed end).
        let isInterval = [.steps, .sleep].contains(sample.kind)
        var cursor = sample.start
        repeat {
            let start: Date
            let end: Date
            if sample.kind == .heartRate {
                guard let interval = calendar.dateInterval(of: .hour, for: cursor) else { return [] }
                start = interval.start; end = interval.end
            } else if sample.kind == .sleep {
                guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: cursor),
                      let previous = calendar.date(byAdding: .day, value: -1, to: noon) else { return [] }
                start = cursor < noon ? previous : noon
                guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
                end = next
            } else {
                start = calendar.startOfDay(for: cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
                end = next
            }
            let window = Self(kind: sample.kind, start: start, end: end)
            guard window.isValid, end > cursor else { return [] }
            result.append(window)
            cursor = end
        } while cursor < sample.end || (!isInterval && cursor == sample.end)
        return result
    }
}

public struct HealthWindowSnapshot: Sendable {
    public let window: HealthImportWindow
    public let samples: [HealthSampleReference]
    public let rows: [DeviceMetricRow]
    public let readings: [MetricReading]
    public let rejected: Int
    public init(window: HealthImportWindow, samples: [HealthSampleReference],
                rows: [DeviceMetricRow], readings: [MetricReading] = [], rejected: Int = 0) {
        self.window = window; self.samples = samples; self.rows = rows
        self.readings = readings; self.rejected = rejected
    }
}
