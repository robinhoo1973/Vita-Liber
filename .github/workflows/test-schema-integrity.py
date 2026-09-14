#!/usr/bin/env python3
"""Execute the actual baseline DDL and the v23 rebuild against SQLite, without Apple SDKs."""
from pathlib import Path
import re
import sqlite3
import unittest
from contextlib import closing

ROOT = Path(__file__).resolve().parents[2]


def baseline():
    text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaV2.swift").read_text()
    return re.search(r'static let ddl\s*=\s*"""(.*?)"""', text, re.S).group(1)


class SchemaIntegrityTests(unittest.TestCase):
    def test_fresh_database_creates_all_indexes_and_relationship_columns(self):
        with closing(sqlite3.connect(":memory:")) as db:
            db.execute("PRAGMA foreign_keys = ON")
            db.executescript(baseline())
            columns = {row[1] for row in db.execute("PRAGMA table_info(ocr_card_commit)")}
            self.assertIn("encounter_id", columns)
            self.assertEqual(list(db.execute("PRAGMA foreign_key_check")), [])
            self.assertIn("hk_import_status", {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")})

    def test_v23_preserves_v22_receipts_and_accepts_new_card_kinds(self):
        with closing(sqlite3.connect(":memory:")) as db:
            # GRDB registers this function on Apple. This test exercises schema/FKs, not the tokenizer.
            db.create_function("bigrams", 1, lambda value: " ".join((value or "")[i:i + 2] for i in range(max(0, len(value or "") - 1))))
            db.execute("PRAGMA foreign_keys = ON")
            db.executescript(baseline())
            db.execute("DROP TABLE ocr_card_commit")
            db.executescript("""
                CREATE TABLE ocr_card_commit (
                  card_id TEXT NOT NULL, row_id TEXT NOT NULL,
                  patient_id TEXT NOT NULL REFERENCES patient_profile(id),
                  document_file_id TEXT NOT NULL REFERENCES document_file(id), page_index INTEGER NOT NULL,
                  card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription')),
                  entity_id TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(card_id,row_id),
                  FOREIGN KEY(document_file_id,page_index) REFERENCES document_page(document_file_id,page_index));
                INSERT INTO patient_profile (id,display_name,relation,created_at,updated_at) VALUES ('p','Owner','self',0,0);
                INSERT INTO document_file (id,patient_id,doc_type,sha256,mime_type,origin,created_at,updated_at)
                  VALUES ('d','p','record','hash','image/png','camera',0,0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg','d',0,'ok',0);
                INSERT INTO encounter (id,patient_id,date,kind,created_at,updated_at) VALUES ('e','p',0,'outpatient',0,0);
                INSERT INTO ocr_card_commit VALUES ('c','r','p','d',0,'encounter','e',0);
                """)
            text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
            migration = re.search(r'Step\(version: 23,.*?sql:\s*"""(.*?)"""', text, re.S).group(1)
            db.executescript("BEGIN;" + migration + "PRAGMA user_version=23; COMMIT;")
            self.assertEqual(db.execute("SELECT card_id,row_id,encounter_id FROM ocr_card_commit").fetchall(), [("c", "r", None)])
            db.execute("INSERT INTO ocr_card_commit VALUES ('c2','r2','p','d',0,'claim_item','receipt','e',0)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO ocr_card_commit VALUES ('c3','r3','p','d',0,'medication','m','missing',0)")

    # 子项目 D · D1-1（discussions/2026-09-13-hospital-card-schema-round1 §D.1/§D.4）：
    # 冻结的 v24 基线夹具 + v25 SQL 步 = 全新库基线（pragma_table_info 逐表相等）；
    # ocr_card_commit 重建搬运无损、entity_table = card_kind；新表成员隔离 FK 生效。
    # 回填为 Swift 代码步（GRDBStore.backfillRecognitionFactLines），由 CoreKit
    # SchemaV25GoldenTests 在 macOS 覆盖；本测试只复核 SQL 半场（Linux 可跑）。
    TABLES_V25 = ["encounter", "prescription", "prescription_line", "claim_item", "claim_line",
                  "document_file", "stock_lot", "ocr_card_commit"]

    @staticmethod
    def columns(db, table):
        return sorted((r[1], r[2], r[3], r[4], r[5]) for r in db.execute(f"PRAGMA table_info({table})"))

    @staticmethod
    def statements(sql):
        # v25/v26 步无触发器体、字面量内无分号——去掉 `--` 行注释后按分号切分即语句边界
        # （与 SchemaMigrations.statements 同结果；v26 步内含 SQL 行注释）。
        return [s.strip() for s in re.sub(r"--[^\n]*", "", sql).split(";") if s.strip()]

    @classmethod
    def apply_idempotent(cls, db, sql):
        """镜像 GRDBStore.executeIdempotent（default 路径）：逐语句执行，ADD COLUMN 经 pragma_table_info 列存在守卫。"""
        for statement in cls.statements(sql):
            add = re.match(r"ALTER TABLE (\w+) ADD COLUMN (\w+)", statement)
            if add and db.execute(f"SELECT COUNT(*) FROM pragma_table_info('{add.group(1)}') WHERE name = ?", (add.group(2),)).fetchone()[0]:
                continue
            db.execute(statement)

    # 纯 SQL 步的步级声明（`sql: ""` 的 v13/v15 代码步不匹配——Python 侧不可重放，只在 v16 以下链上出现）。
    STEP_PATTERN = re.compile(r'Step\(version: (\d+), name: "([^"]+)",\s*sql: """(.*?)"""(?:,\s*transactional: (true|false))?(?:,\s*fkCheckTable: "(\w+)")?\)', re.S)

    @classmethod
    def steps(cls):
        text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
        return [(int(version), name, sql, flag == "true", fk_table or None) for version, name, sql, flag, fk_table in cls.STEP_PATTERN.findall(text)]

    @classmethod
    def latest_version(cls):
        return max(version for version, *_ in cls.steps())

    @classmethod
    def apply_pending(cls, db, after):
        """镜像 GRDBStore.migrateIncremental 走完整 pending 链（与 Swift 金样 `GRDBStore(writer:)` 同口径——老库逐步升级到
        最新 = 全新库基线，后续每个新迁移步落地时既有金样自动覆盖）：调用方已在事务外关闭外键；transactional 步 =
        单事务（逐语句幂等 + fkCheckTable 校验 + 版本推进），纯 SQL 步 = 逐语句幂等 + 版本推进。要求 db 为自动提交模式。"""
        for version, name, sql, transactional, fk_table in cls.steps():
            if version <= after:
                continue
            if transactional:
                db.execute("BEGIN")
                cls.apply_idempotent(db, sql)
                if fk_table and list(db.execute(f"PRAGMA foreign_key_check({fk_table})")):
                    db.execute("ROLLBACK")
                    raise AssertionError(f"v{version} {name}: fkCheckTable {fk_table} 搬运后外键悬空，整步回滚")
                db.execute(f"PRAGMA user_version = {version}")
                db.execute("COMMIT")
            else:
                cls.apply_idempotent(db, sql)
                db.execute(f"PRAGMA user_version = {version}")

    def test_v25_upgrades_frozen_v24_baseline_to_fresh_baseline_and_preserves_receipts(self):
        fixture = (ROOT / "CoreKit/Tests/CoreKitTests/Fixtures/schema_v24_baseline.sql").read_text()
        text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
        step = re.search(r'Step\(version: 25,.*?sql:\s*"""(.*?)"""', text, re.S)
        self.assertIsNotNone(step, "v25 recognition-fact-lines 迁移步缺失")
        migration = step.group(1)
        bigrams = lambda value: " ".join((value or "")[i:i + 2] for i in range(max(0, len(value or "") - 1)))
        with closing(sqlite3.connect(":memory:")) as legacy, closing(sqlite3.connect(":memory:")) as fresh:
            for db in (legacy, fresh):
                db.create_function("bigrams", 1, bigrams)
                db.execute("PRAGMA foreign_keys = ON")
            fresh.executescript(baseline())
            legacy.executescript(fixture)
            legacy.execute("PRAGMA user_version = 24")
            legacy.executescript("""
                INSERT INTO patient_profile (id,display_name,relation,created_at,updated_at) VALUES ('p','Owner','self',0,0);
                INSERT INTO document_file (id,patient_id,doc_type,sha256,mime_type,origin,created_at,updated_at)
                  VALUES ('d','p','处方单','hash','image/png','import',0,0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg','d',0,'ok',0);
                INSERT INTO prescription (id,patient_id,document_file_id,source,prescribed_at,advice_text,confirmed,created_at,updated_at)
                  VALUES ('rx','p','d','ocr',0,'Drug A 0.5g',1,0,0);
                INSERT INTO ocr_card_commit (card_id,row_id,patient_id,document_file_id,page_index,card_kind,entity_id,encounter_id,created_at)
                  VALUES ('c','r','p','d',0,'prescription','rx',NULL,1);
                """)
            # runner（GRDBStore.migrateIncremental）在事务外关闭外键、表重建步单事务执行
            legacy.execute("PRAGMA foreign_keys = OFF")
            legacy.executescript("BEGIN;" + migration + "PRAGMA user_version = 25; COMMIT;")
            legacy.execute("PRAGMA foreign_keys = ON")
            for table in self.TABLES_V25:
                self.assertEqual(self.columns(legacy, table), self.columns(fresh, table), f"{table}: 老库逐步升级 ≠ 全新库基线")
            self.assertEqual(legacy.execute("PRAGMA user_version").fetchone()[0], 25)
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check")), [])
            self.assertEqual(legacy.execute("SELECT card_id,row_id,card_kind,entity_table,entity_id,encounter_id FROM ocr_card_commit").fetchall(),
                             [("c", "r", "prescription", "prescription", "rx", None)], "搬运无损且 entity_table = card_kind")
            self.assertEqual(legacy.execute("SELECT advice_text FROM prescription WHERE id='rx'").fetchone(), ("Drug A 0.5g",), "advice_text 原样保留")
            indexes = {r[0] for r in legacy.execute("SELECT name FROM sqlite_master WHERE type='index'")}
            for name in ("idx_ocr_card_commit_source", "idx_ocr_card_commit_entity", "idx_ocr_card_commit_encounter",
                         "idx_ocr_card_commit_entity_table", "idx_prescription_line_patient", "idx_claim_line_patient"):
                self.assertIn(name, indexes)
            # entity_table 枚举一次列全 D1–D3：行表可写、未知表名被 CHECK 拒绝
            legacy.execute("INSERT INTO prescription_line (id,prescription_id,patient_id,ordinal,printed_name,dose_text,dose_unit,confirmed,created_at,updated_at)"
                           " VALUES ('l0','rx','p',0,'Drug A','0.5','g',1,0,0)")
            legacy.execute("INSERT INTO ocr_card_commit VALUES ('c','r2','p','d',0,'prescription','prescription_line','l0',NULL,2)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO ocr_card_commit VALUES ('c','r3','p','d',0,'prescription','bogus_table','l0',NULL,3)")
            # 成员隔离：行表 patient_id 悬空被拒；UNIQUE(prescription_id, ordinal) 生效
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO prescription_line (id,prescription_id,patient_id,ordinal,printed_name,confirmed,created_at,updated_at)"
                               " VALUES ('l9','rx','ghost',9,'X',1,0,0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO prescription_line (id,prescription_id,patient_id,ordinal,printed_name,confirmed,created_at,updated_at)"
                               " VALUES ('l1','rx','p',0,'Dup',1,0,0)")
            legacy.execute("INSERT INTO claim_item (id,patient_id,item_type,confirmed,created_at,updated_at) VALUES ('ci','p','fee',1,0,0)")
            legacy.execute("INSERT INTO claim_line (id,claim_item_id,patient_id,ordinal,item_name,created_at) VALUES ('cl','ci','p',0,'挂号费',0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO claim_line (id,claim_item_id,patient_id,ordinal,item_name,created_at) VALUES ('cl2','missing','p',1,'X',0)")
            # BR-006/007：剂量/数量为文本 + 单位列，表内无 REAL 剂量列
            line_types = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(prescription_line)")}
            for column in ("dose_text", "dose_unit", "quantity_text", "quantity_unit", "frequency_text", "duration_text"):
                self.assertEqual(line_types[column], "TEXT", column)
            # 幂等纪律：新表/新索引语句一律 IF NOT EXISTS（在全新库上重放不炸）；表重建只针对 ocr_card_commit
            creates = [s for s in self.statements(migration) if re.match(r"CREATE (TABLE|INDEX)", s)]
            rebuild = [s for s in creates if not s.startswith(("CREATE TABLE IF NOT EXISTS", "CREATE INDEX IF NOT EXISTS"))]
            self.assertTrue(all("ocr_card_commit" in s for s in rebuild), rebuild)
            for statement in creates:
                if statement.startswith(("CREATE TABLE IF NOT EXISTS", "CREATE INDEX IF NOT EXISTS")):
                    fresh.execute(statement)
            adds = [s for s in self.statements(migration) if s.startswith("ALTER TABLE") and "ADD COLUMN" in s]
            self.assertEqual(len(adds), 5 + 7 + 1 + 5 + 2, "encounter 5 / prescription 7 / stock_lot 1 / claim_item 5 / document_file 2")

    # 子项目 D · D2-1（discussions/2026-09-13-hospital-card-schema-round1 §C.2–C.5 / §D.2 / §D.4）：
    # 冻结的 v25 基线夹具 + v26 SQL 步（default 路径：executeIdempotent 逐语句 + 版本推进）= 全新库基线；
    # lab_report 纯 SQL 回填——每张历史检验卡（card_id，同页同卡类唯一）一条表头，幂等键 source_card_id
    # UNIQUE，只从已确认回执生成（BR-003）；metric_sample.measured_at 不改；红线 DDL 断言
    # （无 critical/triage 列、诊断编码只存打印文本不 FK 码表、成员隔离 FK、CHECK 枚举）。
    TABLES_V26 = ["hospitalization", "diagnosis", "exam_report", "lab_report", "lab_result", "metric_sample", "ocr_card_commit"]

    def test_v26_upgrades_frozen_v25_baseline_and_backfills_lab_report_headers(self):
        fixture = (ROOT / "CoreKit/Tests/CoreKitTests/Fixtures/schema_v25_baseline.sql").read_text()
        text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
        step = re.search(r'Step\(version: 26,.*?sql:\s*"""(.*?)"""', text, re.S)
        self.assertIsNotNone(step, "v26 clinical-episodes 迁移步缺失")
        migration = step.group(1)
        bigrams = lambda value: " ".join((value or "")[i:i + 2] for i in range(max(0, len(value or "") - 1)))
        with closing(sqlite3.connect(":memory:")) as legacy, closing(sqlite3.connect(":memory:")) as fresh:
            # 自动提交 = GRDB writeWithoutTransaction：runner 在事务外切换 PRAGMA foreign_keys（事务内是 no-op），
            # Python sqlite3 默认在 DML 前隐式 BEGIN，会让后续 PRAGMA 静默失效。
            legacy.isolation_level = None
            for db in (legacy, fresh):
                db.create_function("bigrams", 1, bigrams)
                db.execute("PRAGMA foreign_keys = ON")
            fresh.executescript(baseline())
            legacy.executescript(fixture)
            legacy.execute("PRAGMA user_version = 25")
            legacy.executescript("""
                INSERT INTO patient_profile (id,display_name,relation,created_at,updated_at) VALUES ('p','Owner','self',0,0);
                INSERT INTO document_file (id,patient_id,doc_type,sha256,mime_type,origin,created_at,updated_at)
                  VALUES ('d','p','检验报告','hash','image/png','import',0,0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg0','d',0,'ok',0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg1','d',1,'ok',0);
                -- 历史检验卡 card（第 0 页）：两行数值 + 两条 v25 形态回执（entity_table = card_kind）
                INSERT INTO metric_sample (id,patient_id,metric_key,value,unit,origin,self_measured,excluded,source_ref,ref_low,ref_high,ref_source_label,raw_label,measured_at,created_at)
                  VALUES ('m1','p','glucose',5.6,'mmol/L','hospital',0,0,'d#p0',3.9,6.1,'仁济医院','葡萄糖',1700000000,10);
                INSERT INTO metric_sample (id,patient_id,metric_key,value,unit,origin,self_measured,excluded,source_ref,ref_low,ref_high,ref_source_label,raw_label,measured_at,created_at)
                  VALUES ('m2','p','hemoglobin',135,'g/L','hospital',0,0,'d#p0',115,150,'仁济医院','血红蛋白',1700000000,11);
                INSERT INTO ocr_card_commit VALUES ('card','r1','p','d',0,'metric_sample','metric_sample','m1',NULL,10);
                INSERT INTO ocr_card_commit VALUES ('card','r2','p','d',0,'metric_sample','metric_sample','m2',NULL,11);
                -- 第二张卡 card2（第 1 页）→ 第二条表头
                INSERT INTO metric_sample (id,patient_id,metric_key,value,unit,origin,self_measured,excluded,source_ref,ref_source_label,raw_label,measured_at,created_at)
                  VALUES ('m4','p','glucose',5.1,'mmol/L','hospital',0,0,'d#p1','仁济医院','葡萄糖',1700086400,13);
                INSERT INTO ocr_card_commit VALUES ('card2','r4','p','d',1,'metric_sample','metric_sample','m4',NULL,13);
                -- 手输行：无回执，不得挂表头
                INSERT INTO metric_sample (id,patient_id,metric_key,value,unit,origin,self_measured,measured_at,created_at)
                  VALUES ('m3','p','glucose',6.0,'mmol/L','manual',1,1700000100,12);
                """)
            # runner（GRDBStore.migrateIncremental）：事务外关闭外键 → v26 default 路径逐语句幂等执行 → 版本推进 → 后续步
            # （v27 起，表重建步 transactional）继续走完 pending 链 → 复位外键。列集比对对象是全新库基线，故必须走完整链
            # （与 SchemaV26GoldenTests 经 GRDBStore(writer:) 升级同口径）；本步专属断言（回填/枚举/红线）不受后续步影响。
            legacy.execute("PRAGMA foreign_keys = OFF")
            self.apply_pending(legacy, 25)
            legacy.execute("PRAGMA foreign_keys = ON")
            for table in self.TABLES_V26:
                self.assertEqual(self.columns(legacy, table), self.columns(fresh, table), f"{table}: 老库逐步升级 ≠ 全新库基线")
            self.assertEqual(legacy.execute("PRAGMA user_version").fetchone()[0], self.latest_version())
            self.assertGreaterEqual(self.latest_version(), 26)
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check")), [], "回填后 metric_sample.lab_report_id 不得悬空")
            indexes = {r[0] for r in legacy.execute("SELECT name FROM sqlite_master WHERE type='index'")}
            for name in ("idx_hospitalization_patient", "idx_diagnosis_patient_time", "idx_diagnosis_encounter",
                         "idx_exam_report_patient_time", "idx_lab_report_patient_time"):
                self.assertIn(name, indexes)
            # 回填：每卡一条表头（id = card_id，UUID 形态与全表 id 同型；幂等键 source_card_id）；
            # hospital 取旧行 ref_source_label；reported_at = 卡内 MAX(measured_at)；created_at = 回执 MIN(created_at)
            headers = "SELECT id,patient_id,document_file_id,hospital,reported_at,source_card_id,source,confirmed,created_at,updated_at FROM lab_report ORDER BY id"
            expected_headers = [("card", "p", "d", "仁济医院", 1700000000.0, "card", "ocr", 1, 10.0, 10.0),
                                ("card2", "p", "d", "仁济医院", 1700086400.0, "card2", "ocr", 1, 13.0, 13.0)]
            self.assertEqual(legacy.execute(headers).fetchall(), expected_headers)
            rows = "SELECT id,lab_report_id,measured_at,abnormal_flag FROM metric_sample ORDER BY id"
            expected_rows = [("m1", "card", 1700000000.0, None), ("m2", "card", 1700000000.0, None),
                             ("m3", None, 1700000100.0, None), ("m4", "card2", 1700086400.0, None)]
            self.assertEqual(legacy.execute(rows).fetchall(), expected_rows, "只补 lab_report_id；measured_at 不改；手输行不挂表头")
            # 幂等：重放 v26 不增行、不改列；用户事后改写表头 → 重放不覆盖（INSERT … WHERE NOT EXISTS 只补缺）
            legacy.execute("UPDATE lab_report SET hospital = '用户改写' WHERE id = 'card'")
            legacy.execute("PRAGMA foreign_keys = OFF")
            self.apply_idempotent(legacy, migration)
            legacy.execute("PRAGMA foreign_keys = ON")
            self.assertEqual(legacy.execute("SELECT COUNT(*) FROM lab_report").fetchone(), (2,), "回填重跑不重复")
            self.assertEqual(legacy.execute("SELECT hospital FROM lab_report WHERE id = 'card'").fetchone(), ("用户改写",))
            self.assertEqual(legacy.execute(rows).fetchall(), expected_rows)
            # 幂等纪律：v26 无表重建——建表/建索引一律 IF NOT EXISTS；增列恰两条且都在 metric_sample
            creates = [s for s in self.statements(migration) if re.match(r"CREATE (TABLE|INDEX)", s)]
            self.assertEqual(len(creates), 5 + 5, "五表 + 五索引")
            self.assertTrue(all(s.startswith(("CREATE TABLE IF NOT EXISTS", "CREATE INDEX IF NOT EXISTS")) for s in creates), creates)
            for statement in creates:
                fresh.execute(statement)   # 全新库重放不炸
            adds = [s for s in self.statements(migration) if s.startswith("ALTER TABLE") and "ADD COLUMN" in s]
            self.assertEqual(sorted(re.match(r"ALTER TABLE (\w+) ADD COLUMN (\w+)", s).groups() for s in adds),
                             [("metric_sample", "abnormal_flag"), ("metric_sample", "lab_report_id")])
            # 红线（BR-004/012）：检查报告无危急值/分级布尔列；诊断编码只存打印文本，不 FK 码表（BR-003）
            exam_columns = {r[1] for r in legacy.execute("PRAGMA table_info(exam_report)")}
            self.assertFalse({c for c in exam_columns if "critical" in c or "triage" in c or "urgent" in c}, exam_columns)
            self.assertLessEqual({"findings", "impression", "report_type"}, exam_columns)
            diagnosis_columns = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(diagnosis)")}
            self.assertEqual((diagnosis_columns["code_text"], diagnosis_columns["code_system_text"]), ("TEXT", "TEXT"))
            self.assertEqual({r[2] for r in legacy.execute("PRAGMA foreign_key_list(diagnosis)")},
                             {"patient_profile", "encounter", "health_problem", "document_file"}, "diagnosis 不得 FK 到 code_concept/ICD 字典")
            # BR-006/007：定性结果原文列为 TEXT，无 REAL 数值列；abnormal_flag 为打印文本
            result_columns = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(lab_result)")}
            for column in ("result_text", "comparator", "unit", "reference_text", "abnormal_flag"):
                self.assertEqual(result_columns[column], "TEXT", column)
            self.assertNotIn("REAL", {t for c, t in result_columns.items() if c not in ("created_at",)})
            # 成员隔离：每张新表 patient_id 悬空被拒（前提：外键执法已真实复位开启）
            self.assertEqual(legacy.execute("PRAGMA foreign_keys").fetchone(), (1,), "外键必须已复位开启，否则下列拒绝断言空转")
            legacy.execute("INSERT INTO encounter (id,patient_id,date,kind,created_at,updated_at) VALUES ('e','p',0,'inpatient',0,0)")
            ghosts = [
                "INSERT INTO hospitalization (id,patient_id,encounter_id,source,created_at,updated_at) VALUES ('h9','ghost','e','ocr',0,0)",
                "INSERT INTO diagnosis (id,patient_id,name,created_at,updated_at) VALUES ('dx9','ghost','X',0,0)",
                "INSERT INTO exam_report (id,patient_id,report_type,source,created_at,updated_at) VALUES ('x9','ghost','ct','ocr',0,0)",
                "INSERT INTO lab_report (id,patient_id,source,created_at,updated_at) VALUES ('lr9','ghost','manual',0,0)",
                "INSERT INTO lab_result (id,patient_id,lab_report_id,item_name,result_text,created_at) VALUES ('r9','ghost','card','X','阴性',0)",
            ]
            for sql in ghosts:
                with self.assertRaises(sqlite3.IntegrityError, msg=sql):
                    legacy.execute(sql)
            # CHECK 枚举 canonical raw；hospitalization 1:0..1（UNIQUE encounter_id）；lab_result UNIQUE(lab_report_id, ordinal) + 表头 FK
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO exam_report (id,patient_id,report_type,source,created_at,updated_at) VALUES ('x1','p','bogus','ocr',0,0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO diagnosis (id,patient_id,diagnosis_type,name,created_at,updated_at) VALUES ('dx1','p','bogus','X',0,0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO hospitalization (id,patient_id,encounter_id,source,created_at,updated_at) VALUES ('h1','p','e','bogus',0,0)")
            legacy.execute("INSERT INTO hospitalization (id,patient_id,encounter_id,source,confirmed,created_at,updated_at) VALUES ('h1','p','e','ocr',1,0,0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO hospitalization (id,patient_id,encounter_id,source,created_at,updated_at) VALUES ('h2','p','e','manual',0,0)")
            legacy.execute("INSERT INTO exam_report (id,patient_id,encounter_id,report_type,impression,source,confirmed,created_at,updated_at) VALUES ('x1','p','e','pathology','原文','ocr',1,0,0)")
            legacy.execute("INSERT INTO diagnosis (id,patient_id,encounter_id,diagnosis_type,name,code_text,created_at,updated_at) VALUES ('dx1','p','e','discharge','急性支气管炎','J20.9',0,0)")
            legacy.execute("INSERT INTO lab_result (id,patient_id,lab_report_id,ordinal,item_name,result_text,created_at) VALUES ('r1','p','card',0,'HBsAg','阴性',0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO lab_result (id,patient_id,lab_report_id,ordinal,item_name,result_text,created_at) VALUES ('r2','p','card',0,'HBeAg','阴性',0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO lab_result (id,patient_id,lab_report_id,ordinal,item_name,result_text,created_at) VALUES ('r3','p','missing',1,'X','阴性',0)")
            # 回执 entity_table 枚举（v25 一次列全）已可指向五张新表
            for entity_table, entity_id in (("hospitalization", "h1"), ("diagnosis", "dx1"), ("exam_report", "x1"), ("lab_report", "card"), ("lab_result", "r1")):
                legacy.execute("INSERT INTO ocr_card_commit VALUES (?,?,?,?,?,?,?,?,?,?)",
                               (f"c-{entity_table}", "r0", "p", "d", 0, "metric_sample" if entity_table.startswith("lab") else entity_table, entity_table, entity_id, None, 0))
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check")), [])

    # 子项目 J · J1（discussions/2026-09-14-card-hierarchy-round1 §E.1/§E.7 / recognition-remediation-design §0.4；并入原 D3 §C.8–C.10）：
    # 冻结的 v26 基线夹具 + v27 SQL 步（transactional：runner 单事务整体执行，含 ocr_card_commit 第三次重建 RENAME→CREATE→
    # INSERT SELECT→DROP→索引）= 全新库基线（pragma_table_info 逐表相等）；v_clinical_report 视图两库同文且 UNION 三源正确；
    # clinical_conclusion 三外键恰一非空 CHECK；report_source / appointment.purpose / conclusion_type / treatment_type CHECK 枚举；
    # 成员隔离 FK；回执枚举扩 health_exam/clinical_conclusion；红线 DDL（无 critical/triage/severity_level 编码列，severity_text 只存打印文本）。
    # 无数据回填（doc_type_key 由 App 层首启任务反查三语标签，J4）——幂等只需 IF NOT EXISTS / ADD COLUMN 守卫在全新库重放不炸。
    TABLES_V27 = ["health_exam", "clinical_conclusion", "surgery", "treatment_record", "lab_report", "exam_report",
                  "metric_sample", "appointment", "reminder", "ocr_card_commit", "document_file"]

    def test_v27_upgrades_frozen_v26_baseline_and_extends_receipt_kinds(self):
        fixture = (ROOT / "CoreKit/Tests/CoreKitTests/Fixtures/schema_v26_baseline.sql").read_text()
        text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
        step = re.search(r'Step\(version: 27,.*?sql:\s*"""(.*?)"""', text, re.S)
        self.assertIsNotNone(step, "v27 card-hierarchy 迁移步缺失")
        migration = step.group(1)
        declared = [(transactional, fk_table) for version, _name, _sql, transactional, fk_table in self.steps() if version == 27]
        self.assertEqual(declared, [(True, "ocr_card_commit")], "v27 含表重建，必须步级声明 transactional + fkCheckTable（v25 形态）")
        bigrams = lambda value: " ".join((value or "")[i:i + 2] for i in range(max(0, len(value or "") - 1)))
        with closing(sqlite3.connect(":memory:")) as legacy, closing(sqlite3.connect(":memory:")) as fresh:
            legacy.isolation_level = None   # 自动提交 = GRDB writeWithoutTransaction（PRAGMA foreign_keys 事务内 no-op）
            for db in (legacy, fresh):
                db.create_function("bigrams", 1, bigrams)
                db.execute("PRAGMA foreign_keys = ON")
            fresh.executescript(baseline())
            legacy.executescript(fixture)
            legacy.execute("PRAGMA user_version = 26")
            legacy.executescript("""
                INSERT INTO patient_profile (id,display_name,relation,created_at,updated_at) VALUES ('p','Owner','self',0,0);
                INSERT INTO document_file (id,patient_id,doc_type,sha256,mime_type,origin,created_at,updated_at)
                  VALUES ('d','p','处方单','hash','image/png','import',0,0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg0','d',0,'ok',0);
                INSERT INTO prescription (id,patient_id,document_file_id,source,prescribed_at,confirmed,created_at,updated_at)
                  VALUES ('rx','p','d','ocr',1,1,0,0);
                -- v26 形态回执（entity_table 已存在）——第三次重建搬运必须无损
                INSERT INTO ocr_card_commit VALUES ('c','r','p','d',0,'prescription','prescription','rx',NULL,5);
                INSERT INTO lab_report (id,patient_id,document_file_id,hospital,report_no,collected_at,reported_at,source,confirmed,created_at,updated_at)
                  VALUES ('lr0','p','d','仁济医院','L-1',100,200,'ocr',1,0,0);
                """)
            # runner（GRDBStore.migrateIncremental → applyTransactional）：事务外关闭外键 → 单事务逐语句幂等执行整步 +
            # PRAGMA foreign_key_check(ocr_card_commit) + 版本推进 → （未来步继续）→ 复位外键
            legacy.execute("PRAGMA foreign_keys = OFF")
            self.apply_pending(legacy, 26)
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check(ocr_card_commit)")), [], "fkCheckTable 语义：重建搬运后回执外键无损")
            legacy.execute("PRAGMA foreign_keys = ON")
            for table in self.TABLES_V27:
                self.assertEqual(self.columns(legacy, table), self.columns(fresh, table), f"{table}: 老库逐步升级 ≠ 全新库基线")
            self.assertEqual(legacy.execute("PRAGMA user_version").fetchone()[0], self.latest_version())
            self.assertGreaterEqual(self.latest_version(), 27)
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check")), [])
            self.assertEqual(legacy.execute("SELECT card_id,row_id,card_kind,entity_table,entity_id,encounter_id,created_at FROM ocr_card_commit").fetchall(),
                             [("c", "r", "prescription", "prescription", "rx", None, 5.0)], "回执搬运无损（含 entity_table 原值）")
            self.assertIsNone(legacy.execute("SELECT name FROM sqlite_master WHERE name='ocr_card_commit_v26'").fetchone(), "重建后旧表已 DROP")
            self.assertEqual(legacy.execute("SELECT id,report_source,health_exam_id FROM lab_report").fetchall(), [("lr0", None, None)],
                             "既有表头新列 NULL = v27 前未标注，不回填")
            # 索引：新表索引 + 文档类型索引改稳定键 + 回执四索引重建
            indexes = {r[0] for r in legacy.execute("SELECT name FROM sqlite_master WHERE type='index'")}
            for name in ("idx_health_exam_patient_time", "idx_clinical_conclusion_health_exam", "idx_clinical_conclusion_lab",
                         "idx_clinical_conclusion_exam", "idx_surgery_patient_time", "idx_treatment_patient_time", "idx_document_patient_type",
                         "idx_ocr_card_commit_source", "idx_ocr_card_commit_entity", "idx_ocr_card_commit_encounter", "idx_ocr_card_commit_entity_table"):
                self.assertIn(name, indexes)
            for db in (legacy, fresh):
                self.assertEqual([r[2] for r in db.execute("PRAGMA index_info(idx_document_patient_type)")], ["patient_id", "doc_type_key", "created_at"],
                                 "D3-1：文档类型索引改稳定键（老库重建 = 全新库）")
            # 视图：两库 sqlite_master 同文（去空白）；只读投影不入备份
            view_sql = lambda db: re.sub(r"\s+", "", db.execute("SELECT sql FROM sqlite_master WHERE type='view' AND name='v_clinical_report'").fetchone()[0])
            self.assertEqual(view_sql(legacy), view_sql(fresh), "v_clinical_report 老库与全新库视图定义漂移")
            self.assertEqual(legacy.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='view'").fetchone(), (1,))
            # 幂等纪律：建表/建索引一律 IF NOT EXISTS（表重建只针对 ocr_card_commit）；视图 IF NOT EXISTS；增列恰九条
            creates = [s for s in self.statements(migration) if re.match(r"CREATE (TABLE|INDEX|VIEW)", s)]
            rebuild = [s for s in creates if not s.startswith(("CREATE TABLE IF NOT EXISTS", "CREATE INDEX IF NOT EXISTS", "CREATE VIEW IF NOT EXISTS"))]
            self.assertTrue(rebuild and all("ocr_card_commit" in s for s in rebuild), rebuild)
            self.assertEqual(len(creates) - len(rebuild), 4 + 6 + 1 + 1, "四表 + 六索引 + 文档类型索引 + 视图")
            for statement in creates:
                if statement not in rebuild:
                    fresh.execute(statement)   # 全新库重放不炸
            self.apply_idempotent(fresh, ";".join(s for s in self.statements(migration) if s.startswith("ALTER TABLE") and "ADD COLUMN" in s))
            adds = [s for s in self.statements(migration) if s.startswith("ALTER TABLE") and "ADD COLUMN" in s]
            self.assertEqual(sorted(re.match(r"ALTER TABLE (\w+) ADD COLUMN (\w+)", s).groups() for s in adds),
                             [("appointment", "encounter_id"), ("appointment", "purpose"), ("exam_report", "health_exam_id"), ("exam_report", "report_source"),
                              ("lab_report", "health_exam_id"), ("lab_report", "report_source"), ("metric_sample", "health_exam_id"),
                              ("reminder", "source_id"), ("reminder", "source_table")])
            self.assertEqual(self.columns(legacy, "lab_report"), self.columns(fresh, "lab_report"), "全新库重放增列守卫后列集不变")
            # 红线（BR-004/012）：结论只存打印文本 severity_text，无 critical/triage/severity_level 编码列；体检一般检查为 *_text 原文（BR-006）
            conclusion_columns = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(clinical_conclusion)")}
            self.assertEqual(conclusion_columns["severity_text"], "TEXT")
            for table in ("health_exam", "clinical_conclusion", "surgery", "treatment_record"):
                names = {r[1] for r in legacy.execute(f"PRAGMA table_info({table})")}
                self.assertFalse({c for c in names if "critical" in c or "triage" in c or "urgent" in c or c in ("severity_level", "severity", "report_status")}, (table, names))
            exam_columns = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(health_exam)")}
            for column in ("height_text", "weight_text", "bmi_text", "systolic_text", "diastolic_text", "pulse_text", "waist_text", "vision_left_text", "vision_right_text"):
                self.assertEqual(exam_columns[column], "TEXT", column)
            surgery_columns = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(surgery)")}
            self.assertEqual((surgery_columns["surgery_code_text"], surgery_columns["surgery_level_text"]), ("TEXT", "TEXT"), "编码/级别只存打印文本")
            # reminder.source_* 多态引用无 FK（白名单由 store 校验）；appointment.encounter_id 有 FK
            self.assertEqual({r[2] for r in legacy.execute("PRAGMA foreign_key_list(reminder)")}, {"patient_profile"})
            self.assertEqual({r[2] for r in legacy.execute("PRAGMA foreign_key_list(appointment)")}, {"patient_profile", "encounter"})
            self.assertEqual({r[2] for r in legacy.execute("PRAGMA foreign_key_list(clinical_conclusion)")}, {"patient_profile", "lab_report", "exam_report", "health_exam"})
            self.assertEqual({r[2] for r in legacy.execute("PRAGMA foreign_key_list(treatment_record)")}, {"patient_profile", "encounter", "document_file", "allergy_event"},
                             "drugs_text 原文不拆行——不 FK prescription_line/medication")
            # 约束（前提：外键执法已真实复位开启）
            self.assertEqual(legacy.execute("PRAGMA foreign_keys").fetchone(), (1,), "外键必须已复位开启，否则下列拒绝断言空转")
            legacy.execute("INSERT INTO encounter (id,patient_id,date,kind,created_at,updated_at) VALUES ('e','p',0,'outpatient',0,0)")
            legacy.execute("INSERT INTO health_exam (id,patient_id,document_file_id,org_name,exam_no,exam_date,report_date,weight_text,source,confirmed,created_at,updated_at)"
                           " VALUES ('h','p','d','美年体检','TJ001',1000,NULL,'65.5','ocr',1,0,0)")
            ghosts = [
                "INSERT INTO health_exam (id,patient_id,source,created_at,updated_at) VALUES ('h9','ghost','ocr',0,0)",
                "INSERT INTO clinical_conclusion (id,patient_id,health_exam_id,conclusion_type,content,created_at) VALUES ('c9','ghost','h','lab','x',0)",
                "INSERT INTO surgery (id,patient_id,surgery_name,source,created_at,updated_at) VALUES ('s9','ghost','X','ocr',0,0)",
                "INSERT INTO treatment_record (id,patient_id,treatment_type,source,created_at,updated_at) VALUES ('t9','ghost','infusion','ocr',0,0)",
                # 悬空外键：结论指向不存在的检验表头；预约指向不存在的就诊；检验表头指向不存在的体检
                "INSERT INTO clinical_conclusion (id,patient_id,lab_report_id,conclusion_type,content,created_at) VALUES ('c8','p','missing','lab','x',0)",
                "INSERT INTO appointment (id,patient_id,starts_at,encounter_id,created_at,updated_at) VALUES ('a9','p',0,'missing',0,0)",
                "INSERT INTO lab_report (id,patient_id,health_exam_id,source,created_at,updated_at) VALUES ('lr9','p','missing','ocr',0,0)",
                # CHECK 枚举：source / conclusion_type / treatment_type / report_source / purpose
                "INSERT INTO health_exam (id,patient_id,source,created_at,updated_at) VALUES ('h8','p','bogus',0,0)",
                "INSERT INTO clinical_conclusion (id,patient_id,health_exam_id,conclusion_type,content,created_at) VALUES ('c7','p','h','critical','x',0)",
                "INSERT INTO treatment_record (id,patient_id,treatment_type,source,created_at,updated_at) VALUES ('t8','p','bogus','ocr',0,0)",
                "INSERT INTO lab_report (id,patient_id,report_source,source,created_at,updated_at) VALUES ('lr8','p','bogus','ocr',0,0)",
                "INSERT INTO exam_report (id,patient_id,report_type,report_source,source,created_at,updated_at) VALUES ('x8','p','ct','clinic','ocr',0,0)",
                "INSERT INTO appointment (id,patient_id,starts_at,purpose,created_at,updated_at) VALUES ('a8','p',0,'bogus',0,0)",
                # 三外键恰一非空：全空 / 两个同时非空
                "INSERT INTO clinical_conclusion (id,patient_id,conclusion_type,content,created_at) VALUES ('c6','p','lab','x',0)",
                "INSERT INTO clinical_conclusion (id,patient_id,health_exam_id,lab_report_id,conclusion_type,content,created_at) VALUES ('c5','p','h','lr0','lab','x',0)",
                # 回执枚举外值
                "INSERT INTO ocr_card_commit VALUES ('c','r9','p','d',0,'bogus','health_exam','h',NULL,9)",
                "INSERT INTO ocr_card_commit VALUES ('c','r8','p','d',0,'health_exam','bogus_table','h',NULL,9)",
            ]
            for sql in ghosts:
                with self.assertRaises(sqlite3.IntegrityError, msg=sql):
                    legacy.execute(sql)
            # 合法写入：恰一父的三类结论、手术/治疗、预约挂就诊、提醒回指来源、报告来源与体检外键、回执新枚举
            legacy.execute("INSERT INTO clinical_conclusion (id,patient_id,health_exam_id,conclusion_type,content,severity_text,ordinal,created_at)"
                           " VALUES ('c1','p','h','health_exam_summary','血脂偏高','关注',0,0)")
            legacy.execute("INSERT INTO clinical_conclusion (id,patient_id,lab_report_id,conclusion_type,content,ordinal,created_at) VALUES ('c2','p','lr0','lab','未见异常',0,0)")
            legacy.execute("INSERT INTO exam_report (id,patient_id,encounter_id,report_type,report_source,hospital,report_no,exam_at,source,confirmed,created_at,updated_at)"
                           " VALUES ('x1','p','e','ct','outpatient','市一院','CT-7',300,'ocr',1,0,0)")
            legacy.execute("INSERT INTO clinical_conclusion (id,patient_id,exam_report_id,conclusion_type,content,ordinal,created_at) VALUES ('c3','p','x1','exam','肝囊肿',0,0)")
            legacy.execute("INSERT INTO lab_report (id,patient_id,health_exam_id,hospital,collected_at,source,confirmed,created_at,updated_at)"
                           " VALUES ('lr1','p','h','美年体检',1000,'ocr',1,0,0)")
            legacy.execute("INSERT INTO metric_sample (id,patient_id,metric_key,value,unit,origin,self_measured,measured_at,created_at,health_exam_id)"
                           " VALUES ('m1','p','weight',65.5,'kg','hospital',0,1000,0,'h')")
            legacy.execute("INSERT INTO surgery (id,patient_id,encounter_id,surgery_at,surgery_name,surgery_level_text,implants_text,source,confirmed,created_at,updated_at)"
                           " VALUES ('s1','p','e',400,'腹腔镜胆囊切除术','三级','钛夹×3','ocr',1,0,0)")
            legacy.execute("INSERT INTO treatment_record (id,patient_id,encounter_id,treatment_type,treated_at,drugs_text,source,confirmed,created_at,updated_at)"
                           " VALUES ('t1','p','e','infusion',500,'0.9% 氯化钠 250ml + 头孢曲松 2g','ocr',1,0,0)")
            legacy.execute("INSERT INTO appointment (id,patient_id,starts_at,encounter_id,purpose,created_at,updated_at) VALUES ('a1','p',900,'e','followUp',0,0)")
            legacy.execute("INSERT INTO appointment (id,patient_id,starts_at,created_at,updated_at) VALUES ('a2','p',901,0,0)")
            legacy.execute("INSERT INTO reminder (id,patient_id,kind,title,at_date,source_table,source_id,created_at,updated_at) VALUES ('rm1','p','followUp','复诊',900,'encounter','e',0,0)")
            for card_kind, entity_table, entity_id in (("health_exam", "health_exam", "h"), ("clinical_conclusion", "clinical_conclusion", "c1"),
                                                        ("surgery", "surgery", "s1"), ("treatment_record", "treatment_record", "t1")):
                legacy.execute("INSERT INTO ocr_card_commit VALUES (?,?,?,?,?,?,?,?,?,?)", (f"c-{card_kind}", "r0", "p", "d", 0, card_kind, entity_table, entity_id, None, 0))
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check")), [])
            # 视图 UNION 三源：report_source 缺失时按体检外键推断呈现（不回写）；report_date = COALESCE(采集/检查, 报告)；体检行 health_exam_id = 自身 id
            rows = legacy.execute("SELECT report_id,patient_id,report_type,report_source,report_date,org_name,report_no,encounter_id,health_exam_id,document_file_id,confirmed"
                                  " FROM v_clinical_report ORDER BY report_type, report_id").fetchall()
            self.assertEqual(rows, [
                ("x1", "p", "exam", "outpatient", 300.0, "市一院", "CT-7", "e", None, None, 1),
                ("h", "p", "health_exam", "health_exam", 1000.0, "美年体检", "TJ001", None, "h", "d", 1),
                ("lr0", "p", "lab", None, 100.0, "仁济医院", "L-1", None, None, "d", 1),
                ("lr1", "p", "lab", "health_exam", 1000.0, "美年体检", None, None, "h", None, 1),
            ])
            self.assertEqual(legacy.execute("SELECT report_source FROM lab_report WHERE id='lr1'").fetchone(), (None,), "视图推断不回写物理列")
            self.assertEqual(legacy.execute("SELECT id FROM clinical_conclusion WHERE health_exam_id='h' ORDER BY ordinal").fetchall(), [("c1",)])
            self.assertEqual(legacy.execute("SELECT severity_text FROM clinical_conclusion WHERE id='c1'").fetchone(), ("关注",), "severity_text 打印文本原样")


if __name__ == "__main__":
    unittest.main()
