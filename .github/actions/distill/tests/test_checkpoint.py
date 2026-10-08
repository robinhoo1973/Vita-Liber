"""train.checkpoint 纯 stdlib 部分:原子写/sidecar 契约(不含 torch 路径)。

回归:atomic_write_bytes 曾对自身 sidecar 递归调用 → sidecar-of-sidecar 无限
递归(每次 checkpoint 保存必崩,py_compile 抓不到);本套用例把该路径拉进
零依赖测试闸(CI tests job 秒级跑)。
"""
import tempfile
import unittest
from pathlib import Path

from train.checkpoint import atomic_write_bytes, check_resume_loss


class ResumeLossGateTests(unittest.TestCase):
    """L1 闸负测(2026-10-08 换锚为「同批探测基」后冻结契约,验收席约束第 8 条):

    - 同批对拍:相等/容差内通过;
    - 超容差必抛(权重错配/装载错误的机械证据代理);run #3 实测 0.0429 vs
      0.1374(68.8%)必须被拒——该数值即负测夹具;
    - 非法断点值必抛。
    """

    def test_equal_passes(self):
        check_resume_loss(0.1374, 0.1374)

    def test_within_tolerance_passes(self):
        check_resume_loss(0.1000, 0.1040)  # 相对偏差 4% < 5%

    def test_beyond_tolerance_raises(self):
        with self.assertRaises(ValueError):
            check_resume_loss(0.1374, 0.0429)  # run #3 实测偏差 68.8%

    def test_invalid_recorded_raises(self):
        with self.assertRaises(ValueError):
            check_resume_loss(0.0, 0.1)

    def test_near_boundary_both_sides(self):
        # 双侧近界(避开浮点表示噪声:0.105-0.100 实际小于 0.005)
        check_resume_loss(1.0, 1.049)  # 4.9% 通过
        with self.assertRaises(ValueError):
            check_resume_loss(1.0, 1.051)  # 5.1% 拒绝


class AtomicWriteTests(unittest.TestCase):
    def test_sidecar_written_once_with_digest(self):
        d = Path(tempfile.mkdtemp())
        p = d / "checkpoint-00000001.pt"
        digest = atomic_write_bytes(p, b"hello")
        self.assertEqual(p.read_bytes(), b"hello")
        sidecar = p.with_suffix(p.suffix + ".sha256")
        self.assertEqual(sidecar.read_text(encoding="utf-8"), f"{digest}  {p.name}\n")
        # 核心回归:不得产生 sidecar 的 sidecar(旧实现递归到文件名超长才崩)
        self.assertFalse((d / "checkpoint-00000001.pt.sha256.sha256").exists())
        self.assertFalse((d / "checkpoint-00000001.pt.sha256.sha256.sha256").exists())

    def test_overwrite_replaces_and_reshares(self):
        d = Path(tempfile.mkdtemp())
        p = d / "latest.pt"
        first = atomic_write_bytes(p, b"aaa")
        second = atomic_write_bytes(p, b"bbbb")
        self.assertNotEqual(first, second)
        self.assertEqual(p.read_bytes(), b"bbbb")
        sidecar = p.with_suffix(p.suffix + ".sha256")
        self.assertEqual(sidecar.read_text(encoding="utf-8"), f"{second}  {p.name}\n")

    def test_creates_parent_dirs(self):
        d = Path(tempfile.mkdtemp()) / "nested" / "dirs"
        p = d / "c.pt"
        atomic_write_bytes(p, b"x")
        self.assertTrue(p.exists())


if __name__ == "__main__":
    unittest.main()
