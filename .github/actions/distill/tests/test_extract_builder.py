"""extract.build_extraction_corpus:端口构建器在 CI 数据面上的端到端冒烟(逐字契约)。"""
import json
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


if __name__ == "__main__":
    unittest.main()
