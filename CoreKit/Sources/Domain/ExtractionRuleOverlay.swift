import Foundation

/// 抽取规则库的**值类型读面**（2026-11-07 业主：规则保存成数据库，
/// 并随 App 正式上线；Core ML 发现的新规则要及时收集）。
///
/// 分层：本文件是纯 Domain 值类型，零第三方依赖；SQLite 读写实现放在
/// Infrastructure（`ExtractionRuleStore`），Domain 不感知 GRDB。
///
/// 规则生命周期：
/// - `specSeed` / `scanMined`：随包种子，只读；
/// - `coreMLObserved`：端侧 Core ML 命中但不在既有别名表 → 写入为 `proposed`，
///   **不改变抽取行为**；
/// - `userConfirmed`：用户在确认页确认了该模型字段 → `confirmedCount += 1`；
///   满足证据门槛后才转 `active`。
public enum ExtractionRuleSource: String, Codable, Sendable, CaseIterable {
    // rawValue 与规则库 `source_kind` 列严格同名（snake_case）——不要改回 camelCase，
    // 否则 seed 读出会被静默降级为 specSeed。
    case specSeed = "spec_seed"
    case scanMined = "scan_mined"
    case coreMLObserved = "coreml_observed"
    case userConfirmed = "user_confirmed"
}

public enum ExtractionRuleStatus: String, Codable, Sendable, CaseIterable {
    case active
    case proposed
    case deprecated
}

public struct ExtractionRuleAlias: Codable, Sendable, Equatable, Hashable {
    public let kind: String
    public let key: String
    public let alias: String
    public let source: ExtractionRuleSource
    public let status: ExtractionRuleStatus
    public let evidenceCount: Int
    public let confirmedCount: Int

    public init(kind: String, key: String, alias: String,
                source: ExtractionRuleSource, status: ExtractionRuleStatus,
                evidenceCount: Int = 0, confirmedCount: Int = 0) {
        self.kind = kind; self.key = key; self.alias = alias
        self.source = source; self.status = status
        self.evidenceCount = evidenceCount; self.confirmedCount = confirmedCount
    }
}

/// 端侧观察到的一条候选规则：只存标签文本，不存字段值（无 PHI）。
public struct ExtractionRuleObservation: Sendable, Equatable, Hashable {
    public let kind: String
    public let key: String
    public let alias: String
    public init(kind: String, key: String, alias: String) {
        self.kind = kind; self.key = key; self.alias = alias
    }
}

/// 规则覆盖层：按卡类给每个字段追加别名。只消费 `active` 行。
public struct ExtractionRuleOverlay: Codable, Sendable, Equatable {
    public var aliases: [ExtractionRuleAlias]

    public init(aliases: [ExtractionRuleAlias] = []) {
        self.aliases = aliases
    }

    /// kind → key → [alias]；保序去重，最长别名优先由 `RuleExtractor.split` 排序。
    public func activeAliases(for kind: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var seen = Set<String>()
        for entry in aliases where entry.kind == kind && entry.status == .active {
            let identity = "\(entry.key)\u{1F}\(entry.alias)"
            guard seen.insert(identity).inserted else { continue }
            out[entry.key, default: []].append(entry.alias)
        }
        return out
    }

    /// 该 (kind,key) 是否含端侧学习别名：命中即把置信度压到 0.5，
    /// 低于批量确认门槛 0.6，强制用户逐项确认（BR-003）。
    public func hasLearnedAlias(kind: String, key: String) -> Bool {
        aliases.contains {
            $0.kind == kind && $0.key == key
                && ($0.source == .coreMLObserved || $0.source == .userConfirmed)
        }
    }

    /// 把覆盖层应用到 spec：只追加别名，不改键/类型/顺序；未命中键原样。
    public func applied(to spec: ExtractionSpec) -> ExtractionSpec {
        let extra = activeAliases(for: spec.kind)
        guard !extra.isEmpty else { return spec }
        func augment(_ fields: [FieldSpec]) -> [FieldSpec] {
            fields.map { field in
                guard let additions = extra[field.key], !additions.isEmpty else { return field }
                var aliases = field.labelAliases
                var seen = Set(aliases)
                for alias in additions where seen.insert(alias).inserted { aliases.append(alias) }
                return FieldSpec(key: field.key, type: field.type, scope: field.scope,
                                 isRequired: field.isRequired, labelAliases: aliases,
                                 grounding: field.grounding, promptHint: field.promptHint,
                                 fallback: field.fallback)
            }
        }
        return ExtractionSpec(kind: spec.kind, version: spec.version,
                              shared: augment(spec.shared), row: augment(spec.row),
                              rowAnchor: spec.rowAnchor, maxRowsPerRegion: spec.maxRowsPerRegion,
                              exemplars: spec.exemplars, negativeGuards: spec.negativeGuards,
                              rowMinFields: spec.rowMinFields)
    }
}
