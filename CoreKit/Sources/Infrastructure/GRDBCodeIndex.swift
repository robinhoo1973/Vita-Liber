#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// F25 医学数据标准化引擎码表 GRDB 实现（tech-spec §5.52 / ADR-028）。
///
/// 六表读取（code_concept/code_alias/code_map/resolver_override/ucum_unit/
/// ucum_molar_bridge，§4.3 DDL）+ 内置种子装载（CodeSetSeeds，P0.5 起点子集）。
///
/// 纪律：
/// - 链序施加在 Domain `CodeResolver`（override > curated > fold）——本实现
///   只如实返回命中，不得自行排序过滤；
/// - 种子装载版本门控（V3.70 审查）：app_settings 记 bundle_version，
///   版本升级按 §5.52 语义整批替换旧种子行，`resolver_override` 用户纠错行
///   与已确认数据永不触碰（FR25.11 编码只补不覆）；
/// - 全部读取走共享 DatabasePool 的并发读路径（§4.4）。
public actor GRDBCodeIndex: CodeIndex, UnitIndex {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 内置种子装载（幂等）：app_settings 记录已装 bundle_version——
    /// 版本未变 = 无动作；版本升级 = 旧种子行按 §5.52 升级语义整批替换
    /// （码表是可重建数据；`resolver_override` 用户纠错行与 metric_sample
    /// 等已确认数据永不触碰，FR25.11）。
    /// 装配层将在 M1.5/M2 接线批于 AppContainer 启动时调用（tech §12 进度表）；
    /// 当前引擎尚未接入生产消费侧，测试直接构造本类。
    public func loadBundledSeedsIfNeeded() async throws {
        try await writer.write { db in
            let stored: String? = try String.fetchOne(db, sql: """
                SELECT value FROM app_settings WHERE key = 'code_set_bundle_version'
                """)
            guard stored != CodeSetSeeds.bundleVersion else { return }
            if stored == nil {
                // 过渡自旧「表空即装」策略（V3.70 审查）：旧装载器未写版本标记，
                // 但写入行的 bundle_version 恒等于编译期常量——已有当前版本
                // 种子行即视为已装，补记标记即可，避免无谓重插/别名重复。
                let existing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM code_concept WHERE bundle_version = ?
                    """, arguments: [CodeSetSeeds.bundleVersion]) ?? 0
                if existing > 0 {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO app_settings (key, value)
                        VALUES ('code_set_bundle_version', ?)
                        """, arguments: [CodeSetSeeds.bundleVersion])
                    return
                }
            }
            try Self.insertSeeds(db, previousVersion: stored)
            try db.execute(sql: """
                INSERT OR REPLACE INTO app_settings (key, value)
                VALUES ('code_set_bundle_version', ?)
                """, arguments: [CodeSetSeeds.bundleVersion])
        }
    }

    private static func insertSeeds(_ db: Database, previousVersion: String?) throws {
        let v = CodeSetSeeds.bundleVersion
        if let prev = previousVersion {
            // 升级替换（§5.52）：带 bundle_version 的表删旧种子行后重插；
            // ucum 两表无 bundle_version 列且只含种子数据，整体重建；
            // code_concept 用 upsert——id 稳定且被 metric_sample 引用，
            // 删行会撞 FK（用户已确认数据永不重写，FR25.11）
            try db.execute(sql: "DELETE FROM code_alias WHERE bundle_version = ?", arguments: [prev])
            try db.execute(sql: "DELETE FROM code_map WHERE bundle_version = ?", arguments: [prev])
            try db.execute(sql: "DELETE FROM ucum_unit")
            try db.execute(sql: "DELETE FROM ucum_molar_bridge")
        } else {
            // 无标记过渡态兜底：清掉任何非当前版本的别名行（code_alias 无主键，
            // 不清理会随重装重复堆积同文别名）
            try db.execute(sql: "DELETE FROM code_alias WHERE bundle_version != ?", arguments: [v])
        }
        for s in CodeSetSeeds.concepts {
            try db.execute(sql: """
                INSERT INTO code_concept
                  (id, canonical_code, coding_system, display_zh_hans, display_en,
                   kind, canonical_unit, bundle_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  canonical_code = excluded.canonical_code,
                  coding_system = excluded.coding_system,
                  display_zh_hans = excluded.display_zh_hans,
                  display_en = excluded.display_en,
                  kind = excluded.kind,
                  canonical_unit = excluded.canonical_unit,
                  bundle_version = excluded.bundle_version
                """, arguments: [s.id, s.canonicalCode, s.codingSystem.rawValue,
                                 s.displayZhHans, s.displayEn, s.kind.rawValue,
                                 s.canonicalUnit, v])
        }
        for s in CodeSetSeeds.aliases {
            try db.execute(sql: """
                INSERT INTO code_alias
                  (alias_text, locale, concept_id, route, priority, bundle_version)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [s.aliasText, s.locale, s.conceptId,
                                 s.route.rawValue, s.priority, v])
        }
        for s in CodeSetSeeds.unitSpecific {
            // OR IGNORE 防御过渡态：旧策略装载过同主键行（无标记库）时
            // 不因冲突抛错（真升级路径的 DELETEs 已先清旧行）
            try db.execute(sql: """
                INSERT OR IGNORE INTO code_map
                  (source_system, source_code, concept_id, bundle_version)
                VALUES ('loinc-unit', ?, ?, ?)
                """, arguments: ["\(s.conceptId)|\(s.unit)", s.targetConceptId, v])
        }
        for s in CodeSetSeeds.overrides {
            // 确定性 id（seed:<pattern>）——升级重插幂等，不随 UUID 重复堆积；
            // 用户纠错行是别的 id，永不触碰（FR25.11）
            try db.execute(sql: """
                INSERT OR IGNORE INTO resolver_override
                  (id, query_pattern, concept_id, note, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["seed:\(s.queryPattern)", s.queryPattern, s.conceptId,
                                 s.note, Date().timeIntervalSince1970])
        }
        for s in CodeSetSeeds.ucumUnits {
            // OR IGNORE 防御过渡态（无标记库已有同主键行时不因冲突抛错）
            try db.execute(sql: """
                INSERT OR IGNORE INTO ucum_unit
                  (unit_code, family, dimension, factor, offset, kind)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [s.unitCode, s.family, s.dimension,
                                 s.factor, s.offset, s.kind])
        }
        for s in CodeSetSeeds.bridges {
            try db.execute(sql: """
                INSERT OR IGNORE INTO ucum_molar_bridge
                  (concept_id, from_unit, to_unit, factor, note)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [s.conceptId, s.fromUnit, s.toUnit, s.factor, s.note])
        }
    }

    // MARK: - CodeIndex

    /// 概念行 → CodeResolution 的**唯一**映射（审查修复：原 concept/unitSpecific
    /// 两处逐字复制同一映射块——corrupt 值回落策略 ?? .loinc/?? .other 存在两份，
    /// 改一处漏一处即静默分叉）。CHECK 约束保证词汇合法，回落仅为防御。
    private static func codeResolution(from row: Row) -> CodeResolution {
        CodeResolution(
            conceptId: row["id"], canonicalCode: row["canonical_code"],
            codingSystem: CodingSystem(rawValue: row["coding_system"] as String) ?? .loinc,
            displayZhHans: row["display_zh_hans"], displayEn: row["display_en"],
            kind: CodeKind(rawValue: row["kind"] as String) ?? .other,
            canonicalUnit: row["canonical_unit"] as String?,
            matchedVia: .curated, confidence: 1)
    }

    public func overrideHit(_ raw: String) async throws -> AliasHit? {
        try await writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT concept_id FROM resolver_override
                WHERE query_pattern = ? AND retired_at IS NULL LIMIT 1
                """, arguments: [raw])
            guard let conceptId: String = row?["concept_id"] else { return nil }
            return AliasHit(conceptId: conceptId, route: .override, priority: 0)
        }
    }

    public func resolveAlias(_ raw: String, locale: Locale) async throws -> [AliasHit] {
        // 精确匹配别名行（locale 参数保留给未来折叠表语义）。链序由 Domain
        // CodeResolver 统一施加（route 权重先于 priority）——本查询不参与
        // 链序裁决，仅保证同权重下的返回次序确定（priority 高者在前，
        // 平局按 rowid——插入次序恒定，防全量码表同文多概念时随引擎抖动）。
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT concept_id, route, priority FROM code_alias
                WHERE alias_text = ?
                ORDER BY priority DESC, rowid
                """, arguments: [raw])
            return rows.map { row in
                AliasHit(conceptId: row["concept_id"],
                         route: MatchRoute(rawValue: row["route"] as String) ?? .curated,
                         priority: row["priority"] as Int)
            }
        }
    }

    public func concept(_ id: String) async throws -> CodeResolution? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM code_concept WHERE id = ?
                """, arguments: [id]) else { return nil }
            return Self.codeResolution(from: row)
        }
    }

    /// FR25.2 单位特异编码（code_map：source_system='loinc-unit'，
    /// source_code='<conceptId>|<unit>'）。单条 JOIN 查询直接返回概念行——
    /// 不得在 read 块内嵌套调用 self.concept（嵌套读 = 潜在死锁面）。
    public func unitSpecificConcept(conceptId: String, unit: String) async throws -> CodeResolution? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id, c.canonical_code, c.coding_system, c.display_zh_hans,
                       c.display_en, c.kind, c.canonical_unit
                FROM code_map cm
                JOIN code_concept c ON c.id = cm.concept_id
                WHERE cm.source_system = 'loinc-unit' AND cm.source_code = ?
                LIMIT 1
                """, arguments: ["\(conceptId)|\(unit)"]) else { return nil }
            return Self.codeResolution(from: row)
        }
    }

    // MARK: - UnitIndex

    public func unit(_ code: String) async throws -> UcumUnit? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM ucum_unit WHERE unit_code = ?
                """, arguments: [code]) else { return nil }
            return UcumUnit(unitCode: row["unit_code"], family: row["family"],
                            dimension: row["dimension"], factor: row["factor"],
                            offset: row["offset"], kind: row["kind"])
        }
    }

    public func molarBridge(from: String, to: String, conceptId: String) async throws -> UcumMolarBridge? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM ucum_molar_bridge
                WHERE concept_id = ? AND from_unit = ? AND to_unit = ?
                """, arguments: [conceptId, from, to]) else { return nil }
            return UcumMolarBridge(conceptId: row["concept_id"],
                                   fromUnit: row["from_unit"], toUnit: row["to_unit"],
                                   factor: row["factor"], note: row["note"])
        }
    }
}
#endif
