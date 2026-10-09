"""gen.sft_dataset:ChatML 渲染/掩码/截断守卫(torch+transformers 缺失时跳过)。

为什么可以跳:torch/transformers 是 smoke job 期依赖(requirements-distill-train-linux),
tests job 不装;CI 的真实验证面 = smoke job 的 train_sft_smoke.py 实跑(与既有一致)。
"""
import json
import tempfile
import unittest
from pathlib import Path

try:
    import torch  # noqa: F401
    import transformers  # noqa: F401

    HAVE_DEPS = True
except ImportError:
    HAVE_DEPS = False

GEN_DIR = Path(__file__).resolve().parents[1] / "gen"


def _write_corpus(tmp: Path) -> Path:
    rows = [
        {"conversations": [
            {"role": "system", "content": "你是转述助手。"},
            {"role": "user", "content": "资料:\n1. 用法:口服。\n问题:怎么吃"},
            {"role": "assistant", "content": '{"mode":"restate","conclusion":"资料里记录的用法是「口服」。","fragments":["口服"],"citations":[1]}'},
        ]},
        {"conversations": [
            {"role": "user", "content": "突然胸痛"},
            {"role": "assistant", "content": '{"mode":"emergency"}'},
        ]},
    ]
    path = tmp / "dialogue_sft.jsonl"
    path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    return path


@unittest.skipUnless(HAVE_DEPS, "torch/transformers 仅 smoke job 安装")
class SftDatasetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from transformers import AutoTokenizer
        from gen.sft_dataset import ChatSFTDataset
        cls.tmp = Path(tempfile.mkdtemp())
        cls.tokenizer = AutoTokenizer.from_pretrained(str(GEN_DIR))
        cls.dataset = ChatSFTDataset(str(_write_corpus(cls.tmp)), cls.tokenizer, max_length=1024)

    def test_masking_targets_assistant_only(self):
        input_ids, labels = self.dataset[0]
        supervised = labels[labels != -100]
        self.assertGreater(len(supervised), 0)
        text = self.tokenizer.decode(supervised.tolist())
        self.assertIn("restate", text)
        self.assertNotIn("怎么吃", text)   # 用户段不参与 loss

    def test_render_strips_empty_think(self):
        prompt = self.dataset.render(self.dataset.samples[0])
        self.assertNotIn("<think>", prompt)

    def test_default_family_is_minimind_strip(self):
        # 默认惰性:不传帧族时行为与参数化前完全一致(100% 剥离;冻结语料不受影响)
        self.assertEqual(self.dataset.frame_family, "minimind-strip")

    def test_render_qwen3_nothink_keeps_final_empty_think(self):
        # E3:部署 Qwen3 帧=保留空 think 段;训练流须与部署帧逐字节同文(仅末段)
        from gen.sft_dataset import ChatSFTDataset
        ds = ChatSFTDataset(str(_write_corpus(self.tmp)), self.tokenizer, max_length=1024,
                            frame_family="qwen3-nothink")
        prompt = ds.render(ds.samples[0])
        self.assertEqual(prompt.count("<think>"), 1)
        self.assertEqual(prompt.count("</think>"), 1)
        head = prompt.rindex("<|im_start|>assistant\n")
        self.assertTrue(
            prompt[head:].startswith("<|im_start|>assistant\n<think>\n\n</think>\n\n"),
            "空 think 段必须紧跟末段 assistant 头(部署帧:提示词含该段,模型只续写答案)")

    def test_unknown_family_fails_closed(self):
        from gen.sft_dataset import ChatSFTDataset
        with self.assertRaises(ValueError):
            ChatSFTDataset(str(_write_corpus(self.tmp)), self.tokenizer, max_length=1024,
                           frame_family="qwen2-think")

    def test_truncation_guard_fails_loud(self):
        from gen.sft_dataset import ChatSFTDataset
        tiny = ChatSFTDataset(str(_write_corpus(self.tmp)), self.tokenizer, max_length=8)
        with self.assertRaises(ValueError):
            _ = tiny[0]

    def test_invalid_conversations_fail_loud(self):
        from gen.sft_dataset import ChatSFTDataset
        bad = self.tmp / "bad.jsonl"
        bad.write_text(json.dumps({"conversations": [{"role": "user", "content": "x"}]}) + "\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            ChatSFTDataset(str(bad), self.tokenizer, max_length=64)

    def test_partial_truncation_guard_fails_loud(self):
        # research B1/Unsloth #11040 族:末 assistant 段尾部被切(缺 <|im_end|>)——
        # 全掩蔽守卫看不见,必须显式拒绝(否则静默教出"不会停")
        from gen.sft_dataset import ChatSFTDataset
        full_ids = self.tokenizer(self.dataset.render(self.dataset.samples[0])).input_ids
        cut = max(9, len(full_ids) - 2)   # 切掉 eos 尾部(保留 assistant 开头)
        partial = ChatSFTDataset(str(_write_corpus(self.tmp)), self.tokenizer, max_length=cut)
        if all(l == -100 for l in partial.generate_labels(full_ids[:cut])):
            self.skipTest("该长度下全掩蔽守卫先命中(等价保护)")
        with self.assertRaisesRegex(ValueError, "截断"):
            _ = partial[0]


if __name__ == "__main__":
    unittest.main()
