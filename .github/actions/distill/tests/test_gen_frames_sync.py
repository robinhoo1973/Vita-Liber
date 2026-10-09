"""gen.frames 帧族语义 + ↔ 本地训练工具 frames.py 跨侧同步断言(E3;零第三方依赖)。

与 test_noise_policy_sync.py 同范式(跨处相等断言左移到测试期,不等产出时才红):
CI 帧后处理(gen/frames.py)的常量必须与训练机正本
refactor/tools/training/template/trainlib/frames.py **逐字相等**——两处漂移 =
「训练/推理不同分布」(E3)复发。本地训练工具树不在 CI 检出内(公开仓 checkout
无 refactor/),锚点上溯找不到即整类断言 skip 不红;语义断言(剥离/保留末段/
fail-closed)不依赖本地树,CI tests job 实跑。
"""
import importlib.util
import unittest
from pathlib import Path

from gen.frames import (DEFAULT_FAMILY, EMPTY_THINK, FAMILIES,
                        FAMILY_MINIMIND_STRIP, FAMILY_QWEN3_NOTHINK,
                        apply_frame_family)


def _find_local_frames():
    """相对锚点逐级上溯找工作区内的训练机正本(找不到=CI 检出,返回 None)。"""
    here = Path(__file__).resolve()
    for base in here.parents:
        candidate = (base / "refactor" / "tools" / "training" / "template" / "scripts"
                     / "trainlib" / "frames.py")
        if candidate.is_file():
            return candidate
    return None


def _load_local_frames(path: Path):
    spec = importlib.util.spec_from_file_location("trainlib_frames_local", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LOCAL_FRAMES = _find_local_frames()


class FrameFamilySemanticsTests(unittest.TestCase):
    def test_family_ids_are_contract_literals(self):
        self.assertEqual(FAMILIES, ("minimind-strip", "qwen3-nothink"))
        self.assertEqual(DEFAULT_FAMILY, FAMILY_MINIMIND_STRIP,
                         "默认族必须=旧行为(minimind-strip;冻结语料 sha 不受影响)")

    def test_empty_think_literal(self):
        # 与 Swift ExtractionPromptBuilder.emptyThinkSegment 逐字同字面(两侧同升纪律)
        self.assertEqual(EMPTY_THINK, "<think>\n\n</think>\n\n")

    def test_minimind_strip_removes_all_empty_think(self):
        text = f"A{EMPTY_THINK}B{EMPTY_THINK}C"
        self.assertEqual(apply_frame_family(text, FAMILY_MINIMIND_STRIP), "ABC")
        self.assertEqual(apply_frame_family(text), "ABC")   # 默认族=剥离

    def test_qwen3_nothink_keeps_only_final_empty_think(self):
        text = f"A{EMPTY_THINK}B{EMPTY_THINK}C"
        self.assertEqual(apply_frame_family(text, FAMILY_QWEN3_NOTHINK),
                         f"AB{EMPTY_THINK}C",
                         "仅末段保留;中间段剥离(Qwen3 官方模板 loop.last 同形)")

    def test_qwen3_nothink_fails_closed_without_empty_think(self):
        with self.assertRaisesRegex(ValueError, "帧契约"):
            apply_frame_family("AB", FAMILY_QWEN3_NOTHINK)

    def test_unknown_family_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "未知帧族"):
            apply_frame_family("AB", "qwen2-think")


@unittest.skipUnless(LOCAL_FRAMES, "本地训练工具树不在工作区(CI 检出无 refactor/)——跨侧同步断言跳过")
class FrameFamilyCrossSideSyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = _load_local_frames(LOCAL_FRAMES)

    def test_all_frame_constants_identical(self):
        for name, ci_value in (("EMPTY_THINK", EMPTY_THINK),
                               ("FAMILY_MINIMIND_STRIP", FAMILY_MINIMIND_STRIP),
                               ("FAMILY_QWEN3_NOTHINK", FAMILY_QWEN3_NOTHINK),
                               ("FAMILIES", FAMILIES),
                               ("DEFAULT_FAMILY", DEFAULT_FAMILY)):
            self.assertEqual(ci_value, getattr(self.local, name),
                             f"{name} 与训练机 frames.py 漂移——先同步两处(两侧同升纪律)")

    def test_default_family_semantics_agree(self):
        # 跨侧行为抽样:默认族均=剥离;qwen3-nothink 全文流均只保留末段 think 段
        local_chat = [{"role": "system", "content": "SYS"},
                      {"role": "user", "content": "USR"},
                      {"role": "assistant", "content": "A"},
                      {"role": "user", "content": "U2"},
                      {"role": "assistant", "content": "B"}]
        local_strip = self.local.frame_sample(local_chat, family="minimind-strip")
        self.assertNotIn(self.local.EMPTY_THINK, local_strip)
        local_qwen3 = self.local.frame_sample(local_chat, family="qwen3-nothink")
        self.assertEqual(local_qwen3.count(self.local.EMPTY_THINK), 1)
        # CI 侧对等价文本形态的同类断言(模板注入版)
        ci_text = f"{local_chat[0]['content']}{EMPTY_THINK}X{EMPTY_THINK}Y"
        self.assertEqual(apply_frame_family(ci_text, FAMILY_MINIMIND_STRIP), "SYSXY")
        self.assertEqual(apply_frame_family(ci_text, FAMILY_QWEN3_NOTHINK),
                         f"SYSX{EMPTY_THINK}Y")


if __name__ == "__main__":
    unittest.main()
