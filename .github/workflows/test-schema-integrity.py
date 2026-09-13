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
            # runner（GRDBStore.migrateIncremental）：事务外关闭外键 → default 路径逐语句幂等执行 → 版本推进 → 复位外键
            legacy.execute("PRAGMA foreign_keys = OFF")
            self.apply_idempotent(legacy, migration)
            legacy.execute("PRAGMA user_version = 26")
            legacy.execute("PRAGMA foreign_keys = ON")
            for table in self.TABLES_V26:
                self.assertEqual(self.columns(legacy, table), self.columns(fresh, table), f"{table}: 老库逐步升级 ≠ 全新库基线")
            self.assertEqual(legacy.execute("PRAGMA user_version").fetchone()[0], 26)
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


if __name__ == "__main__":
    unittest.main()
