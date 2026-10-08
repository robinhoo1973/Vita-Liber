"""派生值域负测(2026-10-08 数据批;H3 D 席 + round2 X 席复核)。

覆盖:load_derived_pools 读取/去重口径、_card_value 优先目录派生值(疫苗/术式/收费)、
常量兜底路径、生产 data-dir(training_feed_manifest.json 在场)派生缺失时 fail-closed。
"""
import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
BUILDER = DISTILL / "extract" / "build_extraction_corpus.py"
sys.path.insert(0, str(DISTILL / "extract"))


class DerivedPoolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "ref").mkdir()
        (self.tmp / "ref" / "vaccine_cn.jsonl").write_text(
            json.dumps({"name_zh": "流感病毒裂解疫苗"}, ensure_ascii=False) + "\n" +
            json.dumps({"name_zh": "带状疱疹疫苗"}, ensure_ascii=False) + "\n", encoding="utf-8")
        (self.tmp / "ref" / "vaccine_tw.jsonl").write_text(
            json.dumps({"name_zh": "肺炎鏈球菌疫苗"}, ensure_ascii=False) + "\n", encoding="utf-8")
        (self.tmp / "ref" / "procedure_tw.jsonl").write_text(
            json.dumps({"name_zh": "腹腔鏡膽囊切除術", "category": "", "price_ref": "12345"},
                       ensure_ascii=False) + "\n", encoding="utf-8")
        (self.tmp / "ref" / "fee_tw.jsonl").write_text(
            json.dumps({"name_zh": "一般門診診察費", "price_ref": "286"}, ensure_ascii=False) + "\n",
            encoding="utf-8")

    def test_load_counts_and_regions(self):
        from build_extraction_corpus import load_derived_pools
        out = load_derived_pools(str(self.tmp), ["cn", "tw", "hk"], random.Random(1))
        self.assertEqual(len(out["vaccines"]["CN"]), 2)
        self.assertEqual(out["vaccines"]["TW"], ["肺炎鏈球菌疫苗"])
        self.assertNotIn("HK", out["vaccines"])
        self.assertEqual(out["procedures"][0]["price"], "12345")
        self.assertEqual(out["fees"][0]["name"], "一般門診診察費")

    def test_card_value_prefers_derived(self):
        from build_extraction_corpus import _card_value, load_derived_pools
        derived = load_derived_pools(str(self.tmp), ["cn", "tw"], random.Random(1))
        pools = {"derived": derived}
        rng = random.Random(2)
        self.assertIn(_card_value("vaccine_name", {}, pools, rng, "TW"), ["肺炎鏈球菌疫苗"])
        self.assertIn(_card_value("vaccine_name", {}, pools, rng, "CN"),
                      ["流感病毒裂解疫苗", "带状疱疹疫苗"])
        self.assertEqual(_card_value("surgery_name", {}, pools, rng, "TW"), "腹腔鏡膽囊切除術")
        self.assertEqual(_card_value("item_name", {}, pools, rng, "TW"), "一般門診診察費")

    def test_card_value_falls_back_without_derived(self):
        from build_extraction_corpus import _card_value
        pools = {"derived": {"vaccines": {}, "procedures": [], "fees": []}}
        rng = random.Random(3)
        # CN 无派生 → 常量兜底(旧 VACCINES 表内);TW 术式无派生 → 常量繁化
        self.assertIn(_card_value("vaccine_name", {}, pools, rng, "CN"),
                      ["乙肝疫苗", "流感疫苗", "肺炎球菌疫苗", "麻腮风疫苗", "水痘疫苗",
                       "HPV疫苗", "新冠疫苗", "带状疱疹疫苗", "百白破疫苗"])
        self.assertTrue(_card_value("surgery_name", {}, pools, rng, "TW"))

    def test_production_dir_missing_derived_fails_closed(self):
        # training_feed_manifest.json 在场=生产 data-dir;疫苗派生缺失 → builder 拒产出(rc=2)
        data = Path(tempfile.mkdtemp())
        (data / "drugs_cn.jsonl").write_text(
            json.dumps({"name_zh": "测试药品片", "specification": "100mg", "dosage_form": "片剂",
                        "usage_text": "口服"}, ensure_ascii=False) + "\n", encoding="utf-8")
        (data / "medical_index.json").write_text(json.dumps({"index": {}}, ensure_ascii=False),
                                                 encoding="utf-8")
        (data / "training_feed_manifest.json").write_text("{}", encoding="utf-8")
        prompts = Path(tempfile.mkdtemp())
        (prompts / "prompt_prescription.txt").write_text("x", encoding="utf-8")
        (prompts / "spec_prescription.json").write_text(json.dumps(
            {"shared": [{"key": "hospital"}], "row": [], "rowAnchor": "", "maxRowsPerRegion": 0},
            ensure_ascii=False), encoding="utf-8")
        r = subprocess.run([sys.executable, str(BUILDER), "--data-dir", str(data),
                            "--prompts-dir", str(prompts), "--out-dir", str(data / "out"),
                            "--cells", "drugs/cn", "--dry-run", "--seed", "7"],
                           capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 2, msg=r.stdout[-800:])
        self.assertIn("派生域缺失", r.stdout)

    def test_cn_import_slots_preferred(self):
        # CN 官方件导入槽(procedure_cn/fee_cn):文件在场时 provider 优先导入值
        (self.tmp / "ref" / "procedure_cn.jsonl").write_text(
            json.dumps({"name_zh": "腹腔镜胆囊切除术", "price_ref": ""}, ensure_ascii=False) + "\n",
            encoding="utf-8")
        (self.tmp / "ref" / "fee_cn.jsonl").write_text(
            json.dumps({"name_zh": "门诊诊察费", "price_ref": ""}, ensure_ascii=False) + "\n",
            encoding="utf-8")
        from build_extraction_corpus import _card_value, load_derived_pools
        pools = {"derived": load_derived_pools(str(self.tmp), ["cn"], random.Random(1))}
        rng = random.Random(2)
        self.assertEqual(_card_value("surgery_name", {}, pools, rng, "CN"), "腹腔镜胆囊切除术")
        self.assertEqual(_card_value("item_name", {}, pools, rng, "CN"), "门诊诊察费")
        # 无导入文件时 CN 常量兜底(回归)
        pools2 = {"derived": {"vaccines": {}, "procedures": [], "fees": [],
                              "procedures_cn": [], "fees_cn": []}}
        self.assertTrue(_card_value("surgery_name", {}, pools2, rng, "CN"))


if __name__ == "__main__":
    unittest.main()
