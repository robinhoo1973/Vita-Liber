import Foundation

/// v2 全量建表（tech-spec §4.3 DDL 摘录 V3.40，dev-pm §3.1 M0 范围第 5 条）
///
/// M0 必须建齐的表（dev-pm §3.1）：
/// - 基础：local_owner / device_identity / patient_profile / document_file / asset / encounter
/// - M0 强制（FR9.10-9.14 依赖）：prescription / medication / medication_plan /
///   medication_dose_log / stock_lot / dose_lot_allocation
/// - 迁移与审计：audit_event（append-only）
/// - 其余 §4.3 表（metric_sample / guideline_source / alert_event / health_problem /
///   allergy_event / immunization / appointment / ai_conversation / ai_message /
///   observation / reminder / notification_delivery / voice_note / onboarding_progress /
///   encounter_question / claim_item / contact / consent_record / notification_state /
///   document_fts / document_fts_2gram）随本常量一并建库，保证 REFERENCES 自洽
///   （外键开启时任何悬空引用都会在 GRDBStore.init 建库阶段直接抛错，可测试可回滚）。
///
/// 注意：DDL 只写一次、建库只执行一次（GRDBStore.init）；历史迁移文件只读不改
/// （dev-pm §8.5）。
public enum SchemaV2 {
    public static let ddl = """
    -- 身份与设备（ADR-015）
    CREATE TABLE local_owner (
      id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      self_patient_id TEXT REFERENCES patient_profile(id),
      created_at REAL NOT NULL);
    CREATE TABLE device_identity (
      id TEXT PRIMARY KEY,
      local_owner_id TEXT NOT NULL REFERENCES local_owner(id),
      device_name TEXT NOT NULL,
      install_key_ref TEXT NOT NULL,
      account_id TEXT,
      last_active_at REAL NOT NULL);

    -- F3 成员档案
    CREATE TABLE patient_profile (
      id TEXT PRIMARY KEY,
      owner_local_id TEXT REFERENCES local_owner(id),
      display_name TEXT NOT NULL,
      relation TEXT NOT NULL,
      gender TEXT, birth_date TEXT, blood_type TEXT,
      id_no TEXT, insurance_no TEXT, avatar_asset_id TEXT REFERENCES asset(id),
      note TEXT, deleted_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_patient_owner ON patient_profile(owner_local_id);

    -- F5 资料文件（类型/状态/哈希/敏感）
    CREATE TABLE document_file (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      doc_type TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','archived','favorite','archived_favorite')),
      sha256 TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      is_sensitive INTEGER NOT NULL DEFAULT 0,
      encounter_id TEXT REFERENCES encounter(id),
      origin TEXT NOT NULL CHECK(origin IN ('camera','scanner','import','photoLibrary','manual')),
      meta_json TEXT,                    -- V3.41: 投影元数据(标题/确认计数/修订历史)，OCR 原文与附件的结构化侧载
      title TEXT,                        -- V3.43: FTS 检索列（external-content 需与虚表列同名）
      ocr_text TEXT,                     -- V3.43: OCR 原文检索列
      notes TEXT,                        -- V3.43: 用户笔记检索列
      -- 审查修复：来源徽章 A–E 的 D 级闸门（BR-003）。机器识别入库默认 'D'（未确认），
      -- 检索/AI 事实链排除 D 级；用户显式确认后升 'C'。手工录入默认 'C'。
      grade TEXT NOT NULL DEFAULT 'C' CHECK(grade IN ('A','B','C','D','E')),
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    -- 审查修复（P0）：UNIQUE → 普通索引。唯一索引与 FR5.6「重复只提示」
    -- 及 ADR-019 keep/adopt/coexist 语义直接冲突：同一文件二次入库必抛约束
    -- 错误（且跨成员全表唯一，家人扫同一份报告也炸）；去重由流程层
    -- duplicates() 查询执行（SchemaMigrations v+1 对老库同步降级）。
    CREATE INDEX idx_document_sha ON document_file(sha256);
    CREATE INDEX idx_document_patient_type ON document_file(patient_id, doc_type, created_at DESC);

    -- 二进制附件
    CREATE TABLE asset (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK(kind IN ('original','processed','thumbnail','blur','photo')),
      relative_path TEXT NOT NULL,
      file_protection TEXT NOT NULL,
      width INTEGER, height INTEGER, size_bytes INTEGER NOT NULL,
      parent_id TEXT REFERENCES asset(id),
      created_at REAL NOT NULL);
    CREATE INDEX idx_asset_kind ON asset(kind);

    -- F4 就诊事件
    CREATE TABLE encounter (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      date REAL NOT NULL, kind TEXT NOT NULL,
      hospital TEXT, department TEXT, doctor TEXT,
      chief_complaint TEXT, diagnosis_text TEXT, advice_text TEXT,
      follow_up_requirement TEXT, fee_amount REAL, rescheduled_from_id TEXT REFERENCES encounter(id),
      deleted_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_encounter_patient_date ON encounter(patient_id, date DESC);

    -- F6 OCR 结果
    CREATE TABLE ocr_result (
      id TEXT PRIMARY KEY, document_file_id TEXT NOT NULL REFERENCES document_file(id),
      page_index INTEGER NOT NULL DEFAULT 0,
      raw_blocks TEXT NOT NULL,
      engine_version TEXT NOT NULL, created_at REAL NOT NULL);

    -- F9 处方（BR-003 关键字段全确认才 confirmed=1）
    CREATE TABLE prescription (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      document_file_id TEXT REFERENCES document_file(id),
      source TEXT NOT NULL CHECK(source IN ('ocr','electronic','manual','encounter','history')),
      hospital TEXT, doctor TEXT, prescribed_at REAL,
      advice_text TEXT,
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);

    -- 药品定义（与 StockLot/Plan 分离，ADR-016）
    CREATE TABLE medication (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      generic_name TEXT NOT NULL, brand_name TEXT, spec TEXT,
      unit_kind TEXT NOT NULL CHECK(unit_kind IN ('tablet','capsule','patch','vial')),
      drug_key TEXT,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);

    -- 用药计划（F9.15 / ADR-020 状态机）
    CREATE TABLE medication_plan (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      medication_id TEXT NOT NULL REFERENCES medication(id),
      status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','ended')),
      schedule_json TEXT NOT NULL,
      start_date REAL NOT NULL, end_date REAL,
      dose_plan_units REAL,
      paused_at REAL, ended_at REAL, ended_reason TEXT,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_plan_patient_status ON medication_plan(patient_id, status);

    -- 计划生命周期历史（FR9.15：append-only，与状态变更同事务）
    CREATE TABLE plan_lifecycle_event (
      id TEXT PRIMARY KEY,
      plan_id TEXT NOT NULL REFERENCES medication_plan(id),
      kind TEXT NOT NULL CHECK(kind IN ('started','edited','paused','resumed','ended')),
      occurred_at REAL NOT NULL,
      note TEXT);
    CREATE INDEX idx_plan_event_plan ON plan_lifecycle_event(plan_id, occurred_at);

    -- 服药剂量日志（FR9.7 送达状态与用户确认分离）
    CREATE TABLE medication_dose_log (
      id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES medication_plan(id),
      scheduled_for REAL NOT NULL,
      dose_units REAL NOT NULL DEFAULT 1,   -- V3.42: 物化时的计划剂量（taper 不失真）
      delivery_state TEXT NOT NULL CHECK(delivery_state IN ('planned','sent','delivered','failed')),
      delivered_at REAL, user_action TEXT CHECK(user_action IN
        ('taken','snoozed','skipped','missed','discomfort') OR user_action IS NULL),
      acted_at REAL, snooze_until REAL, note TEXT);

    -- 双轨库存（F9.8 / ADR-009/016）
    CREATE TABLE stock_lot (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      medication_id TEXT NOT NULL REFERENCES medication(id),
      prescription_id TEXT REFERENCES prescription(id),
      total_units REAL NOT NULL,
      unit_kind TEXT NOT NULL CHECK(unit_kind IN ('tablet','capsule','patch','vial')),
      remaining_plan_units REAL NOT NULL,
      remaining_confirmed_units REAL NOT NULL,
      opened_at REAL, expire_at REAL,
      storage_note TEXT,
      storage_photo_id TEXT REFERENCES asset(id),
      box_photo_id TEXT REFERENCES asset(id),
      status TEXT NOT NULL CHECK(status IN ('active','depleted','expired','discarded')),
      last_reconciled_at REAL NOT NULL);
    CREATE INDEX idx_stock_lot_med_expire ON stock_lot(patient_id, medication_id, expire_at);

    CREATE TABLE dose_lot_allocation (
      dose_log_id TEXT NOT NULL REFERENCES medication_dose_log(id),
      stock_lot_id TEXT NOT NULL REFERENCES stock_lot(id),
      planned_units REAL NOT NULL,
      confirmed_units REAL NOT NULL DEFAULT 0,
      PRIMARY KEY(dose_log_id, stock_lot_id));

    -- 自测/设备指标样本（F7/F16；V3.23 派生 CHECK）
    CREATE TABLE metric_sample (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      metric_key TEXT NOT NULL,
      value REAL NOT NULL, secondary_value REAL,
      unit TEXT NOT NULL,
      origin TEXT NOT NULL CHECK(origin IN ('hospital','manual','device')),
      self_measured INTEGER NOT NULL
        CHECK((origin = 'hospital' AND self_measured = 0) OR (origin IN ('manual','device') AND self_measured = 1)),
      excluded INTEGER NOT NULL DEFAULT 0,   -- V3.45: 排除点软删(§5.29)
      source_ref TEXT,                       -- V3.45: 回原报告引用
      -- V3.46 / 迁移 v2：报告自带参考范围（A 级）。FR7.2 铁律「不同医院参考范围
      -- 不得合并成一条正常带」——ref_source_label（医院/实验室名）是各自成带的分组键；
      -- 三列缺席时该点无 A 级范围，回落信源库 B 级（P1）或渲染为「范围不可用」。
      ref_low REAL, ref_high REAL, ref_source_label TEXT,
      -- F25（V3.69 / 迁移 v14）：raw_label=原始指标名（FR7.1 原始名保真，FR25.4）；
      -- code_concept_id=规范编码（BR-003 确认前为空，确认后回填——编码只补不覆 FR25.11）
      raw_label TEXT, code_concept_id TEXT REFERENCES code_concept(id),
      measured_at REAL NOT NULL, created_at REAL NOT NULL);
    CREATE INDEX idx_metric_patient_time ON metric_sample(patient_id, metric_key, measured_at);

    -- B 级信源库（F16.4）
    CREATE TABLE guideline_source (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, org TEXT NOT NULL,
      year INTEGER NOT NULL, clause_ref TEXT NOT NULL,
      citation_url TEXT NOT NULL, version TEXT NOT NULL,
      checked_at REAL NOT NULL, retired_at REAL,
      -- V3.47 / 迁移 v3：L1-L3 阈值档位 JSON（GuidelineSource.Thresholds 形态）。
      -- v1 只有书目字段、无阈值数字——FR16.4「医学数字单一事实源」在数据层
      -- 无处落脚；单一 JSON 列让指南版本升级变成整条替换而非 ALTER。
      thresholds_json TEXT,
      -- 按指标检索的键（与 unit 一起随 v3 补列）
      metric_key TEXT,
      unit TEXT);

    -- 预警事件（F16）
    CREATE TABLE alert_event (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL,
      rule_id TEXT NOT NULL, severity TEXT NOT NULL CHECK(severity IN ('L0','L1','L2','L3')),
      evidence_json TEXT NOT NULL,
      delivered_state TEXT NOT NULL, created_at REAL NOT NULL);

    -- 健康问题（F11.4）
    CREATE TABLE health_problem (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      name TEXT NOT NULL, kind TEXT,
      archived INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_health_problem_patient ON health_problem(patient_id);

    -- 过敏与不良反应（F23 / ADR-018 一等事件）
    CREATE TABLE allergy_event (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      substance TEXT NOT NULL,
      reaction_tags TEXT NOT NULL,
      severity TEXT NOT NULL CHECK(severity IN ('mild','moderate','severe')),
      occurred_at REAL, duration_min INTEGER, treatment_note TEXT,
      encounter_id TEXT REFERENCES encounter(id), medication_id TEXT REFERENCES medication(id),
      consulted_doctor INTEGER NOT NULL DEFAULT 0,
      note TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_allergy_patient_time ON allergy_event(patient_id, occurred_at);

    -- 疫苗接种（FR4.5）
    CREATE TABLE immunization (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      vaccine_name TEXT NOT NULL, dose_number INTEGER,
      administered_at REAL, provider TEXT, lot_number TEXT,
      encounter_id TEXT REFERENCES encounter(id),
      source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','ocr','provider')),
      confirmed INTEGER NOT NULL DEFAULT 0,
      adverse_reaction_id TEXT REFERENCES allergy_event(id),
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_immunization_patient_time ON immunization(patient_id, administered_at);

    -- 预约（F10.7 / ADR-020 状态机）
    CREATE TABLE appointment (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      hospital TEXT, department TEXT, doctor TEXT,
      starts_at REAL NOT NULL, address TEXT, booking_no TEXT,
      status TEXT NOT NULL DEFAULT 'scheduled'
        CHECK(status IN ('scheduled','completed','cancelled','missed')),
      cancel_reason TEXT, rescheduled_from TEXT,
      source TEXT, items_to_bring TEXT, notes TEXT,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_appointment_patient_time ON appointment(patient_id, starts_at);

    -- AI 会话与消息（F12.10）
    CREATE TABLE ai_conversation (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL,
      title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE ai_message (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES ai_conversation(id),
      role TEXT NOT NULL CHECK(role IN ('user','assistant')),
      content TEXT NOT NULL, citation_ids TEXT,
      created_at REAL NOT NULL);

    -- 观察（F8 P0 差异化核心）
    CREATE TABLE observation (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      kind TEXT NOT NULL,
      occurred_at REAL NOT NULL, captured_at REAL,
      media_asset_ids TEXT,
      body_part TEXT, description TEXT,
      duration_min INTEGER, frequency TEXT, is_first INTEGER,
      trigger TEXT, accompanying TEXT, pain_score INTEGER,
      meds_diet TEXT, consulted_doctor INTEGER NOT NULL DEFAULT 0,
      encounter_id TEXT REFERENCES encounter(id),
      health_problem_id TEXT REFERENCES health_problem(id),
      group_id TEXT,
      self_mark TEXT CHECK(self_mark IN ('improved','unchanged','worsened') OR self_mark IS NULL),
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_observation_patient_time ON observation(patient_id, occurred_at DESC);

    -- 通用提醒（FR8.10/FR10.2/FR17.10）
    CREATE TABLE reminder (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      kind TEXT NOT NULL CHECK(kind IN ('followUp','examPrep','selfTest','medLog','appointment','any')),
      title TEXT NOT NULL, at_date REAL NOT NULL, repeats TEXT,
      status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','done','cancelled')),
      source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','voice','followUp')),
      channel_pref TEXT,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_reminder_patient_time ON reminder(patient_id, at_date);

    -- 送达记录（FR9.7/9.18）
    CREATE TABLE notification_delivery (
      id TEXT PRIMARY KEY,
      reminder_id TEXT REFERENCES reminder(id), dose_log_id TEXT REFERENCES medication_dose_log(id),
      scheduled_at REAL NOT NULL, delivered_at REAL,
      channel TEXT NOT NULL CHECK(channel IN ('inApp','local','persistentRing','serverPush')),
      level TEXT, outcome TEXT CHECK(outcome IN ('delivered','failed','skipped') OR outcome IS NULL),
      created_at REAL NOT NULL);

    -- 语音速记（FR17.14）
    CREATE TABLE voice_note (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      body TEXT NOT NULL, occurred_at REAL NOT NULL, tags TEXT,
      encounter_id TEXT REFERENCES encounter(id),
      in_timeline INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_voice_note_patient_time ON voice_note(patient_id, occurred_at DESC);

    -- 向导断点续填（FR21.9 / FR17.11 双流）
    CREATE TABLE onboarding_progress (
      id TEXT PRIMARY KEY, local_owner_id TEXT NOT NULL REFERENCES local_owner(id),
      flow_id TEXT NOT NULL DEFAULT 'onboarding',
      completed_steps TEXT NOT NULL, skipped_steps TEXT NOT NULL,
      current_step TEXT NOT NULL, finished INTEGER NOT NULL DEFAULT 0,
      updated_at REAL NOT NULL);

    -- 问诊问题（FR10.5）
    CREATE TABLE encounter_question (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      body TEXT NOT NULL, asked_at REAL,
      status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','asked','dropped')),
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_question_patient ON encounter_question(patient_id, status, created_at);

    -- 报销票据（FR13.7）
    CREATE TABLE claim_item (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      document_file_id TEXT REFERENCES document_file(id),
      item_type TEXT NOT NULL CHECK(item_type IN ('invoice','fee','receipt')),
      amount REAL, currency TEXT DEFAULT 'CNY', date REAL, merchant TEXT,
      summary TEXT,
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_claim_patient_encounter ON claim_item(patient_id, encounter_id, date);

    -- 紧急联系人（F15 数据源）
    CREATE TABLE contact (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      name TEXT NOT NULL, relation TEXT NOT NULL, phone TEXT NOT NULL,
      is_emergency INTEGER NOT NULL DEFAULT 0,
      note TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_contact_patient ON contact(patient_id, is_emergency);

    -- F24 发送状态（V3.49 / 迁移 v5）：只记状态与收件人，**不存消息原文**——
    -- 最小必要原则（FR24.2 展示状态即可，原文留在发送时刻的卡片里）。
    CREATE TABLE sent_message (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      kind TEXT NOT NULL,                    -- helpCard / sos
      recipient TEXT NOT NULL,               -- 收件人显示名
      status TEXT NOT NULL DEFAULT 'sent' CHECK(status IN ('sent','ackPending','acked','timeout')),
      sent_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_sent_message_patient ON sent_message(patient_id, sent_at);

    -- F15 急救卡用户选择（V3.48 / 迁移 v4）：FR15.1「必须由用户逐项选择，
    -- 不能静默加入」。只记选择，数据仍在原表；退选=删行。
    CREATE TABLE emergency_card_selection (
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      item_id TEXT NOT NULL,
      item_kind TEXT NOT NULL,
      selected_at REAL NOT NULL,
      PRIMARY KEY(patient_id, item_id));

    -- 同意记录（ADR-014/FR20.5/FR17.12）
    CREATE TABLE consent_record (
      id TEXT PRIMARY KEY, local_owner_id TEXT REFERENCES local_owner(id),
      patient_id TEXT REFERENCES patient_profile(id),
      key TEXT NOT NULL,
      level INTEGER NOT NULL,
      version TEXT NOT NULL, accepted_at REAL NOT NULL, scene TEXT);
    CREATE INDEX idx_consent_key ON consent_record(key, version);

    -- 通知中心（FR14.8/SP-27）
    CREATE TABLE notification_state (
      item_key TEXT PRIMARY KEY,
      kind TEXT NOT NULL, read_at REAL, archived_at REAL);

    -- 偏好设置（§5.28：键枚举单一事实源；只存非默认覆盖）
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL);

    -- 审计（§5.6 对齐：audit_event(id, at, actor_local, action, entity_type, entity_id_hash, meta_json)）
    -- 仅 INSERT API 暴露；entity_id 存哈希不存明文（§6 日志最小化）
    CREATE TABLE audit_event (
      id TEXT PRIMARY KEY,
      actor_local TEXT NOT NULL,
      action TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id_hash TEXT,
      at REAL NOT NULL,
      meta_json TEXT);
    CREATE INDEX idx_audit_time ON audit_event(at DESC);

    -- 中文全文检索（V3.24 查询长度路由：≥3 字 trigram 主表 / 2 字 2-gram 影子表）
    -- V3.44：external-content + 触发器维护——FTS5 rowid 必须为 INTEGER（源表 TEXT UUID
    -- 主键 → content_rowid='rowid' 经隐式 rowid 联接）；external-content 表不支持直接
    -- DELETE/INSERT 更新（曾报 disk image malformed），改由源表触发器同步，
    -- 2-gram 影子列经注册的 bigrams() SQL 函数转换（GRDBStore.init 注册）。
    -- V3.47：删除标记值必须与「已索引值」一致——脱敏插入（NULL）后若以原文值
    -- 打删除标记，SQLite 直接报 database disk image is malformed（3.46 实测），
    -- 故 AD/AU 触发器删除半段与插入半段同用 CASE WHEN is_sensitive = 0 守卫；
    -- contentless 表禁用 DELETE FROM，清空一律走 delete-all 特殊命令。
    CREATE VIRTUAL TABLE document_fts USING fts5(
      title, ocr_text, notes, tokenize='trigram case_sensitive 0',
      content='document_file', content_rowid='rowid');
    CREATE VIRTUAL TABLE document_fts_2gram USING fts5(
      title_2gram, ocr_2gram, note_2gram, tokenize='unicode61',
      content='');    -- V3.44: contentless——影子列名与源表不同（title_2gram 等），
                      -- external-content 要求列名一致会报 no such column；
                      -- contentless 支持 INSERT/DELETE（触发器可维护），
                      -- 片段高亮由检索侧从源表取回后手动拼接

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

    -- F25 医学数据标准化引擎码表(ADR-028/§5.52, V3.69): 数据许可见 §2.2; 只补不覆(FR25.11)
    CREATE TABLE code_concept (
      id TEXT PRIMARY KEY,                    -- 内部概念 id(UUID)
      canonical_code TEXT NOT NULL,           -- 规范码, 如 LOINC 718-7
      coding_system TEXT NOT NULL CHECK(coding_system IN ('loinc','snomed_ct','rxnorm')),
      display_zh_hans TEXT NOT NULL, display_en TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('metric','medication','observation_kind','other')),
      canonical_unit TEXT,                    -- 规范单位(FR25.2 换算目标, 如 718-7 的 g/dL); 可空
      bundle_version TEXT NOT NULL,           -- 码表版本(如 p0.5-seeds-2026-09-05)
      UNIQUE(coding_system, canonical_code));
    CREATE INDEX idx_code_concept_kind ON code_concept(kind);

    -- 多语言别名表: curated 行 > fold 行(FR25.1 链序, 由 Domain CodeResolver 施加)
    CREATE TABLE code_alias (
      alias_text TEXT NOT NULL,               -- 血红蛋白 / Hb / ヘモグロビン...
      locale TEXT NOT NULL,                   -- zh-Hans/zh-Hant/en/ja...
      concept_id TEXT NOT NULL REFERENCES code_concept(id),
      route TEXT NOT NULL CHECK(route IN ('curated','fold')),  -- fold=简繁脚本折叠产物
      priority INTEGER NOT NULL DEFAULT 0,
      bundle_version TEXT NOT NULL);
    CREATE INDEX idx_code_alias_lookup ON code_alias(alias_text, locale);

    -- 跨词表桥(含 FR25.2 单位特异编码: source_system='loinc-unit',
    -- source_code='<conceptId>|<unit>')
    CREATE TABLE code_map (
      source_system TEXT NOT NULL, source_code TEXT NOT NULL,
      concept_id TEXT NOT NULL REFERENCES code_concept(id),
      bundle_version TEXT NOT NULL,
      PRIMARY KEY(source_system, source_code));

    -- 人工覆盖表: 人写的行永远胜过表面匹配(FR25.1); 软删纪律对齐 guideline_source
    CREATE TABLE resolver_override (
      id TEXT PRIMARY KEY,
      query_pattern TEXT NOT NULL,
      concept_id TEXT NOT NULL REFERENCES code_concept(id),
      note TEXT NOT NULL,                     -- 纠错理由(人写行留痕)
      created_at REAL NOT NULL,
      retired_at REAL);

    -- UCUM 单位族(FR25.3): 量纲换算(因子+偏移); 非线性函数(如 pH/log)不入本表
    CREATE TABLE ucum_unit (
      unit_code TEXT PRIMARY KEY,             -- 规范码, 如 mmol/L
      family TEXT NOT NULL,                   -- 单位族(可互换判定)
      dimension TEXT NOT NULL,                -- 量纲记号
      factor REAL NOT NULL, offset REAL NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'simple');   -- simple/arithmetic

    -- 摩尔质量桥接(FR25.3): 跨量纲按指标编码取值(如血糖 mg/dL↔mmol/L),
    -- 同一物质的摩尔质量因物质而异, 不得按单位族推断
    CREATE TABLE ucum_molar_bridge (
      concept_id TEXT NOT NULL REFERENCES code_concept(id),
      from_unit TEXT NOT NULL, to_unit TEXT NOT NULL,
      factor REAL NOT NULL,                   -- 换算系数(含摩尔质量)
      note TEXT NOT NULL,                     -- 来源留痕(摩尔质量出处)
      PRIMARY KEY(concept_id, from_unit, to_unit));
    """
}
