"""train.checkpoint 纯 stdlib 部分:原子写/sidecar 契约(不含 torch 路径)。

回归:atomic_write_bytes 曾对自身 sidecar 递归调用 → sidecar-of-sidecar 无限
递归(每次 checkpoint 保存必崩,py_compile 抓不到);本套用例把该路径拉进
零依赖测试闸(CI tests job 秒级跑)。
"""
import tempfile
import unittest
from pathlib import Path

from train.checkpoint import atomic_write_bytes


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
