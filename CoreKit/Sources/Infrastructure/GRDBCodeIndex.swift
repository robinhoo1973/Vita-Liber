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
/// - 种子装载幂等（INSERT OR IGNORE）：码表表内按 bundle_version 整批替换时
///   （升级路径）先清旧版本行再插入，`resolver_override` 用户纠错行永不触碰
///   （FR25.11 编码只补不覆）；
/// - 全部读取走共享 DatabasePool 的并发读路径（§4.4）。
public actor GRDBCodeIndex: CodeIndex, UnitIndex {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 首次使用装载内置种子（幂等：表空才写；bundle_version 元数据可追溯）。
    /// 生产装配层在 AppContainer 启动时调用一次；测试可跳过（注入空库）。
    public func loadBundledSeedsIfNeeded() async throws {
        try await writer.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM code_concept") == 0 else {
                return   // 已装载（升级路径另行走 bundle 替换）
            }
            try Self.insertSeeds(db)
        }
    }

    private static func insertSeeds(_ db: Database) throws {
        let v = CodeSetSeeds.bundleVersion
        for s in CodeSetSeeds.concepts {
            try db.execute(sql: """
                INSERT OR IGNORE INTO code_concept
                  (id, canonical_code, coding_system, display_zh_hans, display_en,
                   kind, canonical_unit, bundle_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [s.id, s.canonicalCode, s.codingSystem.rawValue,
                                 s.displayZhHans, s.displayEn, s.kind.rawValue,
                                 s.canonicalUnit, v])
        }
        for s in CodeSetSeeds.aliases {
            try db.execute(sql: """
                INSERT OR IGNORE INTO code_alias
                  (alias_text, locale, concept_id, route, priority, bundle_version)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [s.aliasText, s.locale, s.conceptId,
                                 s.route.rawValue, s.priority, v])
        }
        for s in CodeSetSeeds.unitSpecific {
            try db.execute(sql: """
                INSERT OR IGNORE INTO code_map
                  (source_system, source_code, concept_id, bundle_version)
                VALUES ('loinc-unit', ?, ?, ?)
                """, arguments: ["\(s.conceptId)|\(s.unit)", s.targetConceptId, v])
        }
        for s in CodeSetSeeds.overrides {
            try db.execute(sql: """
                INSERT OR IGNORE INTO resolver_override
                  (id, query_pattern, concept_id, note, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, s.queryPattern, s.conceptId,
                                 s.note, Date().timeIntervalSince1970])
        }
        for s in CodeSetSeeds.ucumUnits {
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
        // CodeResolver 统一施加（route 权重先于 priority）——本查询的排序
        // 仅作一致排列，不得依赖它做链序裁决。
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT concept_id, route, priority FROM code_alias
                WHERE alias_text = ?
                ORDER BY CASE route WHEN 'curated' THEN 2 WHEN 'fold' THEN 1 END DESC,
                         priority DESC
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
            return CodeResolution(
                conceptId: row["id"], canonicalCode: row["canonical_code"],
                codingSystem: CodingSystem(rawValue: row["coding_system"] as String) ?? .loinc,
                displayZhHans: row["display_zh_hans"], displayEn: row["display_en"],
                kind: CodeKind(rawValue: row["kind"] as String) ?? .other,
                canonicalUnit: row["canonical_unit"] as String?,
                matchedVia: .curated, confidence: 1)
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
            return CodeResolution(
                conceptId: row["id"], canonicalCode: row["canonical_code"],
                codingSystem: CodingSystem(rawValue: row["coding_system"] as String) ?? .loinc,
                displayZhHans: row["display_zh_hans"], displayEn: row["display_en"],
                kind: CodeKind(rawValue: row["kind"] as String) ?? .other,
                canonicalUnit: row["canonical_unit"] as String?,
                matchedVia: .curated, confidence: 1)
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
