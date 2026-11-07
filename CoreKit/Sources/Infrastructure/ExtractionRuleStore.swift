// 平台守卫与 Package.swift 的 GRDB 条件依赖严格镜像（同 GRDBStore.swift）：
// Linux 上 `canImport(GRDB)` 为 true 但 CSQLite 不可链接，必须用 os 守卫。
#if os(iOS) || os(macOS)
// linux-blind: GRDB/SQLite 规则库（Apple 平台） —— Linux 只编译下方的空实现
import Foundation
import GRDB
import Domain
import Protocols

/// 抽取规则库（2026-11-07 业主：规则存数据库、随 App 上线；Core ML 发现的新
/// 规则及时收集）。两层：
///
/// 1. **随包只读种子** `Resources/ExtractionRules/extraction-rules-v1.sqlite`
///    —— 键/类型仍由 Swift `ExtractionSpecRegistry` 定义，DB 只提供别名数据。
/// 2. **端侧可写覆盖** Application Support/…/rules-overlay.sqlite
///    —— Core ML 未知标签先落 `candidate`（模型单独证据权重为 0），用户确认
///    累计强证据；达到 ≥5 次确认且 ≥3 份文档才转 `active`。
///
/// 缺库/损坏/只读失败 → 空覆盖，规则引擎继续用码内 spec（fail-closed）。
/// 零网络、零遥测；只存标签文本与计数，绝不存字段值/患者数据。
public actor ExtractionRuleStore: ExtractionRuleCataloging {
    private let base: DatabaseQueue?
    private let overlay: DatabaseQueue?
    private var cache: ExtractionRuleOverlay?
    private let now = ISO8601DateFormatter()

    public init(bundle: Bundle = .main) {
        let baseURL = bundle.url(forResource: "ExtractionRules", withExtension: nil)?
            .appendingPathComponent("extraction-rules-v1.sqlite")
        self.base = baseURL.flatMap { try? DatabaseQueue(path: $0.path, configuration: Self.readOnlyConfiguration()) }   // try?-ok: 缺库=空覆盖

        let support = try? FileManager.default.url(for: .applicationSupportDirectory,   // try?-ok: 无目录=无覆盖
                                                   in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let directory = support?.appendingPathComponent("VitaLiber/Rules", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)   // try?-ok: 创建失败=无覆盖
            // 派生数据：不进备份、不进导出；锁屏后仍可读（抽取不在锁屏态运行）。
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(values)   // try?-ok: 标记失败不影响打开
            let url = directory.appendingPathComponent("rules-overlay.sqlite")
            var config = Configuration()
            config.foreignKeysEnabled = true
            self.overlay = try? DatabaseQueue(path: url.path, configuration: config)   // try?-ok: 打开失败=无覆盖
        } else {
            self.overlay = nil
        }
        if let overlay {
            try? overlay.write { db in   // try?-ok: 建表失败=覆盖不可用
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS rule_candidate(
                      card_kind TEXT NOT NULL,
                      field_key TEXT NOT NULL,
                      candidate_kind TEXT NOT NULL DEFAULT 'alias',
                      value TEXT NOT NULL,
                      source_kind TEXT NOT NULL,
                      evidence_count INTEGER NOT NULL DEFAULT 0,
                      distinct_doc_count INTEGER NOT NULL DEFAULT 0,
                      status TEXT NOT NULL,
                      created_at TEXT NOT NULL,
                      last_seen TEXT NOT NULL,
                      PRIMARY KEY(card_kind, field_key, candidate_kind, value));
                    CREATE TABLE IF NOT EXISTS rule_candidate_doc(
                      card_kind TEXT NOT NULL,
                      field_key TEXT NOT NULL,
                      value TEXT NOT NULL,
                      doc_pseudonym TEXT NOT NULL,
                      seen_at TEXT NOT NULL,
                      PRIMARY KEY(card_kind, field_key, value, doc_pseudonym));
                    CREATE TABLE IF NOT EXISTS rule_change_log(
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      at TEXT NOT NULL,
                      action TEXT NOT NULL,
                      card_kind TEXT,
                      field_key TEXT,
                      value TEXT,
                      from_status TEXT,
                      to_status TEXT,
                      reason TEXT);
                    """)
            }
        }
    }

    private static func readOnlyConfiguration() -> Configuration {
        var config = Configuration()
        config.readonly = true
        config.foreignKeysEnabled = true
        return config
    }

    public func activeOverlay() async -> ExtractionRuleOverlay {
        if let cache { return cache }
        var entries: [ExtractionRuleAlias] = []
        if let base {
            let rows = (try? await base.read { db in   // try?-ok: 读失败=该层丢弃
                try Row.fetchAll(db, sql: """
                    SELECT card_kind, field_key, alias, source_kind, status
                    FROM rule_alias WHERE status = 'active'
                    """)
            }) ?? []
            entries += rows.compactMap { row in
                guard let kind: String = row["card_kind"], let key: String = row["field_key"],
                      let alias: String = row["alias"] else { return nil }
                let sourceKind: String = row["source_kind"] ?? "specSeed"
                return ExtractionRuleAlias(kind: kind, key: key, alias: alias,
                                           source: ExtractionRuleSource(rawValue: sourceKind) ?? .specSeed,
                                           status: .active)
            }
        }
        if let overlay {
            let rows = (try? await overlay.read { db in   // try?-ok: 读失败=该层丢弃
                try Row.fetchAll(db, sql: """
                    SELECT card_kind, field_key, value, evidence_count, distinct_doc_count
                    FROM rule_candidate
                    WHERE candidate_kind = 'alias' AND status = 'active'
                    """)
            }) ?? []
            entries += rows.compactMap { row in
                guard let kind: String = row["card_kind"], let key: String = row["field_key"],
                      let value: String = row["value"] else { return nil }
                return ExtractionRuleAlias(kind: kind, key: key, alias: value,
                                           source: .coreMLObserved, status: .active,
                                           evidenceCount: row["evidence_count"] ?? 0,
                                           confirmedCount: row["distinct_doc_count"] ?? 0)
            }
        }
        let overlayValue = ExtractionRuleOverlay(aliases: entries)
        cache = overlayValue
        return overlayValue
    }

    public func observe(_ observations: [ExtractionRuleObservation]) async {
        guard let overlay else { return }
        let timestamp = now.string(from: Date())
        try? await overlay.write { db in   // try?-ok: 收集失败不影响抽取
            for item in observations {
                guard Self.isLearnableAlias(item.alias) else { continue }
                try db.execute(sql: """
                    INSERT INTO rule_candidate
                      (card_kind, field_key, candidate_kind, value, source_kind,
                       evidence_count, distinct_doc_count, status, created_at, last_seen)
                    VALUES (?, ?, 'alias', ?, 'coreml_observed', 0, 0, 'candidate', ?, ?)
                    ON CONFLICT(card_kind, field_key, candidate_kind, value) DO UPDATE SET
                      last_seen = excluded.last_seen
                    """, arguments: [item.kind, item.key, item.alias, timestamp, timestamp])
            }
        }
    }

    public func confirm(kind: String, key: String, alias: String, documentPseudonym: String) async {
        guard let overlay, Self.isLearnableAlias(alias) else { return }
        let timestamp = now.string(from: Date())
        try? await overlay.write { db in   // try?-ok: 确认失败不影响抽取
            // 同别名已绑定到另一个键 → 冲突，abstain（不落库、不猜）。
            let conflict = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM rule_candidate
                  WHERE card_kind = ? AND candidate_kind = 'alias' AND value = ? AND field_key <> ?)
                """, arguments: [kind, alias, key]) ?? false
            guard !conflict else { return }
            try db.execute(sql: """
                INSERT INTO rule_candidate
                  (card_kind, field_key, candidate_kind, value, source_kind,
                   evidence_count, distinct_doc_count, status, created_at, last_seen)
                VALUES (?, ?, 'alias', ?, 'user_confirmed', 1, 0, 'candidate', ?, ?)
                ON CONFLICT(card_kind, field_key, candidate_kind, value) DO UPDATE SET
                  evidence_count = evidence_count + 1,
                  source_kind = 'user_confirmed',
                  last_seen = excluded.last_seen
                """, arguments: [kind, key, alias, timestamp, timestamp])
            try db.execute(sql: """
                INSERT OR IGNORE INTO rule_candidate_doc
                  (card_kind, field_key, value, doc_pseudonym, seen_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [kind, key, alias, documentPseudonym, timestamp])
            let docs = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rule_candidate_doc
                WHERE card_kind = ? AND field_key = ? AND value = ?
                """, arguments: [kind, key, alias]) ?? 0
            let evidence = try Int.fetchOne(db, sql: """
                SELECT evidence_count FROM rule_candidate
                WHERE card_kind = ? AND field_key = ? AND candidate_kind = 'alias' AND value = ?
                """, arguments: [kind, key, alias]) ?? 0
            try db.execute(sql: """
                UPDATE rule_candidate SET distinct_doc_count = ?
                WHERE card_kind = ? AND field_key = ? AND candidate_kind = 'alias' AND value = ?
                """, arguments: [docs, kind, key, alias])
            // 激活门槛（与规则库设计一致）：≥5 次用户确认、≥3 份文档。
            if evidence >= 5, docs >= 3 {
                try db.execute(sql: """
                    UPDATE rule_candidate SET status = 'active'
                    WHERE card_kind = ? AND field_key = ? AND candidate_kind = 'alias' AND value = ?
                    """, arguments: [kind, key, alias])
                try db.execute(sql: """
                    INSERT INTO rule_change_log
                      (at, action, card_kind, field_key, value, from_status, to_status, reason)
                    VALUES (?, 'activate', ?, ?, ?, 'candidate', 'active', 'evidence>=5,docs>=3')
                    """, arguments: [timestamp, kind, key, alias])
            }
        }
        cache = nil   // 下次读面重建
    }

    /// 只学习「像标签」的短文本：2–20 字符、无数字/空白、非空。
    /// 患者姓名/编号/日期等含数字或过长串直接拒绝，避免 PHI 入库。
    static func isLearnableAlias(_ alias: String) -> Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...20).contains(trimmed.count) else { return false }
        return !trimmed.contains(where: { $0.isNumber || $0.isWhitespace })
    }
}

#else
import Foundation
import Domain
import Protocols

/// Linux 型检空单元：GRDB 不链接，规则库不可用 → 恒空覆盖（码内 spec 兜底）。
public actor ExtractionRuleStore: ExtractionRuleCataloging {
    public init(bundle: Bundle = .main) {}
    public func activeOverlay() async -> ExtractionRuleOverlay { ExtractionRuleOverlay() }
    public func observe(_ observations: [ExtractionRuleObservation]) async {}
    public func confirm(kind: String, key: String, alias: String, documentPseudonym: String) async {}
}
#endif
