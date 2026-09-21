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
/// - 子项目 D（v25/v26）：prescription_line / claim_line（v25）、hospitalization / diagnosis /
///   exam_report / lab_report / lab_result（v26）——新表 DDL 同批进基线与迁移步（L0 §3）
///   （外键开启时任何悬空引用都会在 GRDBStore.init 建库阶段直接抛错，可测试可回滚）。
/// - 子项目 J（v27）：health_exam / clinical_conclusion / surgery / treatment_record + v_clinical_report
///   （体检第三枢纽、统一结论、原 D3 两表、统一报告头只读视图；lab_report/exam_report 报告来源与体检外键、
///   metric_sample 体检回指、appointment 挂就诊 + 目的、reminder 多态来源、文档类型索引改稳定键、
///   ocr_card_commit 第三次重建扩枚举——discussions/2026-09-14-card-hierarchy-round1 §E.1）。
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
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v25（子项目 D §C.10）：稳定类型键（分类学 D3 定稿；旧行 NULL 直至 App 层回填）
      -- 与标题来源；doc_type 标签列保留为过渡显示列。表尾追加 = 迁移 ADD COLUMN 同序。
      doc_type_key TEXT,
      title_source TEXT CHECK(title_source IN ('user','suggested','filename','none') OR title_source IS NULL));
    -- 审查修复（P0）：UNIQUE → 普通索引。唯一索引与 FR5.6「重复只提示」
    -- 及 ADR-019 keep/adopt/coexist 语义直接冲突：同一文件二次入库必抛约束
    -- 错误（且跨成员全表唯一，家人扫同一份报告也炸）；去重由流程层
    -- duplicates() 查询执行（SchemaMigrations v+1 对老库同步降级）。
    CREATE INDEX idx_document_sha ON document_file(sha256);
    -- v27（原 D3-1 §C.10）：文档类型索引改稳定键 doc_type_key（老库经 v27 DROP/CREATE 重建同形；旧行键 NULL 直至 App 层回填）。
    CREATE INDEX idx_document_patient_type ON document_file(patient_id, doc_type_key, created_at DESC);

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
      deleted_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v25（子项目 D §C.1）：门诊病历叙事列，原文保存、App 不摘要不改写；
      -- allergy_history 为资料建议（D4）来源列（+1 列偏离，见实施计划 D1-1）。
      present_illness TEXT, visit_summary TEXT, past_history TEXT, physical_exam TEXT, allergy_history TEXT);
    CREATE INDEX idx_encounter_patient_date ON encounter(patient_id, date DESC);

    -- v26（子项目 D §C.2）：住院期（1:0..1 encounter，kind ∈ inpatient/daySurgery；UNIQUE(encounter_id) = 一次住院一行，
    -- 多份原件 COALESCE(NULLIF) 补空）。encounter 仍是枢纽，不另设 setting 列。入院途径/付费方式/离院方式只存
    -- 打印文本 *_text（不编码）；诊断原文块留此、逐条见 diagnosis；出院带药只存原文（BR-006）。
    -- 排除：org_code、护理级别、切口愈合等级、手术级别、ABO/Rh（已在 patient_profile）。
    CREATE TABLE hospitalization (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT NOT NULL UNIQUE REFERENCES encounter(id),   -- kind ∈ inpatient/daySurgery
      document_file_id TEXT REFERENCES document_file(id),
      hospital TEXT, medical_record_no TEXT, inpatient_times INTEGER,
      admit_at REAL, discharge_at REAL, actual_days INTEGER,
      admit_dept TEXT, discharge_dept TEXT, ward TEXT, bed_no TEXT,
      admit_route_text TEXT,         -- 急诊/门诊/转院（打印文本，不编码）
      payment_type_text TEXT,        -- 医保/自费/公费…（打印文本）
      discharge_way_text TEXT,       -- 医嘱离院/转院/非医嘱离院…（打印文本）
      attending_physician TEXT,
      admit_diagnosis_text TEXT, discharge_diagnosis_text TEXT,     -- 原文块；逐条见 diagnosis
      admit_condition TEXT, treatment_course TEXT, discharge_condition TEXT,
      discharge_orders TEXT, take_home_drugs_text TEXT,             -- 出院小结叙事（BR-006：带药只存原文）
      total_cost REAL,
      summary_doctor TEXT, summary_date REAL,
      source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_hospitalization_patient ON hospitalization(patient_id, admit_at DESC);

    -- v26（子项目 D §C.3）：诊断逐条投影（encounter.diagnosis_text 原文块保留，两者不互相派生）。
    -- diagnosis_type 存 canonical raw + CHECK，展示经 fieldValueDisplay；编码只存打印文本 code_text/
    -- code_system_text——不 FK、不推断、不接 F25 码表（BR-003）。health_problem_id 只由用户显式
    -- 「采用为健康问题」后回填（FR11.4）。encounter_id 可空：诊断证明可无就诊卡。
    CREATE TABLE diagnosis (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      ordinal INTEGER NOT NULL DEFAULT 0,
      diagnosis_type TEXT NOT NULL DEFAULT 'unspecified'
        CHECK(diagnosis_type IN ('primary','secondary','admission','discharge','preop','postop','pathology','certificate','unspecified')),
      name TEXT NOT NULL,                         -- 医生原文，不改写
      code_text TEXT, code_system_text TEXT,      -- 仅打印码（如 ICD-10 J20.9），不推断、不 FK
      diagnosed_at REAL,
      health_problem_id TEXT REFERENCES health_problem(id),   -- 用户显式「采用为健康问题」后回填（FR11.4）
      note TEXT,
      source_page INTEGER, source_row_id TEXT,
      document_file_id TEXT REFERENCES document_file(id),
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE INDEX idx_diagnosis_patient_time ON diagnosis(patient_id, diagnosed_at DESC);
    CREATE INDEX idx_diagnosis_encounter ON diagnosis(encounter_id, ordinal);

    -- F6 OCR 结果（字段级留痕；page_index = 所属页，V3.99 起写真实页号）
    CREATE TABLE ocr_result (
      id TEXT PRIMARY KEY, document_file_id TEXT NOT NULL REFERENCES document_file(id),
      page_index INTEGER NOT NULL DEFAULT 0,
      raw_blocks TEXT NOT NULL,
      engine_version TEXT NOT NULL, created_at REAL NOT NULL);

    -- F6 页级识别文本（V3.99 / 迁移 v21，FR6.9 页级多卡）：一条 OCR 记录（单图或 PDF）
    -- 每页一行，失败/跳过页占位保页号；信息卡经 (document_file_id, page_index) 回到页。
    -- document_file.ocr_text 继续存拼接文本供 FTS，本表不进 FTS/AI 检索。
    CREATE TABLE document_page (
      id TEXT PRIMARY KEY,
      document_file_id TEXT NOT NULL REFERENCES document_file(id),
      page_index INTEGER NOT NULL,
      ocr_text TEXT,
      status TEXT NOT NULL DEFAULT 'ok' CHECK(status IN ('ok','failed','skipped','no_text')),
      created_at REAL NOT NULL,
      UNIQUE(document_file_id, page_index));
    CREATE INDEX idx_document_page_doc ON document_page(document_file_id, page_index);

    -- v22: committed card rows retain page provenance and make confirmation replay-safe.
    -- v25（子项目 D §C.0-6 / §D.0）：card_kind = 卡类（reviewState/save 按此找卡），
    -- entity_table = 回执所指真实实体表（validateReceipt/detail/exportCommits 按此找实体）——
    -- 「一卡多表」（处方表头 + 处方行）留痕解耦；两枚举 v25 列全 D1–D3。
    -- v27（子项目 J §0.4 改判）：新增 health_exam / clinical_conclusion 两卡类 → 第三次重建扩两枚举（迁移 v27，与本串同文）。
    CREATE TABLE ocr_card_commit (
      card_id TEXT NOT NULL,
      row_id TEXT NOT NULL,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      document_file_id TEXT NOT NULL REFERENCES document_file(id),
      page_index INTEGER NOT NULL CHECK(page_index >= 0),
      card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription','claim_item','medication','immunization','hospitalization','diagnosis','exam_report','surgery','treatment_record','health_exam','clinical_conclusion')),
      entity_table TEXT NOT NULL CHECK(entity_table IN ('metric_sample','encounter','prescription','claim_item','medication','immunization','hospitalization','diagnosis','exam_report','surgery','treatment_record','prescription_line','claim_line','lab_report','lab_result','health_exam','clinical_conclusion')),
      entity_id TEXT NOT NULL,
      encounter_id TEXT REFERENCES encounter(id),
      created_at REAL NOT NULL,
      PRIMARY KEY(card_id, row_id),
      FOREIGN KEY(document_file_id, page_index) REFERENCES document_page(document_file_id, page_index));
    CREATE INDEX idx_ocr_card_commit_source ON ocr_card_commit(document_file_id, page_index, card_kind);
    CREATE INDEX idx_ocr_card_commit_entity ON ocr_card_commit(card_kind, entity_id, patient_id);
    CREATE INDEX idx_ocr_card_commit_encounter ON ocr_card_commit(encounter_id, patient_id);
    CREATE INDEX idx_ocr_card_commit_entity_table ON ocr_card_commit(entity_table, entity_id, patient_id);

    -- F9 处方（BR-003 关键字段全确认才 confirmed=1）
    CREATE TABLE prescription (
      id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      document_file_id TEXT REFERENCES document_file(id),
      source TEXT NOT NULL CHECK(source IN ('ocr','electronic','manual','encounter','history')),
      hospital TEXT, doctor TEXT, prescribed_at REAL,
      advice_text TEXT,
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v25（子项目 D §C.6）：处方表头打印字段；advice_text 只承担「医嘱原文/整段用法」，
      -- 不再折叠药品行（行见 prescription_line）。prescription_type 存 canonical raw，展示经 fieldValueDisplay。
      department TEXT, prescription_no TEXT,
      prescription_type TEXT CHECK(prescription_type IN ('general','emergency','pediatric','narcotic','psychotropic','tcm','other')),
      fee_type_text TEXT, clinical_diagnosis TEXT, pharmacist_names TEXT, total_amount REAL);

    -- v25（子项目 D §C.6）：处方行实体（「卡类 = 事实表」三重绑定拆开）。
    -- BR-006/007：剂量/数量/频次/疗程一律原文 *_text + *_unit，不解析 REAL、不换算、不推算给药方案；
    -- 单价/金额为费用可 REAL。source_page + source_row_id（= 回执 row_id）留痕，文档经表头到达；
    -- medication_id 只由用户显式「采用为药品目录项」写入（不自动匹配）。
    -- 排在 stock_lot 之前：stock_lot.prescription_line_id 外键指向本表。
    CREATE TABLE prescription_line (
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
    CREATE INDEX idx_prescription_line_patient ON prescription_line(patient_id, prescription_id, ordinal);

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
    -- 物化/补录热路径（评审修正第二轮）：materializeWindow 的 NOT EXISTS 决议行
    -- 守卫与 recordTakenAt 的时段解析均按 plan_id + scheduled_for 扫描——
    -- 无索引时每剂一次全表扫，随剂量行累积线性劣化。
    CREATE INDEX idx_dose_log_plan_time ON medication_dose_log(plan_id, scheduled_for);

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
      last_reconciled_at REAL NOT NULL,
      -- v25（子项目 D §C.6）：批次挂处方行——只由用户在行详情「加入药箱」显式传入，不推断。
      prescription_line_id TEXT REFERENCES prescription_line(id));
    CREATE INDEX idx_stock_lot_med_expire ON stock_lot(patient_id, medication_id, expire_at);

    CREATE TABLE dose_lot_allocation (
      dose_log_id TEXT NOT NULL REFERENCES medication_dose_log(id),
      stock_lot_id TEXT NOT NULL REFERENCES stock_lot(id),
      planned_units REAL NOT NULL,
      confirmed_units REAL NOT NULL DEFAULT 0,
      PRIMARY KEY(dose_log_id, stock_lot_id));

    -- v27（子项目 J · round1 §E.1 / 融合方案 §五-5.4、§二）：体检 = 第三枢纽（门诊/急诊 encounter、住院期 hospitalization、体检 health_exam）。
    -- 表头 + 一般检查**打印原文**（*_text，BR-006）+ 总体结论/健康指导（原文）；一般检查可严格解析且 MetricType 有键者另投影 metric_sample。
    -- 排除 critical_flag / report_status / org_code / patient_name（§C.11 同口径）。排在 lab_report 之前：三表 health_exam_id 外键指向本表。
    CREATE TABLE health_exam (
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
    CREATE INDEX idx_health_exam_patient_time ON health_exam(patient_id, exam_date DESC);

    -- v26（子项目 D §C.5）：检验报告表头——采集/报告时间分离（趋势 x 轴应为采集时间）、标本类型、跨页共享
    -- 上下文、审核者/实验室/报告号（FR5.6 重复检测）。卡类仍是 metric_sample（不改历史回执语义）：
    -- 同一 card_id 的行提交复用同一表头，幂等键 source_card_id UNIQUE（手工录入 NULL）。
    -- 排在 metric_sample 之前：metric_sample.lab_report_id 外键指向本表。
    CREATE TABLE lab_report (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      document_file_id TEXT REFERENCES document_file(id),
      hospital TEXT, department TEXT, lab_name TEXT, report_no TEXT,
      specimen_type TEXT, specimen_no TEXT, test_class_text TEXT,
      clinical_diagnosis TEXT,
      collected_at REAL, received_at REAL, reported_at REAL,
      send_doctor TEXT, test_doctor TEXT, review_doctor TEXT,
      source_card_id TEXT UNIQUE,                 -- 生成本表头的确认卡 id（幂等键 + 反查；手工录入 NULL）
      source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v27：报告来源（融合方案 §三-3）与体检枢纽回指；NULL = v27 前未标注（读侧按 encounter/health_exam 推断呈现、不回填）。
      report_source TEXT CHECK(report_source IN ('outpatient','emergency','inpatient','health_exam') OR report_source IS NULL),
      health_exam_id TEXT REFERENCES health_exam(id));
    CREATE INDEX idx_lab_report_patient_time ON lab_report(patient_id, reported_at DESC);

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
      -- V3.86 / 迁移 v18：设备来源元数据与小时窗口聚合（FR16.1/FR7.9）——
      -- value=窗口均值、value_min/max=窗口极值、sample_count=窗口有效样本数（<3 不落行）；
      -- source 三键=HKSource 元数据（幂等键含来源，手输/医院行为 NULL）
      value_min REAL, value_max REAL, sample_count INTEGER,
      source_name TEXT, source_version TEXT, source_product TEXT,
      source_identifier TEXT, aggregation_kind TEXT, window_end REAL,
      measured_at REAL NOT NULL, created_at REAL NOT NULL,
      -- v26（子项目 D §C.5）：趋势点回指检验表头；abnormal_flag = 报告打印的 ↑↓/H/L（A 级来源事实，
      -- 不由 App 计算、不触发提示）。表尾追加 = 迁移 ADD COLUMN 同序。
      lab_report_id TEXT REFERENCES lab_report(id), abnormal_flag TEXT,
      -- v27：体检一般检查投影回指（只有严格 Double + 单位且 MetricType 有键的项才投影，BR-006）。
      health_exam_id TEXT REFERENCES health_exam(id));
    CREATE INDEX idx_metric_patient_time ON metric_sample(patient_id, metric_key, measured_at);
    CREATE INDEX idx_metric_source ON metric_sample(patient_id, metric_key, measured_at, source_name);
    CREATE INDEX idx_metric_device_identity ON metric_sample(patient_id, source_ref) WHERE origin = 'device';
    -- v28（2026-09-16 委员会评审）：时间轴/宫格查询索引（迁移同名 IF NOT EXISTS）。
    CREATE INDEX idx_metric_timeline ON metric_sample(patient_id, origin, measured_at DESC, id DESC);
    CREATE INDEX idx_metric_latest ON metric_sample(patient_id, excluded, metric_key, measured_at DESC);

    -- v26（子项目 D §C.5）：非数值/半定量检验项目（阴性 / 阳性(+) / <0.5 / 未检出）——原文保存、不猜数值、
    -- 不进趋势（分流规则：value 严格可解析且有单位 → metric_sample，否则 → 本表，不双写）。
    -- code_concept_id 仅用户批准的 F25 建议。报告详情 = 两表 UNION 按 ordinal。
    CREATE TABLE lab_result (                       -- 非数值/半定量项目：不进趋势
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      lab_report_id TEXT NOT NULL REFERENCES lab_report(id),
      ordinal INTEGER NOT NULL DEFAULT 0,
      item_name TEXT NOT NULL, item_code_text TEXT,
      result_text TEXT NOT NULL,                    -- 阴性 / 阳性(+) / 弱阳性 / <0.5 / 未检出（原文）
      comparator TEXT, unit TEXT, reference_text TEXT, abnormal_flag TEXT, method TEXT,
      code_concept_id TEXT REFERENCES code_concept(id),   -- 仅用户批准的 F25 建议
      source_page INTEGER, source_row_id TEXT,
      created_at REAL NOT NULL,
      UNIQUE(lab_report_id, ordinal));

    -- v26（子项目 D §C.4）：检查/影像/病理报告。report_type 存 canonical raw + CHECK（展示经 fieldValueDisplay）；
    -- findings/impression 原文叙事，App 不摘要不改写。**明确排除 critical_value_flag**：危急值是院内闭环
    -- 通知语义，一个布尔列会诱导预警/提示逻辑（BR-004/BR-012 越线面）——报告印有「危急值」留在 impression 原文。
    -- 排除 report_file_path（原件即 document_file）、DICOM。
    CREATE TABLE exam_report (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      encounter_id TEXT REFERENCES encounter(id),
      document_file_id TEXT REFERENCES document_file(id),
      report_type TEXT NOT NULL
        CHECK(report_type IN ('ct','mri','xray','ultrasound','ecg','endoscopy','pathology','nuclear','other')),
      hospital TEXT, department TEXT, report_no TEXT,
      exam_part TEXT, exam_method TEXT,           -- 检查部位 / 检查方法（打印文本）
      exam_at REAL, reported_at REAL,
      findings TEXT, impression TEXT,             -- 检查所见 / 诊断意见（原文叙事）
      apply_doctor TEXT, report_doctor TEXT, review_doctor TEXT,
      source TEXT NOT NULL CHECK(source IN ('ocr','manual')),
      confirmed INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v27：报告来源（融合方案 §三-3）与体检枢纽回指；NULL = v27 前未标注（读侧按 encounter/health_exam 推断呈现、不回填）。
      report_source TEXT CHECK(report_source IN ('outpatient','emergency','inpatient','health_exam') OR report_source IS NULL),
      health_exam_id TEXT REFERENCES health_exam(id));
    CREATE INDEX idx_exam_report_patient_time ON exam_report(patient_id, exam_at DESC);

    -- v27（round1 §E.1 / 融合方案 §六-6.3）：统一结论表——检验结论 / 检查结论 / 体检总检 / 异常发现 / 健康建议 / 复查建议 / 就医建议。
    -- 三外键恰一非空（CHECK）；content 原文；severity_text **只存打印文本**（融合方案 severity_level 的 正常/关注/异常/需复查 不编码不排序不着色，BR-004/012）。
    CREATE TABLE clinical_conclusion (
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
    CREATE INDEX idx_clinical_conclusion_health_exam ON clinical_conclusion(health_exam_id, ordinal);
    CREATE INDEX idx_clinical_conclusion_lab ON clinical_conclusion(lab_report_id, ordinal);
    CREATE INDEX idx_clinical_conclusion_exam ON clinical_conclusion(exam_report_id, ordinal);

    -- v27（原 D3 §C.8）：手术记录。编码/级别只存打印文本；植入物原文（MRI 禁忌/复查所需）。排除麻醉/核查/清点字段（仅附件）。
    CREATE TABLE surgery (
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
    CREATE INDEX idx_surgery_patient_time ON surgery(patient_id, surgery_at DESC);

    -- v27（原 D3 §C.9）：门诊治疗/输液/注射/理疗记录。drugs_text 原文不拆行、不进 prescription_line/medication（BR-006/007，避免双计）。
    CREATE TABLE treatment_record (
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
    CREATE INDEX idx_treatment_patient_time ON treatment_record(patient_id, treated_at DESC);

    -- v27（round1 §E.1 / 融合方案 §七-7.2 方案 A）：统一报告头**视图**（不做物理大表、不入备份）。
    -- report_source 缺失时按外键推断呈现（体检子报告 → health_exam），不回写。Domain 读模型 ClinicalReportSummary。
    -- 视图正文内不得出现分号或 -- 注释（SchemaMigrations.statements 与 test-schema-integrity.py 均按分号切句）；与迁移 v27 同文。
    CREATE VIEW v_clinical_report AS
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

    -- F16 同步锚点（V3.86 / 迁移 v18）：HKAnchoredObjectQuery 增量兜底的持久化
    -- 落点——DB 随 .vlbu 备份往返（UserDefaults 不入备份、恢复后锚点丢失=漏读/重放）
    CREATE TABLE hk_sync_anchor (
      anchor_key TEXT PRIMARY KEY,
      anchor_value TEXT NOT NULL,
      updated_at REAL NOT NULL);

    CREATE TABLE hk_import_binding (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      id TEXT NOT NULL UNIQUE,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      time_zone TEXT NOT NULL,
      connected_at REAL NOT NULL);
    CREATE TABLE hk_sample_index (
      sample_id TEXT NOT NULL,
      type_key TEXT NOT NULL,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      source_id TEXT NOT NULL,
      start_at REAL NOT NULL, end_at REAL NOT NULL,
      PRIMARY KEY(sample_id, type_key, patient_id));
    CREATE INDEX idx_hk_sample_window ON hk_sample_index(patient_id, type_key, start_at, end_at);

    -- v22: local-only recovery state; never infer ownership from a restored aggregate's bucket key.
    CREATE TABLE hk_pending_batch (
      binding_id TEXT NOT NULL REFERENCES hk_import_binding(id) ON DELETE CASCADE,
      type_key TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      PRIMARY KEY(binding_id, type_key));
    CREATE TABLE hk_import_status (
      binding_id TEXT PRIMARY KEY REFERENCES hk_import_binding(id) ON DELETE CASCADE,
      report_json TEXT NOT NULL,
      updated_at REAL NOT NULL);
    CREATE TABLE hk_projection_state (
      binding_id TEXT NOT NULL REFERENCES hk_import_binding(id) ON DELETE CASCADE,
      metric_id TEXT NOT NULL REFERENCES metric_sample(id) ON DELETE CASCADE,
      PRIMARY KEY(binding_id, metric_id));
    CREATE INDEX idx_hk_projection_metric ON hk_projection_state(metric_id);

    -- FR6.9 待办卡（V3.96 / 迁移 v19，data-flow §3.5 单一事实源）：
    -- 「跳过稍后」暂存的 D 级草稿卡——partial_data/raw_text 恒 D 级，
    -- BR-003 绝对禁止：不参与搜索索引/FTS 投影/AI 检索/导出（表级排除）。
    -- 生命周期：pending → (in_progress) → resolved / expired(7d) /
    -- archived(30d，§21.3；tech v19 登记枚举未含，按产品行为补列)。
    CREATE TABLE pending_card (
      id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL REFERENCES patient_profile(id),
      source_type TEXT NOT NULL CHECK(source_type IN ('ocr','voice','manual')),
      source_doc_id TEXT REFERENCES document_file(id),
      source_page INTEGER,                   -- V3.99：所属页号（与 source_doc_id 配对；单图 0）
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
    CREATE INDEX idx_pending_card_patient_status ON pending_card(patient_id, status, created_at);
    CREATE INDEX idx_pending_card_source_doc ON pending_card(source_doc_id);

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
      qualified INTEGER NOT NULL DEFAULT 0, scheduled_at REAL,
      delivered_state TEXT NOT NULL, created_at REAL NOT NULL);
    CREATE INDEX idx_alert_qualified ON alert_event(patient_id, qualified, created_at);
    -- FR16.2 去重键（patient_id + rule_id）前缀扫描——无索引时每次预警评估
    -- 全表扫并逐行 json_extract，随事件累积线性劣化。
    CREATE INDEX idx_alert_event_patient_rule ON alert_event(patient_id, rule_id);

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
      note TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v30（全仓审查 2026-09-18 F-A4-01）：过敏原类型（药品/食物/其他，FR23.1 表单第一步）——
      -- 此前表单采集后无落点、静默丢弃。表尾追加 = 迁移 ADD COLUMN 同序。
      allergen_kind TEXT);
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
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v27（FR10.7 / round1 §E.1）：复诊预约挂产生它的就诊；purpose 存 canonical raw（展示经 fieldValueDisplay）；
      -- 'visit' 预约「已完成 → 补录就诊」时由 store 回写 encounter_id。表尾追加 = 迁移 ADD COLUMN 同序。
      encounter_id TEXT REFERENCES encounter(id),
      purpose TEXT CHECK(purpose IN ('visit','followUp','exam','healthExam') OR purpose IS NULL));
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
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v27（round1 §E.1）：来源实体多态引用（白名单 encounter/appointment/health_exam 由 store 校验，无 FK）。
      source_table TEXT, source_id TEXT);
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
      created_at REAL NOT NULL, updated_at REAL NOT NULL,
      -- v25（子项目 D §C.7）：票面支付三分（统筹/个人现金/个人账户，打印数）、票据号（FR5.6 重复检测）、
      -- 医保类型打印文本。ClaimStore.totals 仍只对 amount 求和（FR13.7 纯事实，不用行反推）。
      reimbursed_amount REAL, out_of_pocket REAL, personal_account_amount REAL, invoice_no TEXT, insurance_type_text TEXT);
    CREATE INDEX idx_claim_patient_encounter ON claim_item(patient_id, encounter_id, date);

    -- v25（子项目 D §C.7）：费用明细行（费用清单页 item_type='fee'）。行全部可选；退费行按票面负数原样，
    -- 不设 status；fee_category_text 为打印文本不编码；数量为原文 + 单位（BR-006 同纪律）。
    CREATE TABLE claim_line (
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
    CREATE INDEX idx_claim_line_patient ON claim_line(patient_id, claim_item_id, ordinal);

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

    -- 词表锚定术语表(2026-09-21, F25 词表证据层/FR25.12⑬): 识别侧匹配词汇——
    -- 药名/剂型/给药途径/频次; 与 code_alias 合成词表单源(同一扫描出口);
    -- concept_id 可空(许可后补标准码); 词表只做匹配建议, 不承载事实(BR-003)。
    CREATE TABLE lexicon_term (
      term TEXT NOT NULL, locale TEXT NOT NULL,   -- zh-Hans/zh-Hant/zh-Hant-TW/zh-Hant-HK/en
      category TEXT NOT NULL CHECK(category IN ('medication','drug_form','route','frequency')),
      concept_id TEXT REFERENCES code_concept(id),-- 可空: 有码后补(FR25.11 只补不覆)
      priority INTEGER NOT NULL DEFAULT 0,
      bundle_version TEXT NOT NULL,
      retired_at REAL,                            -- 软删纪律对齐 resolver_override
      PRIMARY KEY(term, locale, category));
    CREATE INDEX idx_lexicon_term_category ON lexicon_term(category);
    """
}
