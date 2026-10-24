#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import GRDB
import Domain
import Protocols

/// F11.4 健康问题管理（SP-49）数据仓：懒创建/手动新建/合并/归档/取消归档。
/// 2026-10-24 业主：名称/类别是官方目录身份，创建后不可改名或改类别。
/// 归档问题不出现在默认筛选（FR11.2）；合并两问题历史不丢（合并 = 建新主问题 +
/// 原问题归档 + 关联数据转移，audit 由调用方记）。
public actor HealthProblemStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct HealthProblemRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var name: String
        public var archived: Bool
        public var kind: String?
        public var bodyRegion: String?
        public var bodySite: String?
        /// 发生/确诊年份（v41）。nil = 用户明确「不详」或旧数据未登记。
        public var year: Int?
        /// v47：官方目录身份 + 个人别名。
        public var catalogId: String?
        public var alias: String?
        public var code: String?
        public var codeSystem: String?
        public var mappingVersion: String?
        public init(id: UUID, patientId: UUID, name: String, archived: Bool,
                    kind: String? = nil, bodyRegion: String? = nil, bodySite: String? = nil,
                    year: Int? = nil, catalogId: String? = nil, alias: String? = nil,
                    code: String? = nil, codeSystem: String? = nil,
                    mappingVersion: String? = nil) {
            self.id = id; self.patientId = patientId; self.name = name; self.archived = archived
            self.kind = kind; self.bodyRegion = bodyRegion; self.bodySite = bodySite
            self.year = year; self.catalogId = catalogId; self.alias = alias
            self.code = code; self.codeSystem = codeSystem
            self.mappingVersion = mappingVersion
        }
    }

    public func list(patientId: UUID, includeArchived: Bool = false) async throws -> [HealthProblemRow] {
        try await writer.read { db in
            // 多选保存（createMany）整批共享同一 created_at，缺 tiebreaker 时
            // 批内顺序由 SQLite 实现决定；rowid 让「同一时刻」也有稳定顺序
            let sql = includeArchived
                ? "SELECT * FROM health_problem WHERE patient_id = ? ORDER BY created_at DESC, rowid DESC"
                : "SELECT * FROM health_problem WHERE patient_id = ? AND archived = 0 ORDER BY created_at DESC, rowid DESC"
            return try Row.fetchAll(db, sql: sql, arguments: [patientId.uuidString]).map { row in
                HealthProblemRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                    patientId: patientId,
                    name: row["name"] as String,
                    archived: (row["archived"] as Int) == 1,
                    kind: row["kind"] as String?,
                    bodyRegion: row["body_region"] as String?,
                    bodySite: row["body_site"] as String?,
                    year: row["year"] as Int?,
                    catalogId: row["catalog_id"] as String?,
                    alias: row["alias"] as String?,
                    code: row["code"] as String?,
                    codeSystem: row["code_system"] as String?,
                    mappingVersion: row["mapping_version"] as String?)
            }
        }
    }

    /// 新建/懒创建（FR11.4：可从文档/观察/就诊懒创建或手动新建）
    @discardableResult
    public func create(patientId: UUID, name: String, now: Date = Date()) async throws -> UUID {
        // 懒创建（文档/观察/就诊）也先尝试官方目录；匹配不到才保留未映射，
        // 不伪造码值、不改用户原文。
        if let condition = HealthHistoryCatalog.condition(matching: name),
           let code = condition.code {
            return try await create(
                patientId: patientId, name: condition.name, kind: nil,
                bodyRegion: condition.regionID, bodySite: condition.organID,
                now: now, catalogId: condition.id, code: code,
                codeSystem: condition.codeSystem, mappingVersion: "医保版 2.0")
        }
        return try await create(patientId: patientId, name: name, kind: nil,
                                bodyRegion: nil, bodySite: nil, now: now)
    }

    public struct NewProblem: Sendable, Equatable {
        public var name: String
        public var kind: String?
        public var bodyRegion: String?
        public var bodySite: String?
        public var year: Int?
        public var catalogId: String?
        public var alias: String?
        public var code: String?
        public var codeSystem: String?
        public var mappingVersion: String?
        public init(name: String, kind: String?, bodyRegion: String?, bodySite: String?,
                    year: Int? = nil, catalogId: String? = nil, alias: String? = nil,
                    code: String? = nil, codeSystem: String? = nil,
                    mappingVersion: String? = nil) {
            self.name = name; self.kind = kind
            self.bodyRegion = bodyRegion; self.bodySite = bodySite
            self.year = year; self.catalogId = catalogId; self.alias = alias
            self.code = code; self.codeSystem = codeSystem
            self.mappingVersion = mappingVersion
        }
    }

    /// 新建健康史条目：kind = chronic/surgery；bodyRegion/bodySite 来自
    /// HealthHistoryCatalog 的稳定 id/显示名。目录未命中时保留原文并留空码值。
    @discardableResult
    public func create(patientId: UUID, name: String, kind: String?,
                       bodyRegion: String?, bodySite: String?,
                       now: Date = Date()) async throws -> UUID {
        // 显式创建也尝试官方目录（调用方未给码值时）；匹配不到保留原文。
        let mapped = HealthHistoryCatalog.condition(matching: name)
        return try await create(
            patientId: patientId, name: name, kind: kind,
            bodyRegion: bodyRegion ?? mapped?.regionID,
            bodySite: bodySite ?? mapped?.organID, now: now,
            catalogId: mapped?.id, code: mapped?.code,
            codeSystem: mapped?.code == nil ? nil : "ICD-10 医保版 2.0",
            mappingVersion: mapped?.code == nil ? nil : "医保版 2.0")
    }

    @discardableResult
    public func create(patientId: UUID, name: String, kind: String?,
                       bodyRegion: String?, bodySite: String?,
                       now: Date = Date(), catalogId: String?, code: String?,
                       codeSystem: String?, mappingVersion: String?) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try Self.insert(id: id, patientId: patientId,
                            problem: NewProblem(name: name, kind: kind,
                                                bodyRegion: bodyRegion, bodySite: bodySite,
                                                catalogId: catalogId, code: code,
                                                codeSystem: codeSystem,
                                                mappingVersion: mappingVersion),
                            now: now, db: db)
        }
        return id
    }

    /// 多选一次保存：同一事务，任一失败整体回滚（不产生半批记录）。
    @discardableResult
    public func createMany(patientId: UUID, problems: [NewProblem],
                           now: Date = Date()) async throws -> [UUID] {
        guard !problems.isEmpty else { return [] }
        return try await writer.write { db in
            var ids: [UUID] = []
            for problem in problems {
                let id = UUID()
                try Self.insert(id: id, patientId: patientId, problem: problem, now: now, db: db)
                ids.append(id)
            }
            return ids
        }
    }

    private static func insert(id: UUID, patientId: UUID, problem: NewProblem,
                               now: Date, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO health_problem
              (id, patient_id, name, kind, archived, body_region, body_site, year,
               catalog_id, alias, code, code_system, mapping_version, created_at, updated_at)
            VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.uuidString, patientId.uuidString, problem.name, problem.kind,
                             problem.bodyRegion, problem.bodySite, problem.year,
                             problem.catalogId, problem.alias, problem.code,
                             problem.codeSystem, problem.mappingVersion,
                             now.timeIntervalSince1970, now.timeIntervalSince1970])
    }

    /// 用户后期修改（2026-10-23 业主：慢性病/手术需提供修改入口）。
    public struct ProblemUpdate: Sendable, Equatable {
        public var bodyRegion: String?
        public var bodySite: String?
        public var year: Int?
        public var alias: String?
        public init(bodyRegion: String?, bodySite: String?,
                    year: Int?, alias: String? = nil) {
            self.bodyRegion = bodyRegion; self.bodySite = bodySite
            self.year = year; self.alias = alias
        }
    }

    /// 后期修改：**名称/类别是官方目录身份，永不更新**（2026-10-24 业主）。
    /// 只改年份、官方映射内的部位/器官与个人别名；行不存在必须抛错。
    public func update(id: UUID, _ update: ProblemUpdate, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE health_problem
                   SET body_region = ?, body_site = ?, year = ?, alias = ?, updated_at = ?
                 WHERE id = ?
                """, arguments: [update.bodyRegion, update.bodySite, update.year,
                                  update.alias, now.timeIntervalSince1970, id.uuidString])
            guard db.changesCount > 0 else { throw StoreError.notFound(id) }
        }
    }

    /// 硬删除用户自报的健康史条目（表无 deleted_at，见 §4.3 DDL）。
    /// BR-002：只删标签，不删医疗事实——关联的 `diagnosis`/`observation`
    /// 行保留，仅把 `health_problem_id` 置空（外键无 ON DELETE，必须先解引用，
    /// 否则 DELETE 触发 FK 约束失败）。同一事务内完成，不产生半删除状态。
    public func delete(id: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM health_problem WHERE id = ?",
                                   arguments: [id.uuidString]) != nil else {
                throw StoreError.notFound(id)
            }
            let stamp = now.timeIntervalSince1970
            try db.execute(sql: """
                UPDATE diagnosis SET health_problem_id = NULL, updated_at = ?
                 WHERE health_problem_id = ?
                """, arguments: [stamp, id.uuidString])
            try db.execute(sql: """
                UPDATE observation SET health_problem_id = NULL, updated_at = ?
                 WHERE health_problem_id = ?
                """, arguments: [stamp, id.uuidString])
            try db.execute(sql: "DELETE FROM health_problem WHERE id = ?",
                           arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw StoreError.notFound(id) }
        }
    }

    /// 归档/取消归档（FR11.4：归档问题不出现在默认筛选；取消归档可恢复）
    public func setArchived(id: UUID, archived: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE health_problem SET archived = ?, updated_at = ? WHERE id = ?",
                           arguments: [archived ? 1 : 0, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// 合并：主问题保留、被合并问题归档（各自历史不丢——数据行不删除）。
    /// 关联数据转移（document/observation 的 problem 引用）由后续版本承载；
    /// 本方法保证「合并」语义的最小不变量：被合并问题从默认筛选消失。
    public func merge(primary: UUID, into secondary: UUID, now: Date = Date()) async throws {
        // 审查修复：① primary != secondary（同一行合并自己 = 幸存者被归档）；
        // ② 被合并问题必须存在且未归档（UPDATE 0 行曾静默「成功」）；
        // ③ 主问题存在性校验（原校验的是被合并侧，主问题缺失时抛 notFound 语义相反）
        guard primary != secondary else { throw StoreError.sameProblem }
        try await writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM health_problem WHERE id = ? AND archived = 0",
                                   arguments: [secondary.uuidString]) != nil else {
                throw StoreError.notFound(secondary)
            }
            // ③ 主问题（幸存侧）存在性校验（对称守卫）：主问题缺失时并库
            //    仍会把被合并侧归档、无幸存者——用户问题从默认筛选静默消失
            guard try Row.fetchOne(db, sql: "SELECT id FROM health_problem WHERE id = ? AND archived = 0",
                                   arguments: [primary.uuidString]) != nil else {
                throw StoreError.notFound(primary)
            }
            try db.execute(sql: "UPDATE health_problem SET archived = 1, updated_at = ? WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, secondary.uuidString])
            guard db.changesCount > 0 else { throw StoreError.notFound(secondary) }
        }
    }

    public enum StoreError: Error, LocalizedError {
        case notFound(UUID)
        case sameProblem
        public var errorDescription: String? { "健康问题操作失败: \(self)" }
    }
}
#endif
