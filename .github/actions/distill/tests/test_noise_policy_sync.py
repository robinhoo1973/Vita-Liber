"""噪声常量 ↔ policy.json 单一事实源同步负测(2026-10-08 D1 批)
+ 跨侧孪生副本同步负测(2026-10-09 W20 B 批)。

背景:extract/extraction_noise.py 的运行期常量(训练机副本无 policy.json 布局,
不能运行期依赖文件)必须与 .github/config/distill/policy.json 逐值相等,否则
语料按一套分布产出、门禁按另一套判。builder main 已有 fail-closed 交叉断言;
本测试把同一断言左移到测试期(不等到产出时才红)。

跨侧类(与 test_gen_frames_sync.py 同范式):CI 簇 .github/actions/distill/extract/
的四个语料模块(extraction_noise / line_ops / confusion / noise_scheduler)是训练机
正本 refactor/tools/training/template/scripts/corpus/ 的只读副本——分叉 = 训练/推理
不同分布(E3 邻类)。CI 检出无 refactor/,锚点上溯找不到即整类 skip(不假红)。

覆盖:bandTargets↔BAND_CER、trainMix↔DEFAULT_TRAIN_MIX、version↔NOISE_VERSION、
ASR 份额带位完备且每带归一;两侧模块 sha 相等;标点漂移表无重复键(C 批回归)。零第三方依赖。
"""
import hashlib
import random
import unittest
from pathlib import Path

from extract.extraction_noise import (ASR_BAND_SHARES, BAND_CER, DEFAULT_TRAIN_MIX,
                                      NOISE_VERSION, punctuation_loosen)
from policy import load


def _find_training_corpus(name: str):
    """逐级上溯找工作区内训练机正本(找不到=CI 检出,返回 None)。"""
    for base in Path(__file__).resolve().parents:
        candidate = (base / "refactor" / "tools" / "training" / "template"
                     / "scripts" / "corpus" / name)
        if candidate.is_file():
            return candidate
    return None


LOCAL_CORPUS = _find_training_corpus("extraction_noise.py")
CI_EXTRACT = Path(__file__).resolve().parents[1] / "extract"


class NoisePolicySyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.noise = load()["noise"]

    def test_band_targets_match(self):
        self.assertEqual(self.noise["bandTargets"], BAND_CER,
                         "BAND_CER 与 policy.noise.bandTargets 不一致——先同步两处")

    def test_train_mix_match(self):
        self.assertEqual(self.noise["trainMix"], DEFAULT_TRAIN_MIX,
                         "DEFAULT_TRAIN_MIX 与 policy.noise.trainMix 不一致(注意口径:分数)")

    def test_version_match(self):
        self.assertEqual(self.noise["version"], NOISE_VERSION)

    def test_asr_shares_cover_nonclean_bands_and_sum_to_one(self):
        bands = set(BAND_CER) - {"clean"}
        self.assertEqual(set(ASR_BAND_SHARES), bands,
                         "ASR 份额带位与 bandTargets(除 clean)不一致")
        for band, shares in ASR_BAND_SHARES.items():
            self.assertAlmostEqual(sum(shares.values()), 1.0, places=6,
                                   msg=f"{band} 族份额和≠1")

    def test_train_mix_does_not_leak_into_asr_shares(self):
        # 防回归:曾出现 trainMix 用百分数(15/30/…)与 policy 分数(0.15)失配
        for band, weight in DEFAULT_TRAIN_MIX.items():
            self.assertLessEqual(weight, 1.0, f"trainMix[{band}] 疑似百分数口径")


class PunctuationLoosenTests(unittest.TestCase):
    def test_full_width_colon_actually_loosens(self):
        """C 批回归(2026-10-09 W20):`punctuation_loosen` 表曾含同型重复键
        `"：": "："`(字面重复键,后者覆盖前者)→ 全角冒号永不漂移,且多消耗一次
        rng 抽样(与训练侧副本同 seed 不同输出)。重复键剔除后形态漂移必须实际发生。
        """
        outs = {punctuation_loosen("：", random.Random(i)) for i in range(64)}
        self.assertIn(":", outs, "全角冒号从未漂移到半角——重复键回归?")
        self.assertIn("", outs, "全角冒号从未丢失——重复键回归?")
        self.assertLessEqual(outs, {":", "：", ""})


@unittest.skipUnless(LOCAL_CORPUS, "本地训练树不在工作区(CI 检出无 refactor/)——跨侧同步断言跳过")
class TwinCopySyncTests(unittest.TestCase):
    """两侧语料模块 sha 相等(训练机正本 ↔ CI 只读副本)。"""

    TWINS = ("extraction_noise.py", "line_ops.py", "confusion.py", "noise_scheduler.py")

    @staticmethod
    def _sha(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_all_twins_byte_identical(self):
        for name in self.TWINS:
            local = _find_training_corpus(name)
            self.assertIsNotNone(local, f"{name} 在训练树缺失")
            self.assertEqual(self._sha(CI_EXTRACT / name), self._sha(local),
                             f"{name} 两侧副本分叉——先同步两处(同分布纪律)")

    def test_line_ops_v22_semantics_present_on_both_sides(self):
        # v2.2 语义超集(linsert/pinterl + donors=)必须两侧同在(训练侧曾落后一版)
        for path in (CI_EXTRACT / "line_ops.py", _find_training_corpus("line_ops.py")):
            src = path.read_text(encoding="utf-8")
            for marker in ('"linsert"', '"pinterl"', "donors"):
                self.assertIn(marker, src, f"{path.name} 缺 v2.2 语义 {marker}")

    def test_confusion_empty_column_semantics_present_on_both_sides(self):
        # C5:丢空列=列语义错位——两侧都必须保留空列(逐字节同源,一次断言双保险)
        for path in (CI_EXTRACT / "confusion.py", _find_training_corpus("confusion.py")):
            src = path.read_text(encoding="utf-8")
            self.assertIn("rows.append(line.split(\"\\t\"))", src,
                          f"{path.name} 仍按 `if cell` 过滤空列(C5 回归)")


if __name__ == "__main__":
    unittest.main()
