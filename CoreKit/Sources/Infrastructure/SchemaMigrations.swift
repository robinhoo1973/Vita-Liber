import Foundation

/// 迁移版本序列（dev-pm §8.5「任何表结构变更走迁移版本递增 + 金样回归，历史迁移文件只读不改」）
///
/// **为什么需要这个文件**：GRDBStore 早期实现是「`user_version == 0` 建全量库，
/// 否则什么都不做」——`version > 0` 是空分支。后果是：**v1 之后的任何表结构变更
/// 对已装机的库永远不会生效**，新列在旧库上缺失，查询在运行期炸。这与 ERR#27/#30
/// 同族（缺证据被当成有证据）的另一面：**缺迁移被当成不需要迁移**。
///
/// **为什么不用 GRDB 的 `DatabaseMigrator`**（偏离 tech-spec §4.3 记述，已回写）：
/// 现网/开发库的版本账本已经落在 `PRAGMA user_version` 上，而 `DatabaseMigrator`
/// 自建 `grdb_migrations` 表记账。两套账本并存时，「v1 建过但 grdb_migrations 为空」
/// 的库会被判成全新库而重跑 baseline，直接「表已存在」崩溃——正是本项要修的那个 bug。
/// 单一账本（user_version 单调整数）语义更窄、可在 Linux 侧纯字符串断言、
/// 且与既有数据兼容，故保留 user_version 作为唯一事实源。
///
/// **纪律**：`steps` 只许追加，既有条目一律只读；每步 SQL 必须**幂等**
/// （ALTER 前查 `pragma_table_info`），因为「baseline 已含新列的全新库」与
/// 「停留在旧版本的老库」会走到同一条升级路径上。
public enum SchemaMigrations {

    public struct Step: Sendable, Equatable {
        /// 目标版本号（PRAGMA user_version 达到该值即视为本步已应用）
        public let version: Int
        /// 人类可读标识（台账/日志用）
        public let name: String
        /// 幂等 SQL（可多语句）
        public let sql: String
        public init(version: Int, name: String, sql: String) {
            self.version = version; self.name = name; self.sql = sql
        }
    }

    /// baseline（v1）= SchemaV2.ddl 全量建表。全新库直接跳到 `latestVersion`。
    public static let baselineVersion = 1

    /// 追加式版本序列。**只许在末尾追加**。
    public static let steps: [Step] = [
        Step(version: 2, name: "metric-reference-band",
             sql: """
             -- F7 / FR7.2 铁律：不同医院的参考范围不得合并成一条正常带。
             -- v1 的 metric_sample 完全没有参考范围列，导致「三家医院各自显示参考范围」
             -- 在数据层无处落脚（tech-spec §5.29 的 TrendSeries 片段只写了单数
             -- referenceRange?，DDL 照抄，漏掉了 FR7.2 的复数语义）。
             -- ref_source_label = A 级来源标签（医院/实验室名），是「各自成带」的分组键。
             ALTER TABLE metric_sample ADD COLUMN ref_low REAL;
             ALTER TABLE metric_sample ADD COLUMN ref_high REAL;
             ALTER TABLE metric_sample ADD COLUMN ref_source_label TEXT;
             """),
        Step(version: 3, name: "guideline-thresholds-json",
             sql: """
             -- F16 信源库阈值：v1 的 guideline_source 只有书目字段，没有阈值数字，
             -- FR16.4「医学数字单一事实源」在数据层无处落脚。
             -- 用单一 JSON 列承载 L1-L3 阈值档位：档位随指南版本演进而变，
             -- 版本升级 = 整条替换而非 ALTER（理由见 GuidelineSource.Thresholds）。
             ALTER TABLE guideline_source ADD COLUMN thresholds_json TEXT;
             -- 按指标检索的键：metric_key 是查询入口，unit 保证阈值单位不外泄。
             -- 首轮设计漏了这两列，导致「按指标取信源」在库层无处检索
             -- （阈值为 JSON，且 Thresholds 形态本身不含 metricKey）。
             ALTER TABLE guideline_source ADD COLUMN metric_key TEXT;
             ALTER TABLE guideline_source ADD COLUMN unit TEXT;
             """),
        Step(version: 4, name: "emergency-card-selection",
             sql: """
             -- F15 急救卡的用户选择语义：FR15.1「必须由用户逐项选择，不能静默加入」。
             -- v1 无任何表承载「用户选了哪几项」——若聚合查询直接 JOIN 数据表，
             -- 就是把「数据存在」当成「用户同意入卡」，恰是 BR-003 要防的静默行为。
             -- 本表只记选择，数据仍在原表：退选=删行，不碰原始数据。
             CREATE TABLE IF NOT EXISTS emergency_card_selection (
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               item_id TEXT NOT NULL,
               item_kind TEXT NOT NULL,            -- medication/allergy/healthProblem/contact
               selected_at REAL NOT NULL,
               PRIMARY KEY(patient_id, item_id));
             """),
        Step(version: 5, name: "sent-message-status",
             sql: """
             -- F24.2 发送状态页：本地只记「发过什么、状态如何」，不存消息原文。
             CREATE TABLE IF NOT EXISTS sent_message (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               kind TEXT NOT NULL,
               recipient TEXT NOT NULL,
               status TEXT NOT NULL DEFAULT 'sent' CHECK(status IN ('sent','ackPending','acked','timeout')),
               sent_at REAL NOT NULL, updated_at REAL NOT NULL);
             """),
    ]

    /// 全新库建库后应落到的版本号
    public static var latestVersion: Int { steps.last?.version ?? baselineVersion }

    /// 从 `current` 升到最新所需的步骤（升序）。current ≥ latest 时为空。
    public static func pending(from current: Int) -> [Step] {
        steps.filter { $0.version > current }.sorted { $0.version < $1.version }
    }

    /// 幂等化：把一条 `ALTER TABLE <t> ADD COLUMN <c> <type>` 包成
    /// 「列不存在才执行」的形态。SQLite 无 `ADD COLUMN IF NOT EXISTS`，
    /// 而本序列必须能在「baseline 已含该列」的全新库上重复执行而不报错。
    /// 返回 nil 表示该语句不是 ADD COLUMN 形态，调用方原样执行。
    public static func addColumnParts(_ statement: String) -> (table: String, column: String)? {
        let s = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // ALTER TABLE <t> ADD COLUMN <c> <type...>
        guard parts.count >= 6,
              parts[0].uppercased() == "ALTER", parts[1].uppercased() == "TABLE",
              parts[3].uppercased() == "ADD", parts[4].uppercased() == "COLUMN"
        else { return nil }
        return (table: parts[2], column: parts[5])
    }

    /// 把多语句 SQL 拆成单条（去注释、去空行）。迁移 SQL 由本仓维护，
    /// 不含字符串字面量里的分号，故按分号切分是安全的。
    public static func statements(_ sql: String) -> [String] {
        sql.split(separator: "\n")
            .map { line -> String in
                guard let r = line.range(of: "--") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
