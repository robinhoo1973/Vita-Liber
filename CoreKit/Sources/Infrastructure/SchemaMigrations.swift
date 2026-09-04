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
        Step(version: 6, name: "fts-sensitive-trigger-hardening",
             sql: """
             -- BR-007/008 敏感内容不入检索索引：SchemaV2.ddl 的触发器只对全新库生效，
             -- v1-v5 老库沿用旧触发器会继续把敏感 notes 索引进 document_fts，
             -- 升级设备上的敏感正文仍可被搜中——重建触发器 + 全量重洗索引。
             -- 两个 SQLite 实测语义（3.46，与 iOS 同代）：
             -- ① FTS5 的 delete 特殊命令按「已索引值」匹配，值不一致直接报
             --    "database disk image is malformed"——脱敏插入（NULL）后必须用
             --    同样脱敏的值做删除标记，故 AD/AU 触发器删除半段与插入半段
             --    同用 CASE WHEN old.is_sensitive = 0 守卫；
             -- ② 老库敏感行的已索引值是「旧触发器形态」（ocr NULL、notes 原文），
             --    逐行 delete 无从对齐，故用 delete-all 整表清空 + 脱敏重灌，
             --    天然幂等（重跑=再清再灌）。
             DROP TRIGGER IF EXISTS document_file_fts_ai;
             DROP TRIGGER IF EXISTS document_file_fts_au;
             DROP TRIGGER IF EXISTS document_file_fts_ad;
             -- 执行次序在此显式写明：先删旧触发器 → 重洗索引 → 再挂新触发器。
             -- 早前是靠切分器「把 CREATE TRIGGER 统一挪到末尾」的副作用达成同样次序，
             -- 属隐式契约（切分器一改次序即静默错序），故改为「书写顺序就是执行顺序」。
             -- 索引重洗：external-content 表逐行 delete 会踩「值不一致即报错」，
             -- delete-all 是唯一无值匹配的整表清空通道；contentless 同样禁用
             -- DELETE FROM（3.46 实测 "cannot DELETE from contentless fts5 table"），
             -- 也用 delete-all 特殊命令清空后重灌。
             INSERT INTO document_fts(document_fts) VALUES('delete-all');
             INSERT INTO document_fts(rowid, title, ocr_text, notes)
               SELECT rowid, title,
                      CASE WHEN is_sensitive = 0 THEN ocr_text END,
                      CASE WHEN is_sensitive = 0 THEN notes END
               FROM document_file;
             INSERT INTO document_fts_2gram(document_fts_2gram) VALUES('delete-all');
             INSERT INTO document_fts_2gram(rowid, title_2gram, ocr_2gram, note_2gram)
               SELECT rowid, bigrams(title),
                      bigrams(CASE WHEN is_sensitive = 0 THEN ocr_text END),
                      bigrams(CASE WHEN is_sensitive = 0 THEN notes END)
               FROM document_file;
             CREATE TRIGGER document_file_fts_ai AFTER INSERT ON document_file BEGIN
               INSERT INTO document_fts(rowid, title, ocr_text, notes)
                 VALUES (new.rowid, new.title,
                         CASE WHEN new.is_sensitive = 0 THEN new.ocr_text END,
                         CASE WHEN new.is_sensitive = 0 THEN new.notes END);
               INSERT INTO document_fts_2gram(rowid, title_2gram, ocr_2gram, note_2gram)
                 VALUES (new.rowid, bigrams(new.title),
                         bigrams(CASE WHEN new.is_sensitive = 0 THEN new.ocr_text END),
                         bigrams(CASE WHEN new.is_sensitive = 0 THEN new.notes END));
             END;
             CREATE TRIGGER document_file_fts_ad AFTER DELETE ON document_file BEGIN
               INSERT INTO document_fts(document_fts, rowid, title, ocr_text, notes)
                 VALUES ('delete', old.rowid, old.title,
                         CASE WHEN old.is_sensitive = 0 THEN old.ocr_text END,
                         CASE WHEN old.is_sensitive = 0 THEN old.notes END);
               INSERT INTO document_fts_2gram(document_fts_2gram, rowid, title_2gram, ocr_2gram, note_2gram)
                 VALUES ('delete', old.rowid, bigrams(old.title),
                         bigrams(CASE WHEN old.is_sensitive = 0 THEN old.ocr_text END),
                         bigrams(CASE WHEN old.is_sensitive = 0 THEN old.notes END));
             END;
             CREATE TRIGGER document_file_fts_au AFTER UPDATE OF title, ocr_text, notes, is_sensitive ON document_file BEGIN
               INSERT INTO document_fts(document_fts, rowid, title, ocr_text, notes)
                 VALUES ('delete', old.rowid, old.title,
                         CASE WHEN old.is_sensitive = 0 THEN old.ocr_text END,
                         CASE WHEN old.is_sensitive = 0 THEN old.notes END);
               INSERT INTO document_fts_2gram(document_fts_2gram, rowid, title_2gram, ocr_2gram, note_2gram)
                 VALUES ('delete', old.rowid, bigrams(old.title),
                         bigrams(CASE WHEN old.is_sensitive = 0 THEN old.ocr_text END),
                         bigrams(CASE WHEN old.is_sensitive = 0 THEN old.notes END));
               INSERT INTO document_fts(rowid, title, ocr_text, notes)
                 VALUES (new.rowid, new.title,
                         CASE WHEN new.is_sensitive = 0 THEN new.ocr_text END,
                         CASE WHEN new.is_sensitive = 0 THEN new.notes END);
               INSERT INTO document_fts_2gram(rowid, title_2gram, ocr_2gram, note_2gram)
                 VALUES (new.rowid, bigrams(new.title),
                         bigrams(CASE WHEN new.is_sensitive = 0 THEN new.ocr_text END),
                         bigrams(CASE WHEN new.is_sensitive = 0 THEN new.notes END));
             END;
             """),
        Step(version: 7, name: "plan-lifecycle-history",
             sql: """
             -- FR9.15 计划历史全程保留（开始/调整/暂停/恢复/结束时间轴，
             -- 供「给医生看」视图引用）：medication_plan 只有当前态列，
             -- 历史事件需要独立 append-only 表。生命周期写操作与事件
             -- 落库同事务（UnitOfWork），历史与状态永不脱节。
             CREATE TABLE IF NOT EXISTS plan_lifecycle_event (
               id TEXT PRIMARY KEY,
               plan_id TEXT NOT NULL REFERENCES medication_plan(id),
               kind TEXT NOT NULL CHECK(kind IN ('started','edited','paused','resumed','ended')),
               occurred_at REAL NOT NULL,
               note TEXT);
             CREATE INDEX IF NOT EXISTS idx_plan_event_plan ON plan_lifecycle_event(plan_id, occurred_at);
             """),
        Step(version: 8, name: "encounter-full-fields",
             sql: """
             -- FR4.1 就诊事件字段全集：v1 的 encounter 只有 id/patient/date/kind/
             -- diagnosis/advice/fee——医院/科室/医生/主诉/复诊要求与改期历史
             -- 无列可落（SP-08 详情页与 FR10.7 改期历史的数据源）。
             ALTER TABLE encounter ADD COLUMN hospital TEXT;
             ALTER TABLE encounter ADD COLUMN department TEXT;
             ALTER TABLE encounter ADD COLUMN doctor TEXT;
             ALTER TABLE encounter ADD COLUMN chief_complaint TEXT;
             ALTER TABLE encounter ADD COLUMN follow_up_requirement TEXT;
             ALTER TABLE encounter ADD COLUMN rescheduled_from_id TEXT REFERENCES encounter(id);
             -- 预约改期历史（FR10.7：原预约保留历史并生成新草稿）
             ALTER TABLE appointment ADD COLUMN rescheduled_from_id TEXT REFERENCES appointment(id);
             ALTER TABLE appointment ADD COLUMN cancel_reason TEXT;
             ALTER TABLE appointment ADD COLUMN doctor TEXT;
             ALTER TABLE appointment ADD COLUMN address TEXT;
             ALTER TABLE appointment ADD COLUMN booking_no TEXT;
             ALTER TABLE appointment ADD COLUMN source TEXT;
             ALTER TABLE appointment ADD COLUMN items_to_bring TEXT;
             ALTER TABLE appointment ADD COLUMN notes TEXT;
             """),
        Step(version: 9, name: "member-soft-delete",
             sql: """
             -- FR3.4 删除成员：资料保留、归属标记清除——软删成员行（deleted_at），
             -- 数据行保留 patient_id 指向，「未归属」筛选 = deleted_at 非空。
             ALTER TABLE patient_profile ADD COLUMN deleted_at REAL;
             """),
        Step(version: 10, name: "asset-parent-link",
             sql: """
             -- §11-15 清偿：敏感资产父资产引用（原图→blur 双产物的显式父子链，
             -- 删除/对账时按父级清理，不依赖命名约定推断）。
             ALTER TABLE asset ADD COLUMN parent_id TEXT REFERENCES asset(id);
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

    /// 把多语句 SQL 拆成单条，**保持书写顺序**。
    ///
    /// 为什么要切分而不是整块 `db.execute`：GRDBStore 需要对每条 `ALTER TABLE … ADD COLUMN`
    /// 做「列已存在则跳过」的幂等处理（SQLite 无 `ADD COLUMN IF NOT EXISTS`），
    /// 这要求语句级粒度。
    ///
    /// 旧实现有两处「今天恰好对」的隐患，均已修掉：
    /// ① **错序**：把所有 `CREATE TRIGGER` 收集后统一追加到末尾，执行顺序与书写顺序不一致。
    ///    v6 恰好想要这个次序，于是隐患被掩盖；后续任何「先建触发器、再灌依赖它的数据」的
    ///    步骤都会静默错序——SQLite 对两种顺序都不报错，只是结果不同（触发器没被触发）。
    ///    v6 现已把预期次序写进 SQL 本身，不再依赖切分器的副作用。
    /// ② **脆弱终止符**：触发器体的结束靠 `END;` 独占一行的字面约定。`END;` 与其他内容同行、
    ///    或体内出现 `CASE … END`，都会切错（截断或吞掉后续语句）。迁移半途而废发生在
    ///    升级设备上，且 `PRAGMA user_version` 已推进 → 丢失的 DDL 永不重放。
    ///
    /// 现在按字符扫描：字符串字面量（含 `''` 转义）、`--` 行注释、`/* */` 块注释内的分号
    /// 不作边界；触发器体由 `BEGIN`…`END` 配对识别，并对体内 `CASE … END` 计数。
    public static func statements(_ sql: String) -> [String] {
        var out: [String] = []
        var current = ""
        var word = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var inLineComment = false
        var inBlockComment = false
        var sawCreateTrigger = false
        var inTriggerBody = false
        var caseDepth = 0

        func endStatement() {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            current = ""
            sawCreateTrigger = false
            inTriggerBody = false
            caseDepth = 0
        }

        // 关键字只在「非字符串、非注释」态结算，因此 'END;' 之类的字面量不会误判
        func closeWord() {
            guard !word.isEmpty else { return }
            switch word.uppercased() {
            case "TRIGGER":
                if current.uppercased().contains("CREATE") { sawCreateTrigger = true }
            case "BEGIN":
                if sawCreateTrigger, !inTriggerBody { inTriggerBody = true }
            case "CASE":
                // 触发器体内的 CASE ... END 必须计数，否则 CASE 的 END 会被
                // 当成体结束标记，把后续语句吞进触发器
                if inTriggerBody { caseDepth += 1 }
            case "END":
                if inTriggerBody {
                    if caseDepth > 0 { caseDepth -= 1 } else { inTriggerBody = false }
                }
            default:
                break
            }
            word = ""
        }

        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if inLineComment {
                if c == "\n" { inLineComment = false; current.append(c) }
                i += 1; continue
            }
            if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; i += 2; continue }
                i += 1; continue
            }
            if inSingleQuote {
                current.append(c)
                if c == "'" {
                    if next == "'" { current.append("'"); i += 2; continue }   // '' 转义
                    inSingleQuote = false
                }
                i += 1; continue
            }
            if inDoubleQuote {
                current.append(c)
                if c == "\"" { inDoubleQuote = false }
                i += 1; continue
            }
            if c == "-", next == "-" { closeWord(); inLineComment = true; i += 2; continue }
            if c == "/", next == "*" { closeWord(); inBlockComment = true; i += 2; continue }
            if c == "'" { closeWord(); inSingleQuote = true; current.append(c); i += 1; continue }
            if c == "\"" { closeWord(); inDoubleQuote = true; current.append(c); i += 1; continue }
            if c.isLetter || c == "_" { word.append(c); current.append(c); i += 1; continue }

            closeWord()
            current.append(c)
            // 语句边界只认「触发器体外」的分号：体内分号是子语句分隔符
            if c == ";", !inTriggerBody { endStatement() }
            i += 1
        }
        closeWord()
        endStatement()
        return out
    }
}
