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
        /// 单事务执行：DDL/数据搬运 + 版本推进同一事务，任何失败/崩溃整体
        /// 回滚、保留旧版本唯一副本（表重建类迁移必需；I5 审查修复——
        /// 该语义此前硬编码在 runner 的 `case 23` 特例里，runner 不该认识
        /// 具体版本号）。默认 false（走语句级幂等路径）。
        public let transactional: Bool
        /// transactional 步提交前必须通过 `PRAGMA foreign_key_check` 的表
        /// （nil = 不校验）。使用者：v23 / v25 / v27（ocr_card_commit 三次重建后校验
        /// 搬运无损）；校验失败抛 `OCRCardStore.StoreError.corruptReceipt`。
        public let fkCheckTable: String?
        public init(version: Int, name: String, sql: String, transactional: Bool = false, fkCheckTable: String? = nil) {
            self.version = version; self.name = name; self.sql = sql
            self.transactional = transactional; self.fkCheckTable = fkCheckTable
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
             -- FR10.7 改期历史：baseline 已有 rescheduled_from/cancel_reason/doctor/address/booking_no，
             -- 此处只补 source/items_to_bring/notes（幂等守卫跳过 baseline 已有列）
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
        // 审查修复（P0）：document_sha 唯一索引降级为普通索引（与 FR5.6 重复
        // 共存语义 / ADR-019 coexist 冲突）。幂等：DROP IF EXISTS +
        // CREATE IF NOT EXISTS，全新库（baseline 已含普通索引）重复执行安全。
        Step(version: 11, name: "document-sha-nonunique",
             sql: """
             DROP INDEX IF EXISTS idx_document_sha;
             CREATE INDEX IF NOT EXISTS idx_document_sha ON document_file(sha256);
             """),
        // 审查修复：document_file 增补来源徽章 grade 列（BR-003 闸门）——
        // 机器识别入库 = 'D'（未确认，检索/AI 事实链排除），用户显式确认升 'C'；
        // 老库既有行回填 'C'（此前无徽章语义，视为已入库历史数据，不追溯降级）。
        Step(version: 12, name: "document-provenance-grade",
             sql: """
             ALTER TABLE document_file ADD COLUMN grade TEXT NOT NULL DEFAULT 'C' CHECK(grade IN ('A','B','C','D','E'));
             """),
        // v13 为代码迁移（GRDBStore.migrateIncremental 的 rename-first 可恢复重建，
        // 见下方 v15 注释段）；sql 置空仅作占位。孤儿剂量行 = 对已删计划继续提醒
        // （FR9.15 计划生命周期破坏）——重建补 plan_id REFERENCES，历史孤儿行保留。
        Step(version: 13, name: "dose-log-plan-fk", sql: ""),
        // F25 医学数据标准化引擎码表六表（tech §4.3 / §5.52，编号 v14——
        // 注记：v12=document grade、v13=dose_log FK，F25 码表迁移从 v14 起）。
        // 幂等：六表 CREATE TABLE IF NOT EXISTS（baseline 已含同定义的全新库
        // 重复执行安全）；metric_sample 增列经 pragma_table_info 守卫
        // （SQLite 无 ADD COLUMN IF NOT EXISTS，§4.3.1 纪律）。
        Step(version: 14, name: "terminology-tables",
             sql: """
             CREATE TABLE IF NOT EXISTS code_concept (
               id TEXT PRIMARY KEY,
               canonical_code TEXT NOT NULL,
               coding_system TEXT NOT NULL CHECK(coding_system IN ('loinc','snomed_ct','rxnorm')),
               display_zh_hans TEXT NOT NULL, display_en TEXT NOT NULL,
               kind TEXT NOT NULL CHECK(kind IN ('metric','medication','observation_kind','other')),
               canonical_unit TEXT,
               bundle_version TEXT NOT NULL,
               UNIQUE(coding_system, canonical_code));
             CREATE INDEX IF NOT EXISTS idx_code_concept_kind ON code_concept(kind);
             CREATE TABLE IF NOT EXISTS code_alias (
               alias_text TEXT NOT NULL, locale TEXT NOT NULL,
               concept_id TEXT NOT NULL REFERENCES code_concept(id),
               route TEXT NOT NULL CHECK(route IN ('curated','fold')),
               priority INTEGER NOT NULL DEFAULT 0,
               bundle_version TEXT NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_code_alias_lookup ON code_alias(alias_text, locale);
             CREATE TABLE IF NOT EXISTS code_map (
               source_system TEXT NOT NULL, source_code TEXT NOT NULL,
               concept_id TEXT NOT NULL REFERENCES code_concept(id),
               bundle_version TEXT NOT NULL,
               PRIMARY KEY(source_system, source_code));
             CREATE TABLE IF NOT EXISTS resolver_override (
               id TEXT PRIMARY KEY,
               query_pattern TEXT NOT NULL,
               concept_id TEXT NOT NULL REFERENCES code_concept(id),
               note TEXT NOT NULL,
               created_at REAL NOT NULL,
               retired_at REAL);
             CREATE TABLE IF NOT EXISTS ucum_unit (
               unit_code TEXT PRIMARY KEY,
               family TEXT NOT NULL, dimension TEXT NOT NULL,
               factor REAL NOT NULL, offset REAL NOT NULL DEFAULT 0,
               kind TEXT NOT NULL DEFAULT 'simple');
             CREATE TABLE IF NOT EXISTS ucum_molar_bridge (
               concept_id TEXT NOT NULL REFERENCES code_concept(id),
               from_unit TEXT NOT NULL, to_unit TEXT NOT NULL,
               factor REAL NOT NULL, note TEXT NOT NULL,
               PRIMARY KEY(concept_id, from_unit, to_unit));

             -- metric_sample 增 raw_label/code_concept_id（FR25.4/FR25.12⑦，
             -- baseline 同步含两列——全新库不重放本段）。与 v2/v10 同纪律：
             -- 老库每条增量只跑一次（user_version 记账）；REFERENCES 子句
             -- 要求默认 NULL——本列确认前为空正是 BR-003 语义（未确认不落编码）。
             ALTER TABLE metric_sample ADD COLUMN raw_label TEXT;
             ALTER TABLE metric_sample ADD COLUMN code_concept_id TEXT REFERENCES code_concept(id);
             """),
        // v15 为**代码迁移**（GRDBStore.migrateIncremental 私有实现，本处 sql 置空）：
        // 剂量行 id 由绝对 epoch 迁移为逻辑身份（day+ordinal，评审修正 D5）——
        // 原地重算而非 DELETE 全清：已决议行/送达证据（delivered_at）全程保留；
        // 无法重算的未决议行清除（物化窗口按逻辑 id 重建，materializeMissed 随即决议）。
        Step(version: 15, name: "dose-logical-ids", sql: ""),
        // v16：数据修复 + 索引补齐（评审修正第二轮）：
        // ① dose_plan_units 归一——旧 MedicationPlanComposer 曾把整盒数量
        //   （initialLot.totalUnits，如 20/30）误写本列，读取侧按「每剂剂量」
        //   解释会令安全线瞬间崩塌（每剂扣一整盒）——异常大值（>100）复位 NULL
        //   （读取侧回落 1）。
        // ② 物化/补录热路径索引——materializeWindow 的 NOT EXISTS 守卫与
        //   recordTakenAt 的时段解析均按 plan_id + scheduled_for 扫描，
        //   此前全表扫随剂量行累积线性劣化；alert_event 去重键按 patient+rule 扫。
        Step(version: 16, name: "dose-units-normalize-and-indexes",
             sql: """
             UPDATE medication_plan SET dose_plan_units = NULL WHERE dose_plan_units > 100;
             CREATE INDEX IF NOT EXISTS idx_dose_log_plan_time ON medication_dose_log(plan_id, scheduled_for);
             CREATE INDEX IF NOT EXISTS idx_alert_event_patient_rule ON alert_event(patient_id, rule_id);
             """),
        // v17 保持预约（text-understanding-fts-indexes-and-slots，tech 账本 V3.83）：
        // 期一理解层元数据入 ocr_result.raw_blocks JSON 与既有 document_fts，
        // 无 schema 变更；本号留给字段级 FTS/槽位列需求。
        // v18：设备来源元数据与同步锚点（V3.86 health-device-source-and-anchor）——
        // ① metric_sample 增小时聚合三列 + HKSource 三键 + 来源索引（FR16.1/FR7.9）；
        // ② hk_sync_anchor 锚点表（随 .vlbu 备份往返，UserDefaults 不入备份已否决）。
        // 老库增量：老行六列 NULL（手输/医院语义不变）；新库 baseline 已含。
        Step(version: 18, name: "health-device-source-and-anchor",
             sql: """
             ALTER TABLE metric_sample ADD COLUMN value_min REAL;
             ALTER TABLE metric_sample ADD COLUMN value_max REAL;
             ALTER TABLE metric_sample ADD COLUMN sample_count INTEGER;
             ALTER TABLE metric_sample ADD COLUMN source_name TEXT;
             ALTER TABLE metric_sample ADD COLUMN source_version TEXT;
             ALTER TABLE metric_sample ADD COLUMN source_product TEXT;
             CREATE INDEX IF NOT EXISTS idx_metric_source ON metric_sample(patient_id, metric_key, measured_at, source_name);
             CREATE TABLE IF NOT EXISTS hk_sync_anchor (
               anchor_key TEXT PRIMARY KEY,
               anchor_value TEXT NOT NULL,
               updated_at REAL NOT NULL);
             """),
        // v19：FR6.9 待办卡（V3.96 pending-card，data-flow §3.5 单一事实源）。
        // 全新库 baseline 已含本表，老库由本步建——与 v2/v10/v18 同纪律：
        // CREATE TABLE IF NOT EXISTS 幂等（user_version 记账保证只跑一次）。
        // BR-003 表级排除：不参与搜索索引/FTS/AI 检索/导出。
        // status CHECK 含 archived（§21.3 三十天归档；tech v19 登记枚举未含，
        // 按 function-spec FR6.9 产品行为补列——枚举扩展向后兼容）。
        Step(version: 19, name: "pending-card",
             sql: """
             CREATE TABLE IF NOT EXISTS pending_card (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               source_type TEXT NOT NULL CHECK(source_type IN ('ocr','voice','manual')),
               source_doc_id TEXT REFERENCES document_file(id),
               card_kind TEXT NOT NULL,
               incomplete_fields TEXT NOT NULL,
               partial_data TEXT NOT NULL,
               raw_text TEXT NOT NULL,
               attempt_count INTEGER NOT NULL DEFAULT 0,
               status TEXT NOT NULL DEFAULT 'pending'
                 CHECK(status IN ('pending','in_progress','resolved','expired','archived')),
               created_at REAL NOT NULL,
               updated_at REAL NOT NULL,
               resolved_at REAL,
               resolved_by TEXT CHECK(resolved_by IN ('user','llm','expired')),
               note TEXT);
             CREATE INDEX IF NOT EXISTS idx_pending_card_patient_status ON pending_card(patient_id, status, created_at);
             CREATE INDEX IF NOT EXISTS idx_pending_card_source_doc ON pending_card(source_doc_id);
             """),
        Step(version: 20, name: "health-import-checkpoints",
             sql: """
             ALTER TABLE metric_sample ADD COLUMN source_identifier TEXT;
             ALTER TABLE metric_sample ADD COLUMN aggregation_kind TEXT;
             ALTER TABLE metric_sample ADD COLUMN window_end REAL;
             CREATE INDEX IF NOT EXISTS idx_metric_device_identity ON metric_sample(patient_id, source_ref) WHERE origin = 'device';
             CREATE TABLE IF NOT EXISTS hk_import_binding (
               singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
               id TEXT NOT NULL UNIQUE,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               time_zone TEXT NOT NULL,
               connected_at REAL NOT NULL);
             CREATE TABLE IF NOT EXISTS hk_sample_index (
               sample_id TEXT NOT NULL,
               type_key TEXT NOT NULL,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               source_id TEXT NOT NULL,
               start_at REAL NOT NULL, end_at REAL NOT NULL,
               PRIMARY KEY(sample_id, type_key, patient_id));
             CREATE INDEX IF NOT EXISTS idx_hk_sample_window ON hk_sample_index(patient_id, type_key, start_at, end_at);
             ALTER TABLE alert_event ADD COLUMN qualified INTEGER NOT NULL DEFAULT 0;
             ALTER TABLE alert_event ADD COLUMN scheduled_at REAL;
             CREATE INDEX IF NOT EXISTS idx_alert_qualified ON alert_event(patient_id, qualified, created_at);
             """),
        // V3.99 / FR6.9 页级多卡（2026-09-09 业主裁决）：信息卡对应到某次 OCR 记录的某一页。
        // document_page 每页一行（失败页占位保页号）；pending_card 补页号列。
        // pending_card 不进 FTS/AI/导出（红线不变）；document_page 随 .vlbu documents.pages 往返。
        Step(version: 21, name: "ocr-page-cards",
             sql: """
             CREATE TABLE IF NOT EXISTS document_page (
               id TEXT PRIMARY KEY,
               document_file_id TEXT NOT NULL REFERENCES document_file(id),
               page_index INTEGER NOT NULL,
               ocr_text TEXT,
               status TEXT NOT NULL DEFAULT 'ok' CHECK(status IN ('ok','failed','skipped')),
               created_at REAL NOT NULL,
               UNIQUE(document_file_id, page_index));
             CREATE INDEX IF NOT EXISTS idx_document_page_doc ON document_page(document_file_id, page_index);
             ALTER TABLE pending_card ADD COLUMN source_page INTEGER;
             """),
        Step(version: 22, name: "review-integrity-checkpoints",
             sql: """
             CREATE TABLE IF NOT EXISTS hk_pending_batch (
               binding_id TEXT NOT NULL REFERENCES hk_import_binding(id) ON DELETE CASCADE,
               type_key TEXT NOT NULL,
               payload_json TEXT NOT NULL,
               PRIMARY KEY(binding_id, type_key));
             CREATE TABLE IF NOT EXISTS hk_projection_state (
               binding_id TEXT NOT NULL REFERENCES hk_import_binding(id) ON DELETE CASCADE,
               metric_id TEXT NOT NULL REFERENCES metric_sample(id) ON DELETE CASCADE,
               PRIMARY KEY(binding_id, metric_id));
             CREATE INDEX IF NOT EXISTS idx_hk_projection_metric ON hk_projection_state(metric_id);
             CREATE TABLE IF NOT EXISTS ocr_card_commit (
               card_id TEXT NOT NULL,
               row_id TEXT NOT NULL,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               document_file_id TEXT NOT NULL REFERENCES document_file(id),
               page_index INTEGER NOT NULL CHECK(page_index >= 0),
               card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription')),
               entity_id TEXT NOT NULL,
               created_at REAL NOT NULL,
               PRIMARY KEY(card_id, row_id),
               FOREIGN KEY(document_file_id, page_index) REFERENCES document_page(document_file_id, page_index));
             CREATE INDEX IF NOT EXISTS idx_ocr_card_commit_source ON ocr_card_commit(document_file_id, page_index, card_kind);
             CREATE INDEX IF NOT EXISTS idx_ocr_card_commit_entity ON ocr_card_commit(card_kind, entity_id, patient_id);
             """),
        // v23：扩大页卡事实种类并保留显式就诊关系。表重建（RENAME→建新→搬运→
        // DROP 旧表）+ 版本推进同一事务，搬运后校验 ocr_card_commit 外键无损
        // ——声明在步级（transactional/fkCheckTable），runner 不再认识版本号。
        Step(version: 23, name: "ocr-card-associations",
             sql: """
             ALTER TABLE ocr_card_commit RENAME TO ocr_card_commit_v22;
             CREATE TABLE ocr_card_commit (
               card_id TEXT NOT NULL, row_id TEXT NOT NULL,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               document_file_id TEXT NOT NULL REFERENCES document_file(id),
               page_index INTEGER NOT NULL CHECK(page_index >= 0),
               card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription','claim_item','medication','immunization')),
               entity_id TEXT NOT NULL, encounter_id TEXT REFERENCES encounter(id),
               created_at REAL NOT NULL,
               PRIMARY KEY(card_id, row_id),
               FOREIGN KEY(document_file_id, page_index) REFERENCES document_page(document_file_id, page_index));
             INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_id, created_at)
               SELECT card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_id, created_at FROM ocr_card_commit_v22;
             DROP TABLE ocr_card_commit_v22;
             CREATE INDEX idx_ocr_card_commit_source ON ocr_card_commit(document_file_id, page_index, card_kind);
             CREATE INDEX idx_ocr_card_commit_entity ON ocr_card_commit(card_kind, entity_id, patient_id);
             CREATE INDEX idx_ocr_card_commit_encounter ON ocr_card_commit(encounter_id, patient_id);
             """, transactional: true, fkCheckTable: "ocr_card_commit"),
        Step(version: 24, name: "health-import-status",
             sql: """
             CREATE TABLE IF NOT EXISTS hk_import_status (
               binding_id TEXT PRIMARY KEY REFERENCES hk_import_binding(id) ON DELETE CASCADE,
               report_json TEXT NOT NULL, updated_at REAL NOT NULL);
             """),
        // v25：recognition-fact-lines（discussions/2026-09-13-hospital-card-schema-round1 §D.1）——
        // 处方行 / 费用行实体、就诊叙事列、处方与票据表头增列、文档稳定键列、回执 entity_table。
        // 幂等：新表 CREATE TABLE IF NOT EXISTS；增列经 addColumnParts 的 pragma_table_info
        // 守卫（SQLite 无 ADD COLUMN IF NOT EXISTS，与 v14 同纪律；transactional 路径自本步起
        // 同样过守卫——GRDBStore.executeIdempotent）；ocr_card_commit 表重建沿 v23 形态
        // （RENAME→CREATE→INSERT SELECT→DROP→索引），搬运时 entity_table = card_kind，
        // CHECK 枚举一次列全 D1–D3，v26/v27 不再重建。回填为代码步（GRDBStore case 25，
        // 只从 ocr-card-v22 回执确定性生成，绝不从 advice_text 自由文本猜回；BR-003）。
        // 增列一律追加表尾，与 SchemaV2.ddl 基线同序（新老库 SELECT * 列序一致）。
        Step(version: 25, name: "recognition-fact-lines",
             sql: """
             ALTER TABLE encounter ADD COLUMN present_illness TEXT;
             ALTER TABLE encounter ADD COLUMN visit_summary TEXT;
             ALTER TABLE encounter ADD COLUMN past_history TEXT;
             ALTER TABLE encounter ADD COLUMN physical_exam TEXT;
             ALTER TABLE encounter ADD COLUMN allergy_history TEXT;
             ALTER TABLE prescription ADD COLUMN department TEXT;
             ALTER TABLE prescription ADD COLUMN prescription_no TEXT;
             ALTER TABLE prescription ADD COLUMN prescription_type TEXT CHECK(prescription_type IN ('general','emergency','pediatric','narcotic','psychotropic','tcm','other'));
             ALTER TABLE prescription ADD COLUMN fee_type_text TEXT;
             ALTER TABLE prescription ADD COLUMN clinical_diagnosis TEXT;
             ALTER TABLE prescription ADD COLUMN pharmacist_names TEXT;
             ALTER TABLE prescription ADD COLUMN total_amount REAL;
             CREATE TABLE IF NOT EXISTS prescription_line (
               id TEXT PRIMARY KEY,
               prescription_id TEXT NOT NULL REFERENCES prescription(id),
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               ordinal INTEGER NOT NULL,
               printed_name TEXT NOT NULL, generic_name TEXT, brand_name TEXT,
               drug_form TEXT, spec TEXT,
               dose_text TEXT, dose_unit TEXT,
               quantity_text TEXT, quantity_unit TEXT,
               frequency_text TEXT, route_text TEXT, duration_text TEXT,
               start_date REAL, end_date REAL, as_needed_text TEXT,
               medication_notes TEXT,
               note TEXT, raw_text TEXT,
               insurance_code TEXT, item_code_text TEXT,
               unit_price REAL, amount REAL,
               medication_id TEXT REFERENCES medication(id),
               source_page INTEGER, source_row_id TEXT,
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL,
               UNIQUE(prescription_id, ordinal));
             CREATE INDEX IF NOT EXISTS idx_prescription_line_patient ON prescription_line(patient_id, prescription_id, ordinal);
             ALTER TABLE stock_lot ADD COLUMN prescription_line_id TEXT REFERENCES prescription_line(id);
             ALTER TABLE claim_item ADD COLUMN reimbursed_amount REAL;
             ALTER TABLE claim_item ADD COLUMN out_of_pocket REAL;
             ALTER TABLE claim_item ADD COLUMN personal_account_amount REAL;
             ALTER TABLE claim_item ADD COLUMN invoice_no TEXT;
             ALTER TABLE claim_item ADD COLUMN insurance_type_text TEXT;
             CREATE TABLE IF NOT EXISTS claim_line (
               id TEXT PRIMARY KEY,
               claim_item_id TEXT NOT NULL REFERENCES claim_item(id),
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               ordinal INTEGER NOT NULL,
               item_name TEXT NOT NULL, item_code_text TEXT, insurance_code TEXT,
               spec TEXT, unit_price REAL, quantity_text TEXT, quantity_unit TEXT,
               amount REAL, fee_category_text TEXT,
               fee_at REAL, executing_dept TEXT, self_pay_ratio_text TEXT,
               raw_text TEXT, source_page INTEGER, source_row_id TEXT,
               created_at REAL NOT NULL,
               UNIQUE(claim_item_id, ordinal));
             CREATE INDEX IF NOT EXISTS idx_claim_line_patient ON claim_line(patient_id, claim_item_id, ordinal);
             ALTER TABLE document_file ADD COLUMN doc_type_key TEXT;
             ALTER TABLE document_file ADD COLUMN title_source TEXT CHECK(title_source IN ('user','suggested','filename','none') OR title_source IS NULL);
             ALTER TABLE ocr_card_commit RENAME TO ocr_card_commit_v24;
             CREATE TABLE ocr_card_commit (
               card_id TEXT NOT NULL, row_id TEXT NOT NULL,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               document_file_id TEXT NOT NULL REFERENCES document_file(id),
               page_index INTEGER NOT NULL CHECK(page_index >= 0),
               card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription','claim_item','medication','immunization','hospitalization','diagnosis','exam_report','surgery','treatment_record')),
               entity_table TEXT NOT NULL CHECK(entity_table IN ('metric_sample','encounter','prescription','claim_item','medication','immunization','hospitalization','diagnosis','exam_report','surgery','treatment_record','prescription_line','claim_line','lab_report','lab_result')),
               entity_id TEXT NOT NULL, encounter_id TEXT REFERENCES encounter(id),
               created_at REAL NOT NULL,
               PRIMARY KEY(card_id, row_id),
               FOREIGN KEY(document_file_id, page_index) REFERENCES document_page(document_file_id, page_index));
             INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_table, entity_id, encounter_id, created_at)
               SELECT card_id, row_id, patient_id, document_file_id, page_index, card_kind, card_kind, entity_id, encounter_id, created_at FROM ocr_card_commit_v24;
             DROP TABLE ocr_card_commit_v24;
             CREATE INDEX idx_ocr_card_commit_source ON ocr_card_commit(document_file_id, page_index, card_kind);
             CREATE INDEX idx_ocr_card_commit_entity ON ocr_card_commit(card_kind, entity_id, patient_id);
             CREATE INDEX idx_ocr_card_commit_encounter ON ocr_card_commit(encounter_id, patient_id);
             CREATE INDEX idx_ocr_card_commit_entity_table ON ocr_card_commit(entity_table, entity_id, patient_id);
             """, transactional: true, fkCheckTable: "ocr_card_commit"),
        // v26：clinical-episodes（discussions/2026-09-13-hospital-card-schema-round1 §C.2–C.5 / §D.2）——
        // 住院期 / 诊断 / 检查报告 / 检验表头 + 定性行五表，metric_sample 增 lab_report_id/abnormal_flag。
        // 纯 SQL 步、非 transactional（无表重建，runner default 路径）：新表/索引 IF NOT EXISTS，增列经
        // executeIdempotent 的 pragma_table_info 守卫；表尾追加与 SchemaV2.ddl 基线同序。
        // ocr_card_commit 的 card_kind/entity_table CHECK 枚举已在 v25 一次列全，本步不重建。
        // 回填（纯 SQL、确定性、幂等）：对 card_kind='metric_sample' 的历史回执按 card_id 分组
        // （同页同卡类 card_id 唯一，OCRCardStore.save 守卫）→ 每张已确认检验卡一条 lab_report
        // （幂等键 source_card_id UNIQUE；id = card_id，UUID 同型、两台设备回填同 id）；hospital 取
        // 回填前塞在 ref_source_label 的医院名，reported_at = 该卡 measured_at；旧行 measured_at 不改，
        // 只补 lab_report_id（且只在表头确实存在时，杜绝悬空 FK）。只从已确认回执生成（BR-003）；
        // 诊断/检查/住院此前无卡 → 零回填。abnormal_flag 不臆造（报告打印才有）。
        Step(version: 26, name: "clinical-episodes",
             sql: """
             CREATE TABLE IF NOT EXISTS hospitalization (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               encounter_id TEXT NOT NULL UNIQUE REFERENCES encounter(id),
               document_file_id TEXT REFERENCES document_file(id),
               hospital TEXT, medical_record_no TEXT, inpatient_times INTEGER,
               admit_at REAL, discharge_at REAL, actual_days INTEGER,
               admit_dept TEXT, discharge_dept TEXT, ward TEXT, bed_no TEXT,
               admit_route_text TEXT,
               payment_type_text TEXT,
               discharge_way_text TEXT,
               attending_physician TEXT,
               admit_diagnosis_text TEXT, discharge_diagnosis_text TEXT,
               admit_condition TEXT, treatment_course TEXT, discharge_condition TEXT,
               discharge_orders TEXT, take_home_drugs_text TEXT,
               total_cost REAL,
               summary_doctor TEXT, summary_date REAL,
               source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_hospitalization_patient ON hospitalization(patient_id, admit_at DESC);
             CREATE TABLE IF NOT EXISTS diagnosis (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               encounter_id TEXT REFERENCES encounter(id),
               ordinal INTEGER NOT NULL DEFAULT 0,
               diagnosis_type TEXT NOT NULL DEFAULT 'unspecified'
                 CHECK(diagnosis_type IN ('primary','secondary','admission','discharge','preop','postop','pathology','certificate','unspecified')),
               name TEXT NOT NULL,
               code_text TEXT, code_system_text TEXT,
               diagnosed_at REAL,
               health_problem_id TEXT REFERENCES health_problem(id),
               note TEXT,
               source_page INTEGER, source_row_id TEXT,
               document_file_id TEXT REFERENCES document_file(id),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_diagnosis_patient_time ON diagnosis(patient_id, diagnosed_at DESC);
             CREATE INDEX IF NOT EXISTS idx_diagnosis_encounter ON diagnosis(encounter_id, ordinal);
             CREATE TABLE IF NOT EXISTS exam_report (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               encounter_id TEXT REFERENCES encounter(id),
               document_file_id TEXT REFERENCES document_file(id),
               report_type TEXT NOT NULL
                 CHECK(report_type IN ('ct','mri','xray','ultrasound','ecg','endoscopy','pathology','nuclear','other')),
               hospital TEXT, department TEXT, report_no TEXT,
               exam_part TEXT, exam_method TEXT,
               exam_at REAL, reported_at REAL,
               findings TEXT, impression TEXT,
               apply_doctor TEXT, report_doctor TEXT, review_doctor TEXT,
               source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_exam_report_patient_time ON exam_report(patient_id, exam_at DESC);
             CREATE TABLE IF NOT EXISTS lab_report (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               encounter_id TEXT REFERENCES encounter(id),
               document_file_id TEXT REFERENCES document_file(id),
               hospital TEXT, department TEXT, lab_name TEXT, report_no TEXT,
               specimen_type TEXT, specimen_no TEXT, test_class_text TEXT,
               clinical_diagnosis TEXT,
               collected_at REAL, received_at REAL, reported_at REAL,
               send_doctor TEXT, test_doctor TEXT, review_doctor TEXT,
               source_card_id TEXT UNIQUE,
               source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_lab_report_patient_time ON lab_report(patient_id, reported_at DESC);
             CREATE TABLE IF NOT EXISTS lab_result (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               lab_report_id TEXT NOT NULL REFERENCES lab_report(id),
               ordinal INTEGER NOT NULL DEFAULT 0,
               item_name TEXT NOT NULL, item_code_text TEXT,
               result_text TEXT NOT NULL,
               comparator TEXT, unit TEXT, reference_text TEXT, abnormal_flag TEXT, method TEXT,
               code_concept_id TEXT REFERENCES code_concept(id),
               source_page INTEGER, source_row_id TEXT,
               created_at REAL NOT NULL,
               UNIQUE(lab_report_id, ordinal));
             ALTER TABLE metric_sample ADD COLUMN lab_report_id TEXT REFERENCES lab_report(id);
             ALTER TABLE metric_sample ADD COLUMN abnormal_flag TEXT;
             -- 回填：每张历史检验卡一条表头（幂等键 source_card_id）；hospital 取回填前塞在 ref_source_label 的医院名，
             -- reported_at = 该卡 measured_at（旧行 measured_at 不改，§C.5）；created_at = 回执 MIN(created_at)。
             INSERT INTO lab_report (id, patient_id, document_file_id, hospital, reported_at, source_card_id, source, confirmed, created_at, updated_at)
               SELECT c.card_id, c.patient_id, c.document_file_id, MAX(m.ref_source_label), MAX(m.measured_at), c.card_id, 'ocr', 1, MIN(c.created_at), MIN(c.created_at)
               FROM ocr_card_commit c JOIN metric_sample m ON m.id = c.entity_id AND m.patient_id = c.patient_id
               WHERE c.card_kind = 'metric_sample' AND c.entity_table = 'metric_sample'
                 AND NOT EXISTS (SELECT 1 FROM lab_report l WHERE l.source_card_id = c.card_id)
               GROUP BY c.card_id;
             -- 只补空、只在表头确实存在时回指（JOIN lab_report 杜绝悬空 FK；迁移期 foreign_keys=OFF 不会即时拦截）。
             UPDATE metric_sample SET lab_report_id = (
                 SELECT l.id FROM ocr_card_commit c JOIN lab_report l ON l.source_card_id = c.card_id
                 WHERE c.entity_id = metric_sample.id AND c.entity_table = 'metric_sample' AND c.patient_id = metric_sample.patient_id)
               WHERE lab_report_id IS NULL AND EXISTS (
                 SELECT 1 FROM ocr_card_commit c JOIN lab_report l ON l.source_card_id = c.card_id
                 WHERE c.entity_id = metric_sample.id AND c.entity_table = 'metric_sample' AND c.patient_id = metric_sample.patient_id);
             """),
        // v27：card-hierarchy（discussions/2026-09-14-card-hierarchy-round1 §E / recognition-remediation-design §0.4；并入原 D3 §C.8–C.10）——
        // 体检枢纽 health_exam、统一结论 clinical_conclusion、手术/治疗记录、报告来源与体检外键、预约/提醒挂接列、
        // 文档类型索引改稳定键、统一报告头视图；ocr_card_commit 第三次重建扩 card_kind/entity_table 枚举
        //（v25 形态 RENAME→CREATE→INSERT SELECT→DROP→索引，transactional + fkCheckTable，runner 按步级声明走 applyTransactional；
        // v25 注释曾预期 v26/v27 不再重建——§0.4 改判新增两卡类致此次重建，历史步注释按纪律不改）。
        // 幂等：IF NOT EXISTS / addColumnParts 守卫 / DROP INDEX IF EXISTS；无回填（doc_type_key 由 App 层首启任务反查三语标签，J4；
        // report_source/health_exam_id 旧行 NULL = v27 前未标注，读侧经视图 COALESCE 推断呈现、不回写）。
        // 语句顺序即依赖顺序：health_exam 先建（三处 health_exam_id 外键指向它）→ 增列 → 视图（其 SELECT 列已齐）→ 回执重建。
        // 视图正文与 SchemaV2.ddl 同文（金样比对 sqlite_master 去空白相等），正文内无分号、无 -- 注释。
        Step(version: 27, name: "card-hierarchy",
             sql: """
             CREATE TABLE IF NOT EXISTS health_exam (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               document_file_id TEXT REFERENCES document_file(id),
               org_name TEXT, exam_no TEXT, package_name TEXT,
               exam_date REAL, total_doctor TEXT, report_date REAL,
               height_text TEXT, weight_text TEXT, bmi_text TEXT,
               systolic_text TEXT, diastolic_text TEXT, pulse_text TEXT, waist_text TEXT,
               vision_left_text TEXT, vision_right_text TEXT,
               overall_conclusion TEXT, health_guidance TEXT,
               source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_health_exam_patient_time ON health_exam(patient_id, exam_date DESC);
             ALTER TABLE lab_report ADD COLUMN report_source TEXT CHECK(report_source IN ('outpatient','emergency','inpatient','health_exam') OR report_source IS NULL);
             ALTER TABLE lab_report ADD COLUMN health_exam_id TEXT REFERENCES health_exam(id);
             ALTER TABLE exam_report ADD COLUMN report_source TEXT CHECK(report_source IN ('outpatient','emergency','inpatient','health_exam') OR report_source IS NULL);
             ALTER TABLE exam_report ADD COLUMN health_exam_id TEXT REFERENCES health_exam(id);
             ALTER TABLE metric_sample ADD COLUMN health_exam_id TEXT REFERENCES health_exam(id);
             CREATE TABLE IF NOT EXISTS clinical_conclusion (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               lab_report_id TEXT REFERENCES lab_report(id),
               exam_report_id TEXT REFERENCES exam_report(id),
               health_exam_id TEXT REFERENCES health_exam(id),
               conclusion_type TEXT NOT NULL
                 CHECK(conclusion_type IN ('lab','exam','health_exam_summary','abnormal_finding','health_advice','recheck_advice','visit_advice')),
               content TEXT NOT NULL,
               severity_text TEXT,
               ordinal INTEGER NOT NULL DEFAULT 0,
               source_page INTEGER, source_row_id TEXT,
               created_at REAL NOT NULL,
               CHECK((lab_report_id IS NOT NULL) + (exam_report_id IS NOT NULL) + (health_exam_id IS NOT NULL) = 1));
             CREATE INDEX IF NOT EXISTS idx_clinical_conclusion_health_exam ON clinical_conclusion(health_exam_id, ordinal);
             CREATE INDEX IF NOT EXISTS idx_clinical_conclusion_lab ON clinical_conclusion(lab_report_id, ordinal);
             CREATE INDEX IF NOT EXISTS idx_clinical_conclusion_exam ON clinical_conclusion(exam_report_id, ordinal);
             CREATE TABLE IF NOT EXISTS surgery (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               encounter_id TEXT REFERENCES encounter(id),
               document_file_id TEXT REFERENCES document_file(id),
               hospital TEXT, department TEXT,
               surgery_at REAL, ended_at REAL,
               surgery_name TEXT NOT NULL, surgery_code_text TEXT, surgery_level_text TEXT,
               surgeon TEXT, assistants TEXT, anesthesiologist TEXT, anesthesia_method TEXT,
               preop_diagnosis_text TEXT, postop_diagnosis_text TEXT,
               procedure_course TEXT, intraop_findings TEXT,
               implants_text TEXT, specimen_text TEXT, blood_loss_text TEXT, transfusion_text TEXT, drainage_text TEXT,
               postop_orders TEXT, complications_text TEXT,
               source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_surgery_patient_time ON surgery(patient_id, surgery_at DESC);
             CREATE TABLE IF NOT EXISTS treatment_record (
               id TEXT PRIMARY KEY,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               encounter_id TEXT REFERENCES encounter(id),
               document_file_id TEXT REFERENCES document_file(id),
               treatment_type TEXT NOT NULL CHECK(treatment_type IN ('infusion','injection','physiotherapy','dressing','other')),
               treated_at REAL, hospital TEXT, department TEXT, doctor TEXT, executor TEXT,
               diagnosis_text TEXT, content TEXT,
               drugs_text TEXT,
               session_text TEXT,
               adverse_reaction_text TEXT,
               allergy_event_id TEXT REFERENCES allergy_event(id),
               result_text TEXT, note TEXT,
               source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
               confirmed INTEGER NOT NULL DEFAULT 0,
               created_at REAL NOT NULL, updated_at REAL NOT NULL);
             CREATE INDEX IF NOT EXISTS idx_treatment_patient_time ON treatment_record(patient_id, treated_at DESC);
             ALTER TABLE appointment ADD COLUMN encounter_id TEXT REFERENCES encounter(id);
             ALTER TABLE appointment ADD COLUMN purpose TEXT CHECK(purpose IN ('visit','followUp','exam','healthExam') OR purpose IS NULL);
             ALTER TABLE reminder ADD COLUMN source_table TEXT;
             ALTER TABLE reminder ADD COLUMN source_id TEXT;
             DROP INDEX IF EXISTS idx_document_patient_type;
             CREATE INDEX IF NOT EXISTS idx_document_patient_type ON document_file(patient_id, doc_type_key, created_at DESC);
             CREATE VIEW IF NOT EXISTS v_clinical_report AS
             SELECT id AS report_id, patient_id, 'lab' AS report_type,
                    COALESCE(report_source, CASE WHEN health_exam_id IS NOT NULL THEN 'health_exam' END) AS report_source,
                    COALESCE(collected_at, reported_at) AS report_date, hospital AS org_name, report_no,
                    encounter_id, health_exam_id, document_file_id, confirmed
             FROM lab_report
             UNION ALL
             SELECT id, patient_id, 'exam',
                    COALESCE(report_source, CASE WHEN health_exam_id IS NOT NULL THEN 'health_exam' END),
                    COALESCE(exam_at, reported_at), hospital, report_no,
                    encounter_id, health_exam_id, document_file_id, confirmed
             FROM exam_report
             UNION ALL
             SELECT id, patient_id, 'health_exam', 'health_exam',
                    COALESCE(exam_date, report_date), org_name, exam_no,
                    NULL, id, document_file_id, confirmed
             FROM health_exam;
             ALTER TABLE ocr_card_commit RENAME TO ocr_card_commit_v26;
             CREATE TABLE ocr_card_commit (
               card_id TEXT NOT NULL, row_id TEXT NOT NULL,
               patient_id TEXT NOT NULL REFERENCES patient_profile(id),
               document_file_id TEXT NOT NULL REFERENCES document_file(id),
               page_index INTEGER NOT NULL CHECK(page_index >= 0),
               card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription','claim_item','medication','immunization','hospitalization','diagnosis','exam_report','surgery','treatment_record','health_exam','clinical_conclusion')),
               entity_table TEXT NOT NULL CHECK(entity_table IN ('metric_sample','encounter','prescription','claim_item','medication','immunization','hospitalization','diagnosis','exam_report','surgery','treatment_record','prescription_line','claim_line','lab_report','lab_result','health_exam','clinical_conclusion')),
               entity_id TEXT NOT NULL, encounter_id TEXT REFERENCES encounter(id),
               created_at REAL NOT NULL,
               PRIMARY KEY(card_id, row_id),
               FOREIGN KEY(document_file_id, page_index) REFERENCES document_page(document_file_id, page_index));
             INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_table, entity_id, encounter_id, created_at)
               SELECT card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_table, entity_id, encounter_id, created_at FROM ocr_card_commit_v26;
             DROP TABLE ocr_card_commit_v26;
             CREATE INDEX idx_ocr_card_commit_source ON ocr_card_commit(document_file_id, page_index, card_kind);
             CREATE INDEX idx_ocr_card_commit_entity ON ocr_card_commit(card_kind, entity_id, patient_id);
             CREATE INDEX idx_ocr_card_commit_encounter ON ocr_card_commit(encounter_id, patient_id);
             CREATE INDEX idx_ocr_card_commit_entity_table ON ocr_card_commit(entity_table, entity_id, patient_id);
             """, transactional: true, fkCheckTable: "ocr_card_commit"),
        Step(version: 28, name: "timeline-metric-indexes",
             sql: """
             -- 时间轴主卡查询（20 分支 UNION ALL 外层 ORDER BY d DESC, id DESC）：
             -- 缺 (origin 等值 + measured_at/id 双列序) 索引时各分支走
             -- USE TEMP B-TREE FOR ORDER BY，成本 O(成员全部病史)（12.7 万行实测
             -- 每页 490 ms）。2026-09-16 委员会评审实测该索引后 6 页 2955 ms → 30 ms。
             CREATE INDEX IF NOT EXISTS idx_metric_timeline
               ON metric_sample(patient_id, origin, measured_at DESC, id DESC);
             -- 指标宫格最新行（PARTITION BY metric_key ORDER BY measured_at DESC,
             -- rowid DESC）：按患者+未排除+指标键提供分区内排序。
             CREATE INDEX IF NOT EXISTS idx_metric_latest
               ON metric_sample(patient_id, excluded, metric_key, measured_at DESC);
             """),
    ]

    /// 全新库建库后应落到的版本号
    /// 账本当前目标版本。取 **max 而非 last**（2026-09-16 委员会评审）：
    /// 文件自身规定「只许在末尾追加」，但 v17 是预留空号——将来「把 v17 填上」
    /// 按直觉会追加到列表尾，此时 `last` 会**回退**到 17，让所有 v27 库命中
    /// `schemaTooNew`（发布级故障）。`max` 让「末尾追加 v17」与「按序插入 v17」
    /// 同结果；`pending(from:)` 本就会排序，runner 不受影响。
    public static var latestVersion: Int { steps.map(\.version).max() ?? baselineVersion }

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
