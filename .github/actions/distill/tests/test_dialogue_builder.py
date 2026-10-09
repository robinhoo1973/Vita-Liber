"""dialogue 语料:接地校验、四态覆盖、负清单 fail-closed、安全词表同源 + 清单确定性(W21 C 批)。"""
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

from dialogue import builder as dialogue_builder
from dialogue.grounding import GroundingError, check_grounding, residual_of
from dialogue.safety_lexicon import load_safety_lexicon

# 仓根锚点逐级上溯（禁止固定层级 parents[N]——四文件化布局下会解析错位,见 workflows/README.md 分簇规则）
REPO_ROOT = Path(__file__).resolve().parent
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent


def _write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")


def _make_catalog_dir(tmp: Path) -> Path:
    facts = tmp / "facts"
    _write_jsonl(facts / "drug.jsonl", [
        {"region": "CN", "name": "阿司匹林肠溶片", "spec": "100mg", "form": "肠溶片",
         "usage": "口服。成人一次1片，一日1次"},
        {"region": "CN", "name": "阿司匹林泡腾片", "spec": "500mg", "form": "泡腾片",
         "usage": "口服。一次1片"},
        {"region": "CN", "name": "阿司匹林片", "form": "片剂"},
        {"region": "CN", "name": "布洛芬缓释胶囊", "spec": "300mg", "form": "胶囊",
         "usage": "口服。一次1粒，一日2次"},
    ])
    _write_jsonl(facts / "hospital.jsonl", [
        {"region": "CN", "name": "测试市人民医院", "type": "综合医院", "level": "三级甲等", "area": "测试市"},
        {"region": "TW", "name": "臺大醫院", "type": "綜合醫院"},
    ])
    _write_jsonl(facts / "department.jsonl", [{"region": "CN", "name": "心内科", "category": "内科"}])
    _write_jsonl(facts / "diagnosis.jsonl", [
        {"region": "CN", "name": "高血压", "chapter": "循环系统疾病"},
        {"region": "CN", "name": "2型糖尿病", "chapter": "内分泌营养和代谢疾病"},
    ])
    _write_jsonl(facts / "exam.jsonl", [{"region": "CN", "name": "血常规", "category": "检验"}])
    return tmp


def _fake_wording_source(tmp: Path, needle: str | None = None) -> Path:
    patterns = [("可能是(.+?)病", "疾病名推断"), ("因为(.+?)所以", "因果句式"), ("建议服用", "治疗建议"),
                ("应该吃药", "治疗建议"), ("确诊", "诊断表述"), ("治疗(.+?)即可", "治疗建议"),
                ("(?:请|建议)(?:你|您)?(?:停用|停药|调药)", "处置建议"), ("由于(.+?)(?:导致|引起)", "因果表述")]
    if needle:
        patterns.append((needle, "注入违禁"))
    lines = ["public enum WordingBlacklist {", "    static let patterns: [(String, String)] = ["]
    for pattern, label in patterns:
        lines.append(f'        ("{pattern}", "{label}"),')
    lines += ["    ]", "}"]
    path = tmp / "FakeAlertEngine.swift"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


class GroundingUnitTests(unittest.TestCase):
    def test_residual_and_violation(self):
        self.assertEqual(residual_of("资料里记录的用法是「口服」。", ["口服"]), "资料里记录的用法是「」。")
        with self.assertRaises(GroundingError):
            residual_of("资料里记录的用法是「口服」。", ["不存在"])
        with self.assertRaises(GroundingError):
            check_grounding("资料里记录的用法是「口服」，建议停药。", ["口服"], ["用法:口服"])
        with self.assertRaises(GroundingError):
            check_grounding("资料里记录的用法是「口服」。", ["静脉"], ["用法:口服"])
        check_grounding("资料里记录的用法是「口服」。", ["口服"], ["用法:口服"])


class SafetyLexiconTests(unittest.TestCase):
    def test_real_source_parses(self):
        lexicon = load_safety_lexicon(REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AILocal.swift")
        self.assertIn("胸痛", lexicon["emergency"])
        self.assertIn("停药", lexicon["high_risk"])
        self.assertGreaterEqual(len(lexicon["emergency"]), 12)


class DialogueBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.catalog = _make_catalog_dir(cls.tmp)
        cls.out = cls.tmp / "out"
        cls.manifest = dialogue_builder.build(
            cls.catalog, cls.out, count=150, eval_ratio=0.1, seed=11,
            wording_source=_fake_wording_source(cls.tmp),
            safety_source=REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AILocal.swift")

    def _rows(self):
        path = self.out / "dialogue_sft.jsonl"
        return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]

    def test_modes_covered(self):
        counts = self.manifest["stats"]["counts"]
        for mode in ("restate", "clarify", "refuse_high", "refuse_insufficient", "emergency"):
            self.assertGreater(counts.get(mode, 0), 0, msg=f"模式缺失: {mode} counts={counts}")

    def test_all_grounded_and_structured(self):
        for record in self._rows():
            for message in record["conversations"]:
                if message["role"] != "assistant":
                    continue
                payload = json.loads(message["content"])
                self.assertIn(payload["mode"], ("restate", "clarify", "refuse", "emergency"))
                if payload["mode"] in ("restate", "clarify"):
                    self.assertTrue(payload["fragments"])
                    self.assertTrue(payload["citations"])
                if payload["mode"] == "refuse":
                    self.assertIn(payload["refusal"], ("high_risk", "insufficient"))

    def test_multi_turn_present(self):
        multi = [r for r in self._rows() if sum(1 for m in r["conversations"] if m["role"] == "user") > 1]
        self.assertGreater(len(multi), 0)

    def test_manifest_frozen(self):
        manifest = json.loads((self.out / "dialogue_manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["safety_lexicon"]["emergency"], 21)  # 词表同源计数快照(漂移即红)
        self.assertTrue(manifest["files"]["dialogue_sft.jsonl"]["sha256"])

    def test_manifest_deterministic_across_builds(self):
        # W21 C 批负测:同输入两次构建 manifest 逐字节相等(墙钟剔除;冻结资产名=内容 sha)。
        # 曾带 generatedAt 墙钟 → 同输入不同 sha(与 extraction/提示词 manifest 同族回归)。
        a, b = self.tmp / "det-a", self.tmp / "det-b"
        dialogue_builder.build(
            self.catalog, a, count=60, eval_ratio=0.1, seed=23,
            wording_source=_fake_wording_source(self.tmp),
            safety_source=REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AILocal.swift")
        dialogue_builder.build(
            self.catalog, b, count=60, eval_ratio=0.1, seed=23,
            wording_source=_fake_wording_source(self.tmp),
            safety_source=REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AILocal.swift")
        ma, mb = (a / "dialogue_manifest.json").read_bytes(), (b / "dialogue_manifest.json").read_bytes()
        self.assertEqual(hashlib.sha256(ma).hexdigest(), hashlib.sha256(mb).hexdigest(),
                         "manifest 非输入纯函数(墙钟字段回归?)")
        self.assertNotIn(b"generatedAt", ma, "manifest 仍带墙钟(C 批回归)")
        for name in ("dialogue_sft.jsonl", "dialogue_eval.jsonl"):
            self.assertEqual((a / name).read_bytes(), (b / name).read_bytes(), name)

    def test_template_violation_fails_closed(self):
        """模板命中负清单(注入) → 构建期即抛,不落半成品。"""
        with self.assertRaises(ValueError):
            dialogue_builder.build(
                self.catalog, self.tmp / "out-bad", count=10, eval_ratio=0.1, seed=1,
                wording_source=_fake_wording_source(self.tmp, needle="资料里记录"),
                safety_source=REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AILocal.swift")

    def test_result_stream_no_writing_on_violation(self):
        self.assertFalse((self.tmp / "out-bad" / "dialogue_sft.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
