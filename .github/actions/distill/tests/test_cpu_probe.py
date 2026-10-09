"""cpu_probe 负测(2026-10-09 研究席 A1)。stdlib;合成 cpuinfo,不依赖本机 ISA。"""
import sys
import tempfile
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DISTILL))

from gen.cpu_probe import bf16_hardware_ok, cpu_flags, summary  # noqa: E402

AMD = "flags\t\t: fpu vme avx avx2 fma f16c\n"
SPR = "flags\t\t: fpu avx avx2 avx512f avx512_bf16 amx_tile amx_bf16\n"
ICE = "flags\t\t: fpu avx avx2 avx512f avx512_vnni\n"


def _probe(text: str) -> dict:
    tmp = Path(tempfile.mkdtemp()) / "cpuinfo"
    tmp.write_text(text, encoding="utf-8")
    return cpu_flags(tmp)


class CpuProbeTests(unittest.TestCase):
    def test_avx2_only_no_bf16(self):
        f = _probe(AMD)
        self.assertTrue(f["avx2"])
        self.assertFalse(bf16_hardware_ok(f))

    def test_amx_box_bf16_ok(self):
        f = _probe(SPR)
        self.assertTrue(f["amx_bf16"])
        self.assertTrue(bf16_hardware_ok(f))

    def test_ice_lake_no_bf16(self):
        f = _probe(ICE)
        self.assertTrue(f["avx512f"])
        self.assertFalse(bf16_hardware_ok(f))

    def test_unreadable_returns_false(self):
        f = cpu_flags(Path("/nonexistent/cpuinfo"))
        self.assertFalse(f["readable"])
        self.assertFalse(bf16_hardware_ok(f))

    def test_summary_shape(self):
        self.assertIn("bf16_hardware=yes", summary(_probe(SPR)))


if __name__ == "__main__":
    unittest.main()
