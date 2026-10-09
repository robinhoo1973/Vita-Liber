"""extract.build_extraction_corpus:端口构建器在 CI 数据面上的端到端冒烟(逐字契约)。

含 C 批(2026-10-09 W20)正确性族:manifest 确定性(无墙钟)/eval 计数自洽/
样本缺口 fail-closed/TW usage 解析控制流/两侧正本修复函数同步。
"""
import ast
import hashlib
import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
BUILDER = DISTILL / "extract" / "build_extraction_corpus.py"

SPECS = {
    "prescription": {
        "shared": [dict(key="hospital"), dict(key="department"), dict(key="doctor"),
                   dict(key="prescribed_at", required=True), dict(key="prescription_no"),
                   dict(key="clinical_diagnosis"), dict(key="advice_text")],
        "row": [dict(key="drug_name", required=True), dict(key="spec"), dict(key="quantity"),
                dict(key="dosage"), dict(key="frequency"), dict(key="route"), dict(key="days")],
        "rowAnchor": "1.", "maxRowsPerRegion": 8,
    },
    "medication": {
        "shared": [],
        "row": [dict(key="generic_name", required=True), dict(key="brand_name"),
                dict(key="spec"), dict(key="unit_kind", required=True)],
        "rowAnchor": "", "maxRowsPerRegion": 4,
    },
    "encounter": {
        "shared": [dict(key="date", required=True), dict(key="hospital"), dict(key="department"),
                   dict(key="doctor"), dict(key="chief_complaint"), dict(key="diagnosis_text"),
                   dict(key="advice_text")],
        "row": [], "rowAnchor": "", "maxRowsPerRegion": 4,
    },
    "metric_sample": {
        "shared": [dict(key="measured_at", required=True), dict(key="hospital"), dict(key="specimen_type")],
        "row": [dict(key="raw_label", required=True), dict(key="value", required=True),
                dict(key="unit"), dict(key="reference_range"), dict(key="abnormal_flag")],
        "rowAnchor": "", "maxRowsPerRegion": 4,
    },
    # 通用卡种覆盖（gen_generic_card 路径；labels/枚举词形/fallback 打印词形随 spec 流入）
    "hospitalization": {
        "shared": [dict(key="hospital", required=True, labels=["医院", "醫院"]),
                   dict(key="admit_at", labels=["入院日期"]),
                   dict(key="actual_days", type="number", integer=True, labels=["实际住院天数"]),
                   dict(key="bed_no", labels=["床号"]),
                   dict(key="discharge_orders", type="narrative", labels=["出院医嘱"])],
        "row": [], "rowAnchor": "", "maxRowsPerRegion": 0,
    },
    "claim_item": {
        "shared": [dict(key="date", required=True, labels=["开票日期"]),
                   dict(key="amount", type="number", integer=False, labels=["合计"]),
                   dict(key="item_type", type="enumerated", domain=["invoice", "fee", "receipt"],
                        fallback_tokens=["发票", "收費單", "收据"], labels=["票据类型"])],
        "row": [dict(key="item_name", required=True, labels=["项目"]),
                dict(key="item_amount", type="number", integer=False, labels=["金额"]),
                dict(key="item_quantity", labels=["数量"])],
        "rowAnchor": "item_name", "maxRowsPerRegion": 6,
    },
}


def _write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")


def _make_data_dir(tmp: Path) -> Path:
    data = tmp / "data"
    drugs = [{"name_zh": f"测试药品{i}片", "specification": "100mg", "dosage_form": "片剂",
              "usage_text": "口服。一次1片,一日2次"} for i in range(6)]
    _write_jsonl(data / "drugs_cn.jsonl", drugs)
    _write_jsonl(data / "drugs_nhsa.jsonl",
                 [{"name_zh": f"医保药品{i}胶囊", "region_specific": {"spec": "", "dosage_form": "胶囊剂"}}
                  for i in range(6)])
    _write_jsonl(data / "tw_records.jsonl",
                 [{"name_zh": f"臺灣藥品{i}錠", "specification": "500毫克", "dosage_form": "錠劑",
                   "usage_text": "口服。一次1錠,一日3次", "source_id": f"TW-{i}"} for i in range(4)])
    _write_jsonl(data / "hk_records.jsonl",
                 [{"name_zh": "", "name_en": f"HONGKONG TABLET {i}", "specification": "500mg",
                   "dosage_form": "Tablet", "usage_text": "Take one tablet daily"} for i in range(4)])
    _write_jsonl(data / "medical_details.jsonl",
                 [{"source_id": f"TW-{i}", "usage_text": "口服。一次1錠,一日3次",
                   "indications": f"用于測試疾症{i}、高血壓治療"} for i in range(4)])
    (data / "medical_index.json").write_text(
        json.dumps({"index": {"測試藥": ["CN-1"], "医保药品0": ["NHSA-1"]}}, ensure_ascii=False), encoding="utf-8")
    _write_jsonl(data / "ref" / "hospital_cn.jsonl",
                 [{"name_zh": f"测试市第{i}人民医院"} for i in range(6)])
    _write_jsonl(data / "ref" / "department_cn.jsonl", [{"name_zh": "心内科"}, {"name_zh": "呼吸内科"}])
    _write_jsonl(data / "ref" / "diagnosis_cn.jsonl",
                 [{"name_zh": "高血压"}, {"name_zh": "2型糖尿病"}, {"name_zh": "咳嗽"}])
    _write_jsonl(data / "ref" / "exam_cn.jsonl", [{"name_zh": "血常规", "unit": ""}])
    return data


def _make_prompts_dir(tmp: Path) -> Path:
    prompts = tmp / "prompts"
    prompts.mkdir(parents=True, exist_ok=True)
    for kind, spec in SPECS.items():
        (prompts / f"prompt_{kind}.txt").write_text(
            f"Extract fields from a document ({kind}). Every value MUST be a verbatim substring of the line.",
            encoding="utf-8")
        (prompts / f"spec_{kind}.json").write_text(json.dumps(spec, ensure_ascii=False), encoding="utf-8")
    return prompts


class BuilderSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.data = _make_data_dir(cls.tmp)
        cls.prompts = _make_prompts_dir(cls.tmp)
        cls.out = cls.tmp / "out"
        result = subprocess.run(
            [sys.executable, str(BUILDER), "--data-dir", str(cls.data), "--prompts-dir", str(cls.prompts),
             "--out-dir", str(cls.out), "--cells", "drugs/cn,hospitals/cn,diagnoses/cn,exams/cn",
             "--dry-run", "--seed", "7"],
            capture_output=True, text=True, timeout=300)
        cls.stdout, cls.stderr, cls.rc = result.stdout, result.stderr, result.returncode

    def test_exit_zero(self):
        self.assertEqual(self.rc, 0, msg=f"stdout={self.stdout[-2000:]}\nstderr={self.stderr[-2000:]}")

    def test_outputs_and_verbatim(self):
        sft = self.out / "extraction_sft.jsonl"
        rows = [json.loads(l) for l in sft.read_text(encoding="utf-8").splitlines() if l.strip()]
        self.assertGreater(len(rows), 0)
        for record in rows:
            messages = record["conversations"]
            self.assertEqual([m["role"] for m in messages], ["system", "user", "assistant"])
            assistant = json.loads(messages[2]["content"])
            lines = [l.split("] ", 1)[1] for l in messages[1]["content"].split("\n")]
            for span in assistant["shared"] + [s for row in assistant["rows"] for s in row]:
                self.assertIn(span["value"], lines[span["lineIndex"]],
                              msg=f"verbatim 违约: {span}")
        self.assertTrue((self.out / "extraction_pretrain.jsonl").exists())
        self.assertTrue((self.out / "extraction_eval.jsonl").exists())

    def test_manifest_written_with_feed_provenance(self):
        manifest = json.loads((self.out / "extraction_manifest.json").read_text(encoding="utf-8"))
        self.assertIn("files", manifest)
        self.assertTrue(manifest["files"]["extraction_sft.jsonl"]["sha256"])

    def test_manifest_licenses_top_level_not_in_noise(self):
        # round2 E:licenses 必须顶层(曾误埋 noise 块内);且逐源义务来自 policy 单源
        manifest = json.loads((self.out / "extraction_manifest.json").read_text(encoding="utf-8"))
        self.assertIn("licenses", manifest)
        self.assertNotIn("licenses", manifest.get("noise", {}))
        self.assertIn("TFDA", manifest["licenses"])
        self.assertIn("PyCorrector", manifest["licenses"])
        self.assertTrue(manifest["licenses"]["TFDA"]["attribution"])

    def test_line_ops_trigger_surface_nonzero(self):
        # round2 X 席:行噪声曾全卡种触发率 0(所有行带 span)——诱饵行补齐后
        # 集成断言触发面必须 >0(seed=7 确定性)
        manifest = json.loads((self.out / "extraction_manifest.json").read_text(encoding="utf-8"))
        ops = manifest["stats"].get("line_ops") or {}
        self.assertGreater(sum(ops.values()), 0, f"行噪声触发面为 0: {ops}")

    def test_sft_never_contains_holdout_values(self):
        # 值级 holdout(round2 X2):SFT 侧样本不得携带 value_holdout 标记
        sft = self.out / "extraction_sft.jsonl"
        rows = [json.loads(l) for l in sft.read_text(encoding="utf-8").splitlines() if l.strip()]
        self.assertEqual(sum(1 for r in rows if r.get("value_holdout")), 0)


def _find_training_builder():
    """逐级上溯找训练机正本(CI 检出无 refactor/ → None,调用方 skip)。"""
    for base in Path(__file__).resolve().parents:
        candidate = (base / "refactor" / "tools" / "training" / "template"
                     / "scripts" / "corpus" / "build_extraction_corpus.py")
        if candidate.is_file():
            return candidate
    return None


def _function_source(path: Path, name: str) -> str:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return ast.unparse(node)
    raise AssertionError(f"{path}: 缺函数 {name}")


class BuilderCorrectnessTests(unittest.TestCase):
    """C 批负测(2026-10-09 W20):review 实证五条里的确定性/计数/缺口/控制流。"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.data = _make_data_dir(cls.tmp)
        cls.prompts = _make_prompts_dir(cls.tmp)

    def _build(self, out, *extra, cells="drugs/cn,hospitals/cn,diagnoses/cn,exams/cn"):
        return subprocess.run(
            [sys.executable, str(BUILDER), "--data-dir", str(self.data),
             "--prompts-dir", str(self.prompts), "--out-dir", str(out),
             "--cells", cells, "--seed", "7", *extra],
            capture_output=True, text=True, timeout=300)

    def test_manifest_bytes_reproducible_across_builds(self):
        # C2:同输入两次构建 manifest 必须逐字节相等(墙钟剔除;冻结资产名=内容 sha)
        a, b = self.tmp / "repro-a", self.tmp / "repro-b"
        ra, rb = self._build(a, "--dry-run"), self._build(b, "--dry-run")
        self.assertEqual(ra.returncode, 0, msg=ra.stdout[-800:])
        self.assertEqual(rb.returncode, 0, msg=rb.stdout[-800:])
        ma = (a / "extraction_manifest.json").read_bytes()
        mb = (b / "extraction_manifest.json").read_bytes()
        self.assertEqual(hashlib.sha256(ma).hexdigest(), hashlib.sha256(mb).hexdigest(),
                         "manifest 非输入纯函数(疑似墙钟字段回归)")
        self.assertNotIn(b"generatedAt", ma)
        for name in ("extraction_sft.jsonl", "extraction_eval.jsonl", "extraction_pretrain.jsonl"):
            self.assertEqual((a / name).read_bytes(), (b / name).read_bytes(), name)

    def test_manifest_eval_claims_equal_eval_rows(self):
        # C1:manifest 声称的 eval 数(=闸的判据)必须=实落行数(曾 N² 放大,声称 937/实落 831)
        out = self.tmp / "claims"
        r = self._build(out, "--dry-run")
        self.assertEqual(r.returncode, 0, msg=r.stdout[-800:])
        manifest = json.loads((out / "extraction_manifest.json").read_text(encoding="utf-8"))
        claims = manifest["stats"]["eval_cells"]
        kind_claims = {k: v for k, v in claims.items() if k.startswith("kind:")}
        rows = [json.loads(l) for l in
                (out / "extraction_eval.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
        self.assertEqual(sum(v["eval"] for v in kind_claims.values()), len(rows),
                         f"总声称与实落不符: {kind_claims}")
        by_kind = {}
        for row in rows:
            kind = row["id"].split("-")[1]
            by_kind[kind] = by_kind.get(kind, 0) + 1
        for cell, v in sorted(kind_claims.items()):
            self.assertEqual(v["eval"], by_kind.get(cell[len("kind:"):], 0), cell)

    def test_gap_gate_nonzero_with_named_error_and_exempt(self):
        # C3:请求数做不满(review 实证 prescription 0/34 全被预算丢)→ rc 非零 + 具名报错;
        # --allow-incomplete-kinds 显式豁免(仍登记);dry-run 冒烟豁免。
        starved = self._build(self.tmp / "gap", "--kinds", "prescription,medication",
                              "--sft-count", "20", "--budget", "1")
        self.assertEqual(starved.returncode, 1, msg=starved.stdout[-800:])
        self.assertIn("[缺口] prescription:", starved.stdout)
        self.assertIn("构建失败(样本缺口)", starved.stdout)
        manifest = json.loads((self.tmp / "gap" / "extraction_manifest.json").read_text(encoding="utf-8"))
        self.assertTrue(manifest["stats"]["incomplete_kinds"])
        exempt = self._build(self.tmp / "gap-ok", "--kinds", "prescription,medication",
                             "--sft-count", "20", "--budget", "1", "--allow-incomplete-kinds")
        self.assertEqual(exempt.returncode, 0, msg=exempt.stdout[-800:])
        self.assertIn("样本缺口已豁免", exempt.stdout)

    def test_tw_usage_joined_on_disease_sampled_lines(self):
        # C4:疾病词表抽样行(i % 25 == 0)不得吞掉 TW 用法解析(曾 if/elif 短路,约 4% 行丢字段)
        sys.path.insert(0, str(DISTILL / "extract"))
        import build_extraction_corpus as builder  # noqa: E402
        data = self.tmp / "details"
        data.mkdir(exist_ok=True)
        rows = []
        for i in range(60):
            rows.append({"source_id": f"TW-{i}",
                         "usage_text": f"口服。一次{i + 1}錠,一日3次" if i in (0, 25, 50) else "",
                         "indications": "用于治疗高血压" if i in (0, 25, 50) else ""})
        (data / "medical_details.jsonl").write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
        tw_ids = {"TW-0", "TW-25", "TW-50"}
        diseases = set()
        usage = builder.load_details(str(data), tw_ids, diseases, random.Random(1))
        self.assertEqual(set(usage), tw_ids, "命中疾病抽样行(i%25==0)的 TW 用法被短路吞掉")
        self.assertIn("TW-0", usage)
        self.assertIn("高血压", diseases, "同行的疾病词表抽取不得因独立化而丢失")

    def test_gap_gate_disabled_for_dry_run(self):
        # dry-run=冒烟(总量 60,预算丢弃属预期):缺口只登记不拒
        r = self._build(self.tmp / "drygap", "--dry-run", "--kinds", "prescription",
                        "--budget", "1")
        self.assertEqual(r.returncode, 0, msg=r.stdout[-800:])


def _find_training_exporter():
    for base in Path(__file__).resolve().parents:
        candidate = (base / "refactor" / "tools" / "training" / "tools"
                     / "export-prompts" / "main.swift")
        if candidate.is_file():
            return candidate
    return None


def _find_training_artifacts():
    for base in Path(__file__).resolve().parents:
        candidate = (base / "refactor" / "tools" / "training" / "template"
                     / "configs" / "extraction_prompts")
        if candidate.is_dir():
            return candidate
    return None


@unittest.skipUnless(_find_training_exporter(), "本地训练树不在工作区——跨侧断言跳过")
class PromptExporterTwinTests(unittest.TestCase):
    """A 批(2026-10-09 W20):导出器源码与产物两侧逐字节同源 + 产物确定性形态。

    产物=语料构建输入 ⇒ manifest 不得含墙钟/路径(同输入两次导出 sha 必等;
    两侧 wrapper 各自编译同一份 main.swift 源码逐字节相同)。
    """

    def test_main_swift_twins_byte_identical(self):
        local = _find_training_exporter()
        ci = DISTILL / "extract" / "export_extraction_prompts" / "main.swift"
        self.assertEqual(ci.read_bytes(), local.read_bytes(),
                         "导出器 main.swift 两侧分叉——先同步两处(A 批同源纪律)")

    def test_committed_artifacts_deterministic_shape(self):
        artifacts = _find_training_artifacts()
        manifest = json.loads((artifacts / "manifest.json").read_text(encoding="utf-8"))
        self.assertNotIn("generatedAt", manifest, "提示词 manifest 含墙钟(A 批可复现性回归)")
        self.assertEqual(manifest["generator"], "extraction-prompts-exporter",
                         "generator 必须路径无关(两侧产物逐字节相等的前提)")
        kinds = [entry["kind"] for entry in manifest["kinds"]]
        self.assertEqual(len(kinds), len(set(kinds)))
        for kind in kinds:
            self.assertTrue((artifacts / f"prompt_{kind}.txt").is_file(), kind)
            spec = json.loads((artifacts / f"spec_{kind}.json").read_text(encoding="utf-8"))
            fields = list(spec.get("shared") or []) + list(spec.get("row") or [])
            self.assertTrue(fields, f"{kind}: spec 无字段")
            for field in fields:
                # A 批漂移面:旧产物(2026-09-24)缺 labels/fallback_tokens/value_tokens
                self.assertTrue(field.get("labels"), f"{kind}.{field.get('key')}: spec 缺 labels")


@unittest.skipUnless(_find_training_builder(), "本地训练树不在工作区(CI 检出无 refactor/)——跨侧断言跳过")
class BuilderTwinSyncTests(unittest.TestCase):
    """C 批修复函数两侧同步:build_extraction_corpus 整体尚存历史分叉(见报告),
    但本批修改的四个语义单元必须两侧逐字同源(先断言这四处,不假绿整体)。"""

    LOCAL = _find_training_builder()

    def test_c_fix_functions_identical(self):
        for name in ("assign_eval_splits", "load_details"):
            self.assertEqual(_function_source(BUILDER, name),
                             _function_source(self.LOCAL, name),
                             f"{name} 两侧分叉——先同步两处(C 批修复必须双侧同源)")

    def test_gap_gate_and_determinism_markers_present_both_sides(self):
        for path in (BUILDER, self.LOCAL):
            src = path.read_text(encoding="utf-8")
            for marker in ("--min-kind-fill", "--allow-incomplete-kinds",
                           "incomplete_kinds", "eval 计数不自洽"):
                self.assertIn(marker, src, f"{path.name} 缺 C 批标记 {marker}")
            self.assertNotIn('"generatedAt":', src, f"{path.name} 仍有墙钟字段(C2 回归)")


if __name__ == "__main__":
    unittest.main()
