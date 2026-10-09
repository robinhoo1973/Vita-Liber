"""gen.smoke_assert 负测(2026-10-08;闸契约变更须附负测——8ba917a 先例)。

零第三方依赖:CI tests job(不装 torch)也实跑本文件。
覆盖五条结构不变量的每条拒绝路径 + 一条合法通过路径:
判别力来自"每条不变量都有≥1 个必抛用例",防止断言被改弱而无人知。
"""
import tempfile
import unittest
from pathlib import Path

from gen.smoke_assert import verify_smoke_summary


def _make_ckpt(tmp: Path) -> tuple[Path, str]:
    import hashlib

    ckpt = tmp / "extraction-smoke.pt"
    payload = b"fake-checkpoint-bytes"
    ckpt.write_bytes(payload)
    sha = hashlib.sha256(payload).hexdigest()
    ckpt.with_suffix(ckpt.suffix + ".sha256").write_text(sha + "\n", encoding="utf-8")
    return ckpt, sha


def _valid_summary(sha: str) -> dict:
    return {
        "label": "extraction", "steps": 20, "started_at_step": 0,
        "new_steps": 20, "consumed_samples": 40, "elapsed_s": 12.3,
        "first_loss": 6.86, "last_loss": 4.28, "grad_norm_max": 1.0,
        "stopped_by": "max_steps", "checkpoint": "extraction-smoke.pt",
        "checkpoint_sha256": sha, "corpus_sha256": "a" * 64,
    }


class VerifySmokeSummaryTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.ckpt, self.sha = _make_ckpt(self.tmp)

    def tearDown(self):
        self._tmp.cleanup()

    def test_valid_passes(self):
        verify_smoke_summary(_valid_summary(self.sha), self.ckpt)

    def test_resume_with_new_steps_passes(self):
        summary = _valid_summary(self.sha)
        summary.update(steps=30, started_at_step=20, new_steps=10)
        verify_smoke_summary(summary, self.ckpt)

    def test_missing_field_raises(self):
        summary = _valid_summary(self.sha)
        del summary["corpus_sha256"]
        with self.assertRaisesRegex(ValueError, "缺字段"):
            verify_smoke_summary(summary, self.ckpt)

    def test_zero_new_steps_raises(self):
        # 历史缺陷形:resume 后 0 新步(或未跑)也以绿收场——必须拒
        summary = _valid_summary(self.sha)
        summary.update(steps=20, started_at_step=20, new_steps=0)
        with self.assertRaisesRegex(ValueError, "无新增训练步"):
            verify_smoke_summary(summary, self.ckpt)

    def test_illegal_stop_reason_raises(self):
        summary = _valid_summary(self.sha)
        summary["stopped_by"] = "crashed"
        with self.assertRaisesRegex(ValueError, "stopped_by 非法"):
            verify_smoke_summary(summary, self.ckpt)

    def test_nan_loss_raises(self):
        summary = _valid_summary(self.sha)
        summary["last_loss"] = float("nan")
        with self.assertRaisesRegex(ValueError, "非有限值"):
            verify_smoke_summary(summary, self.ckpt)

    def test_inf_grad_norm_raises(self):
        summary = _valid_summary(self.sha)
        summary["grad_norm_max"] = float("inf")
        with self.assertRaisesRegex(ValueError, "非有限值"):
            verify_smoke_summary(summary, self.ckpt)

    def test_none_first_loss_raises(self):
        summary = _valid_summary(self.sha)
        summary["first_loss"] = None
        with self.assertRaisesRegex(ValueError, "非有限值"):
            verify_smoke_summary(summary, self.ckpt)

    def test_missing_checkpoint_raises(self):
        with self.assertRaisesRegex(ValueError, "checkpoint 不存在"):
            verify_smoke_summary(_valid_summary(self.sha), self.tmp / "nope.pt")

    def test_empty_checkpoint_raises(self):
        empty = self.tmp / "empty.pt"
        empty.write_bytes(b"")
        empty.with_suffix(".pt.sha256").write_text("0" * 64 + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "为空文件"):
            verify_smoke_summary(_valid_summary(self.sha), empty)

    def test_missing_sidecar_raises(self):
        ckpt = self.tmp / "no-sidecar.pt"
        ckpt.write_bytes(b"bytes")
        with self.assertRaisesRegex(ValueError, "sidecar 缺失"):
            verify_smoke_summary(_valid_summary(self.sha), ckpt)

    def test_summary_sha_mismatch_raises(self):
        summary = _valid_summary("b" * 64)
        with self.assertRaisesRegex(ValueError, "三方不一致"):
            verify_smoke_summary(summary, self.ckpt)

    def test_sidecar_sha_mismatch_raises(self):
        self.ckpt.with_suffix(self.ckpt.suffix + ".sha256").write_text(
            "c" * 64 + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "三方不一致"):
            verify_smoke_summary(_valid_summary(self.sha), self.ckpt)

    def test_content_tamper_raises(self):
        # 内容被改写(名=c 与记录不符)必须拒——append-only 同族防线
        self.ckpt.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "三方不一致"):
            verify_smoke_summary(_valid_summary(self.sha), self.ckpt)

    def test_grad_norm_default_zero_is_finite(self):
        summary = _valid_summary(self.sha)
        summary["grad_norm_max"] = 0.0
        verify_smoke_summary(summary, self.ckpt)


if __name__ == "__main__":
    unittest.main()
